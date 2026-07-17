// Uploads encrypted segments directly to the user's own S3 bucket (SigV4-signed), with no backend in the path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import '../models/recording_segment.dart';
import 'crypto/segment_encryptor.dart';
import 'spectral_sidecar.dart';

class UploadResult {
  const UploadResult.success(this.remoteKey) : error = null;

  const UploadResult.failure(this.error) : remoteKey = null;

  final String? remoteKey;
  final String? error;

  bool get isSuccess => remoteKey != null;
}

class S3StorageClient {
  factory S3StorageClient({
    http.Client? httpClient,
    Duration requestTimeout = const Duration(seconds: 45),
    SegmentEncryptor? encryptor,
  }) {
    return S3StorageClient._(
      httpClient ?? http.Client(),
      requestTimeout,
      encryptor,
    );
  }

  S3StorageClient._(this._httpClient, this.requestTimeout, this._encryptor);

  final http.Client _httpClient;
  final Duration requestTimeout;

  /// When set, local segment files are sealed on-device before the direct-to-S3
  /// PUT. The SigV4 payload hash is computed over the ciphertext that is sent.
  /// Server-side object copies ([_copyObject]) are untouched — they move bytes
  /// that are already ciphertext.
  final SegmentEncryptor? _encryptor;

  Future<UploadResult> uploadSegment({
    required AppConfig config,
    required CloudSecrets secrets,
    required RecordingSegment segment,
    required File file,
  }) async {
    if (!config.s3TargetReady || !secrets.hasS3Credentials) {
      return const UploadResult.failure(
        'S3 bucket, region, and credentials are required.',
      );
    }
    if (!await file.exists()) {
      return const UploadResult.failure('Local segment file is missing.');
    }
    final audioResult = await _putFile(
      config: config,
      secrets: secrets,
      key: objectKeyFor(config, segment),
      file: file,
      contentType: segment.contentType,
    );
    if (!audioResult.isSuccess) {
      return audioResult;
    }

    // The sidecar is finalized before upload draining begins. Keep it adjacent
    // to the audio in S3 and seal it independently when encryption is enabled.
    // PUT is idempotent, so retrying after a sidecar failure safely replaces the
    // already-uploaded audio object with the same logical segment.
    final sidecar = File(SpectralSidecar.sidecarPathFor(file.path));
    if (!await sidecar.exists()) {
      return audioResult;
    }
    final sidecarResult = await _putFile(
      config: config,
      secrets: secrets,
      key: analysisObjectKeyFor(config, segment),
      file: sidecar,
      contentType: _encryptor == null
          ? 'application/json'
          : 'application/octet-stream',
    );
    if (!sidecarResult.isSuccess) {
      return UploadResult.failure(
        'Audio uploaded, but FFT analysis sidecar failed: ${sidecarResult.error}',
      );
    }
    return audioResult;
  }

  Future<UploadResult> saveSegmentPermanently({
    required AppConfig config,
    required CloudSecrets secrets,
    required RecordingSegment segment,
    File? file,
  }) async {
    if (!config.s3TargetReady || !secrets.hasS3Credentials) {
      return const UploadResult.failure(
        'S3 bucket, region, and credentials are required.',
      );
    }
    final permanentKey = permanentObjectKeyFor(config, segment);
    if (file != null && await file.exists()) {
      return _putFile(
        config: config,
        secrets: secrets,
        key: permanentKey,
        file: file,
        contentType: segment.contentType,
      );
    }
    final sourceKey = segment.remoteKey;
    if (sourceKey == null || sourceKey.trim().isEmpty) {
      return const UploadResult.failure(
        'Segment is not available locally or in S3.',
      );
    }
    return _copyObject(
      config: config,
      secrets: secrets,
      sourceKey: sourceKey,
      destinationKey: permanentKey,
    );
  }

  Future<String?> deleteObject({
    required AppConfig config,
    required CloudSecrets secrets,
    required String key,
  }) async {
    if (!config.s3TargetReady || !secrets.hasS3Credentials) {
      return 'S3 bucket, region, and credentials are required.';
    }
    try {
      final uri = _objectUri(config, key);
      final payloadHash = sha256.convert(const <int>[]).toString();
      final headers = _signedHeaders(
        method: 'DELETE',
        uri: uri,
        config: config,
        secrets: secrets,
        payloadHash: payloadHash,
      );
      final response = await _httpClient
          .delete(uri, headers: headers)
          .timeout(requestTimeout);
      if (response.statusCode == 204 ||
          response.statusCode == 200 ||
          response.statusCode == 404) {
        return null;
      }
      return 'S3 delete failed: HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}'
          .trim();
    } on TimeoutException {
      return 'S3 delete timed out after ${requestTimeout.inSeconds} seconds.';
    } on FormatException catch (error) {
      return error.message;
    } catch (error) {
      return 'S3 delete failed: $error';
    }
  }

  /// Deletes a rolling segment's analysis sidecar first, then its audio. This
  /// ordering avoids leaving readable event metadata behind if the second
  /// request fails; either failure keeps the segment indexed for a later retry.
  Future<String?> deleteSegmentObjects({
    required AppConfig config,
    required CloudSecrets secrets,
    required String audioKey,
  }) async {
    final sidecarError = await deleteObject(
      config: config,
      secrets: secrets,
      key: analysisObjectKeyForAudioKey(audioKey),
    );
    if (sidecarError != null) {
      return 'FFT sidecar delete failed: $sidecarError';
    }
    return deleteObject(config: config, secrets: secrets, key: audioKey);
  }

  String objectKeyFor(AppConfig config, RecordingSegment segment) {
    final prefix = config.s3Prefix
        .split('/')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join('/');
    final started = segment.startedAtUtc.toUtc();
    final parts = <String>[
      if (prefix.isNotEmpty) prefix,
      config.deviceId,
      started.year.toString().padLeft(4, '0'),
      started.month.toString().padLeft(2, '0'),
      started.day.toString().padLeft(2, '0'),
      started.hour.toString().padLeft(2, '0'),
      '${segment.id}.${segment.fileExtension}',
    ];
    return parts.join('/');
  }

  String analysisObjectKeyFor(AppConfig config, RecordingSegment segment) {
    return analysisObjectKeyForAudioKey(objectKeyFor(config, segment));
  }

  String analysisObjectKeyForAudioKey(String audioKey) {
    final dot = audioKey.lastIndexOf('.');
    final stem = dot < 0 ? audioKey : audioKey.substring(0, dot);
    return '$stem.features.json';
  }

  String permanentObjectKeyFor(AppConfig config, RecordingSegment segment) {
    final prefix = config.s3Prefix
        .split('/')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join('/');
    final started = segment.startedAtUtc.toUtc();
    final parts = <String>[
      if (prefix.isNotEmpty) prefix,
      config.deviceId,
      'permanent',
      started.year.toString().padLeft(4, '0'),
      started.month.toString().padLeft(2, '0'),
      started.day.toString().padLeft(2, '0'),
      started.hour.toString().padLeft(2, '0'),
      '${segment.id}.${segment.fileExtension}',
    ];
    return parts.join('/');
  }

  Future<UploadResult> _putFile({
    required AppConfig config,
    required CloudSecrets secrets,
    required String key,
    required File file,
    required String contentType,
  }) async {
    try {
      final plaintext = await file.readAsBytes();
      final bytes = _encryptor == null
          ? plaintext
          : await _encryptor.seal(plaintext);
      final uri = _objectUri(config, key);
      final payloadHash = sha256.convert(bytes).toString();
      final headers = _signedHeaders(
        method: 'PUT',
        uri: uri,
        config: config,
        secrets: secrets,
        payloadHash: payloadHash,
        // Do not add x-amz-server-side-encryption here. Direct uploads are
        // already encrypted on-device when an encryptor is configured, and R2
        // rejects the AWS-specific AES256 request header.
        extraHeaders: {'content-type': contentType},
      );
      final response = await _httpClient
          .put(uri, headers: headers, body: bytes)
          .timeout(requestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return UploadResult.success(key);
      }
      return UploadResult.failure(
        'S3 upload failed: HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}'
            .trim(),
      );
    } on TimeoutException {
      return UploadResult.failure(
        'S3 upload timed out after ${requestTimeout.inSeconds} seconds.',
      );
    } on FormatException catch (error) {
      return UploadResult.failure(error.message);
    } catch (error) {
      return UploadResult.failure('S3 upload failed: $error');
    }
  }

  Future<UploadResult> _copyObject({
    required AppConfig config,
    required CloudSecrets secrets,
    required String sourceKey,
    required String destinationKey,
  }) async {
    try {
      final uri = _objectUri(config, destinationKey);
      final payloadHash = sha256.convert(const <int>[]).toString();
      final headers = _signedHeaders(
        method: 'PUT',
        uri: uri,
        config: config,
        secrets: secrets,
        payloadHash: payloadHash,
        extraHeaders: {'x-amz-copy-source': _copySource(config, sourceKey)},
      );
      final response = await _httpClient
          .put(uri, headers: headers)
          .timeout(requestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return UploadResult.success(destinationKey);
      }
      return UploadResult.failure(
        'S3 copy failed: HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}'
            .trim(),
      );
    } on TimeoutException {
      return UploadResult.failure(
        'S3 copy timed out after ${requestTimeout.inSeconds} seconds.',
      );
    } on FormatException catch (error) {
      return UploadResult.failure(error.message);
    } catch (error) {
      return UploadResult.failure('S3 copy failed: $error');
    }
  }

  String _copySource(AppConfig config, String key) {
    final encodedKey = key.split('/').map(_awsEncode).join('/');
    return '${Uri.encodeComponent(config.s3Bucket.trim())}/$encodedKey';
  }

  Uri _objectUri(AppConfig config, String key) {
    final endpoint = config.s3Endpoint.trim();
    if (endpoint.isNotEmpty) {
      final base = Uri.parse(endpoint);
      if (base.scheme != 'https') {
        throw const FormatException('S3-compatible endpoints must use HTTPS.');
      }
      if (config.s3Bucket.trim().contains('/')) {
        throw const FormatException('S3 bucket must not contain slashes.');
      }
      final baseSegments = base.pathSegments.where((part) => part.isNotEmpty);
      return base.replace(
        query: '',
        fragment: '',
        pathSegments: [
          ...baseSegments,
          config.s3Bucket.trim(),
          ...key.split('/'),
        ],
      );
    }
    final bucket = config.s3Bucket.trim();
    final validDnsBucket = RegExp(
      r'^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$',
    ).hasMatch(bucket);
    if (!validDnsBucket) {
      throw const FormatException(
        'AWS S3 bucket must be 3-63 lowercase letters, numbers, and hyphens for direct AWS uploads.',
      );
    }
    return Uri.https(
      '$bucket.s3.${config.s3Region.trim()}.amazonaws.com',
      '/$key',
    );
  }

  Map<String, String> _signedHeaders({
    required String method,
    required Uri uri,
    required AppConfig config,
    required CloudSecrets secrets,
    required String payloadHash,
    Map<String, String> extraHeaders = const {},
  }) {
    final now = DateTime.now().toUtc();
    final amzDate = _amzDate(now);
    final dateStamp = _dateStamp(now);
    final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    final headers = <String, String>{
      'host': host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      ...extraHeaders.map((key, value) => MapEntry(key.toLowerCase(), value)),
    };
    if (secrets.s3SessionToken.trim().isNotEmpty) {
      headers['x-amz-security-token'] = secrets.s3SessionToken.trim();
    }
    final signedHeaderNames = headers.keys.toList()..sort();
    final canonicalHeaders = signedHeaderNames
        .map((name) => '$name:${headers[name]!.trim()}\n')
        .join();
    final signedHeaders = signedHeaderNames.join(';');
    final canonicalRequest =
        [
              method,
              _canonicalUri(uri),
              uri.queryParameters.entries
                  .map(
                    (entry) =>
                        '${_awsEncode(entry.key)}=${_awsEncode(entry.value)}',
                  )
                  .toList()
                ..sort(),
              canonicalHeaders,
              signedHeaders,
              payloadHash,
            ]
            .map((part) {
              if (part is List<String>) {
                return part.join('&');
              }
              return part.toString();
            })
            .join('\n');
    final credentialScope =
        '$dateStamp/${config.s3Region.trim()}/s3/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');
    final signature = _hmacHex(
      _signingKey(
        secrets.s3SecretAccessKey.trim(),
        dateStamp,
        config.s3Region.trim(),
      ),
      stringToSign,
    );
    return {
      ...headers,
      'Authorization':
          'AWS4-HMAC-SHA256 Credential=${secrets.s3AccessKeyId.trim()}/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature',
    };
  }

  Uint8List _signingKey(String secret, String dateStamp, String region) {
    final kDate = _hmacBytes(utf8.encode('AWS4$secret'), dateStamp);
    final kRegion = _hmacBytes(kDate, region);
    final kService = _hmacBytes(kRegion, 's3');
    return _hmacBytes(kService, 'aws4_request');
  }

  Uint8List _hmacBytes(List<int> key, String message) {
    return Uint8List.fromList(
      Hmac(sha256, key).convert(utf8.encode(message)).bytes,
    );
  }

  String _hmacHex(List<int> key, String message) {
    return Hmac(sha256, key).convert(utf8.encode(message)).toString();
  }

  String _canonicalUri(Uri uri) {
    if (uri.pathSegments.isEmpty) {
      return '/';
    }
    return '/${uri.pathSegments.map(_awsEncode).join('/')}';
  }

  String _awsEncode(String value) {
    return Uri.encodeComponent(
      value,
    ).replaceAll('+', '%20').replaceAll('*', '%2A').replaceAll('%7E', '~');
  }

  String _dateStamp(DateTime dateTime) {
    return '${dateTime.year.toString().padLeft(4, '0')}'
        '${dateTime.month.toString().padLeft(2, '0')}'
        '${dateTime.day.toString().padLeft(2, '0')}';
  }

  String _amzDate(DateTime dateTime) {
    return '${_dateStamp(dateTime)}T'
        '${dateTime.hour.toString().padLeft(2, '0')}'
        '${dateTime.minute.toString().padLeft(2, '0')}'
        '${dateTime.second.toString().padLeft(2, '0')}Z';
  }

  void close() {
    _httpClient.close();
  }
}
