// Backend-mediated upload client for non-S3 providers: registers the device and streams encrypted segments through the Sonus backend.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../models/cloud_provider.dart';
import '../models/cloud_secrets.dart';
import '../models/recording_segment.dart';
import 'crypto/segment_encryptor.dart';

class BackendUploadSession {
  const BackendUploadSession({
    required this.id,
    required this.expiresAtUtc,
    required this.maxSegmentBytes,
  });

  final String id;
  final DateTime? expiresAtUtc;
  final int maxSegmentBytes;

  bool get isUsable {
    final expiresAt = expiresAtUtc;
    if (expiresAt == null) {
      return true;
    }
    return DateTime.now().toUtc().isBefore(
      expiresAt.subtract(const Duration(minutes: 2)),
    );
  }
}

class BackendUploadResult {
  const BackendUploadResult.success(this.remoteKey)
    : error = null,
      session = null;

  const BackendUploadResult.failure(this.error)
    : remoteKey = null,
      session = null;

  const BackendUploadResult.sessionExpired()
    : remoteKey = null,
      error = 'Backend upload session expired.',
      session = null;

  const BackendUploadResult.withSession({
    required this.remoteKey,
    required this.session,
  }) : error = null;

  final String? remoteKey;
  final String? error;
  final BackendUploadSession? session;

  bool get isSuccess => remoteKey != null;
}

class BackendPermanentSaveResult {
  const BackendPermanentSaveResult.success(this.remoteKeysBySegmentId)
    : error = null;

  const BackendPermanentSaveResult.failure(this.error)
    : remoteKeysBySegmentId = const {};

  final Map<String, String> remoteKeysBySegmentId;
  final String? error;

  bool get isSuccess => error == null;
}

class DeviceRegistration {
  const DeviceRegistration({
    required this.accountId,
    required this.deviceId,
    required this.deviceToken,
  });

  final String accountId;
  final String deviceId;
  final String deviceToken;
}

class SoundRecorderBackendClient {
  SoundRecorderBackendClient({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 45),
    this._encryptor,
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration requestTimeout;

  /// When set, every segment is sealed on-device before upload so the cloud and
  /// our backend only ever store ciphertext. The presign/complete hash and byte
  /// count are computed over the ciphertext that is actually PUT.
  final SegmentEncryptor? _encryptor;

  Future<BackendUploadSession> createUploadSession({
    required AppConfig config,
    required CloudSecrets secrets,
  }) async {
    final uri = _apiUri(config, '/api/mobile/v1/upload-sessions');
    final response = await _httpClient
        .post(
          uri,
          headers: _jsonHeaders(secrets),
          body: jsonEncode({
            'contentType': 'audio/wav',
            'codec': 'pcm_s16le',
            'sampleRate': config.sampleRate,
            'channelCount': config.channels,
            'segmentDurationSeconds': config.segmentDuration.inSeconds,
            'maxSegmentBytes': _maxSegmentBytes(config),
            'useCase': config.useCase,
            'audioProfile': config.audioProfile,
            'metaData': {
              'overlapSeconds': config.overlapSeconds,
              'overlapSamples': config.overlapSamples,
              'captureMode': 'continuous_pcm_stream',
            },
          }),
        )
        .timeout(requestTimeout);
    final body = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_errorMessage(body, 'Backend session failed.'));
    }
    final session = _requireMap(body['session'], 'session');
    final id = session['id'];
    if (id is! String || id.trim().isEmpty) {
      throw StateError(
        'Backend session response did not include a session id.',
      );
    }
    return BackendUploadSession(
      id: id,
      expiresAtUtc: _dateTime(session['expiresAt']),
      maxSegmentBytes: _asInt(session['maxSegmentBytes']),
    );
  }

  Future<BackendUploadResult> uploadSegment({
    required AppConfig config,
    required CloudSecrets secrets,
    required BackendUploadSession session,
    required RecordingSegment segment,
    required File file,
  }) async {
    if (!session.isUsable) {
      return const BackendUploadResult.sessionExpired();
    }
    if (!await file.exists()) {
      return const BackendUploadResult.failure(
        'Local segment file is missing.',
      );
    }
    try {
      final plaintext = await file.readAsBytes();
      // Seal on-device before anything leaves the phone. The hash, byte count,
      // and PUT body below all operate on the ciphertext the cloud stores.
      final bytes = _encryptor == null
          ? plaintext
          : await _encryptor.seal(plaintext);
      final sha256Hex = sha256.convert(bytes).toString();
      final presignUri = _apiUri(
        config,
        '/api/mobile/v1/upload-sessions/${session.id}/segments/presign',
      );
      final presignResponse = await _httpClient
          .post(
            presignUri,
            headers: _jsonHeaders(secrets),
            body: jsonEncode({
              'sequenceNumber': segment.sequence,
              'capturedStartedAt': segment.startedAtUtc.toIso8601String(),
              'durationMillis': segment.canonicalDuration.inMilliseconds,
              'contentType': segment.contentType,
              'codec': segment.codec,
              'byteCount': bytes.length,
              'sha256Hex': sha256Hex,
              'metaData': {
                'captureSessionId': segment.captureSessionId,
                'startSample': segment.startSample,
                'sampleCount': segment.sampleCount,
                'storedSampleCount': segment.effectiveStoredSampleCount,
                'overlapSamples': segment.overlapSamples,
                'sampleRate': segment.sampleRate,
                'channels': segment.channels,
                if (segment.geoTag != null) 'geo': segment.geoTag!.toJson(),
              },
            }),
          )
          .timeout(requestTimeout);
      final presignBody = _decode(presignResponse);
      if (presignResponse.statusCode < 200 ||
          presignResponse.statusCode >= 300) {
        return BackendUploadResult.failure(
          _errorMessage(presignBody, 'Backend presign failed.'),
        );
      }
      final upload = presignBody['upload'] as Map<String, dynamic>;
      final serverSegment = presignBody['segment'] as Map<String, dynamic>;
      final uploadUri = _signedUploadUri(upload);
      final transferHeaders = _signedTransferHeaders(
        upload,
        expectedContentLength: bytes.length,
      );
      final uploadResponse = await _httpClient
          .put(uploadUri, headers: transferHeaders, body: bytes)
          .timeout(requestTimeout);
      if (uploadResponse.statusCode < 200 || uploadResponse.statusCode >= 300) {
        return BackendUploadResult.failure(
          'Signed upload failed: HTTP ${uploadResponse.statusCode} ${uploadResponse.reasonPhrase ?? ''}'
              .trim(),
        );
      }
      final segmentId = serverSegment['id'] as String;
      final completeUri = _apiUri(
        config,
        '/api/mobile/v1/upload-sessions/${session.id}/segments/$segmentId/complete',
      );
      final completeResponse = await _httpClient
          .post(
            completeUri,
            headers: _jsonHeaders(secrets),
            body: jsonEncode({
              'etag': uploadResponse.headers['etag'],
              'byteCount': bytes.length,
              'sha256Hex': sha256Hex,
              'capturedEndedAt': segment.endedAtUtc.toIso8601String(),
            }),
          )
          .timeout(requestTimeout);
      final completeBody = _decode(completeResponse);
      if (completeResponse.statusCode < 200 ||
          completeResponse.statusCode >= 300) {
        return BackendUploadResult.failure(
          _errorMessage(completeBody, 'Backend completion failed.'),
        );
      }
      final completedSegment =
          completeBody['segment'] as Map<String, dynamic>? ?? serverSegment;
      final remoteKey = completedSegment['storageKey'] as String?;
      if (remoteKey == null || remoteKey.trim().isEmpty) {
        return const BackendUploadResult.failure(
          'Backend completion did not return a storage key.',
        );
      }
      return BackendUploadResult.withSession(
        remoteKey: remoteKey,
        session: session,
      );
    } on TimeoutException {
      return BackendUploadResult.failure(
        'Backend upload timed out after ${requestTimeout.inSeconds} seconds.',
      );
    } catch (error) {
      return BackendUploadResult.failure('Backend upload failed: $error');
    }
  }

  Future<String?> postAlert({
    required AppConfig config,
    required CloudSecrets secrets,
    required String trigger,
    required DateTime occurredAtUtc,
    required String? segmentId,
    required int? sequence,
    Map<String, Object?> metadata = const {},
  }) async {
    try {
      final uri = _apiUri(config, '/api/mobile/v1/alerts');
      final response = await _httpClient
          .post(
            uri,
            headers: _jsonHeaders(secrets),
            body: jsonEncode({
              'trigger': trigger,
              'occurredAt': occurredAtUtc.toIso8601String(),
              'listenOffsetSeconds': 20,
              'segmentId': segmentId,
              'sequenceNumber': sequence,
              'metaData': metadata,
            }),
          )
          .timeout(requestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }
      return _errorMessage(_decode(response), 'Alert request failed.');
    } catch (error) {
      return 'Alert request failed: $error';
    }
  }

  Future<BackendPermanentSaveResult> saveSegmentsPermanently({
    required AppConfig config,
    required CloudSecrets secrets,
    required DateTime rangeStartedAtUtc,
    required DateTime rangeEndedAtUtc,
    required List<RecordingSegment> segments,
  }) async {
    if (segments.isEmpty) {
      return const BackendPermanentSaveResult.failure(
        'No uploaded segments were available for permanent save.',
      );
    }
    try {
      final uri = _apiUri(config, '/api/mobile/v1/permanent-saves');
      final response = await _httpClient
          .post(
            uri,
            headers: _jsonHeaders(secrets),
            body: jsonEncode({
              'provider': canonicalProviderName(config.cloudProvider),
              'rangeStartedAt': rangeStartedAtUtc.toIso8601String(),
              'rangeEndedAt': rangeEndedAtUtc.toIso8601String(),
              'segments': segments
                  .map(
                    (segment) => {
                      'id': segment.id,
                      'storageKey': segment.remoteKey,
                      'sequenceNumber': segment.sequence,
                      'capturedStartedAt': segment.startedAtUtc
                          .toIso8601String(),
                      'capturedEndedAt': segment.endedAtUtc.toIso8601String(),
                      'durationMillis':
                          segment.canonicalDuration.inMilliseconds,
                      'contentType': segment.contentType,
                      'codec': segment.codec,
                      'byteCount': segment.byteSize,
                      'metaData': {
                        'captureSessionId': segment.captureSessionId,
                        'startSample': segment.startSample,
                        'sampleCount': segment.sampleCount,
                        'storedSampleCount': segment.effectiveStoredSampleCount,
                        'overlapSamples': segment.overlapSamples,
                        'sampleRate': segment.sampleRate,
                        'channels': segment.channels,
                        if (segment.geoTag != null)
                          'geo': segment.geoTag!.toJson(),
                      },
                    },
                  )
                  .toList(),
            }),
          )
          .timeout(requestTimeout);
      final body = _decode(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return BackendPermanentSaveResult.failure(
          _errorMessage(body, 'Permanent save failed.'),
        );
      }
      final remoteKeys = _permanentRemoteKeys(body);
      if (remoteKeys.isEmpty) {
        return const BackendPermanentSaveResult.failure(
          'Permanent save did not return storage keys.',
        );
      }
      return BackendPermanentSaveResult.success(remoteKeys);
    } on TimeoutException {
      return BackendPermanentSaveResult.failure(
        'Permanent save timed out after ${requestTimeout.inSeconds} seconds.',
      );
    } catch (error) {
      return BackendPermanentSaveResult.failure(
        'Permanent save failed: $error',
      );
    }
  }

  /// Registers (or rotates) this device and returns the issued device token.
  /// Identity is taken from the `x-supabase-auth` header when a Supabase token
  /// is present; otherwise the backend's registration posture applies.
  Future<DeviceRegistration> registerDevice({
    required AppConfig config,
    required CloudSecrets secrets,
    required String platform,
    required String installId,
    required String consentVersion,
    bool recordingIndicatorAcknowledged = true,
    String? appVersion,
    String? osVersion,
    String? displayName,
    String? legalRegion,
  }) async {
    final uri = _apiUri(config, '/api/mobile/v1/devices/register');
    final response = await _httpClient
        .post(
          uri,
          headers: _identityHeaders(secrets),
          body: jsonEncode({
            'platform': platform,
            'installId': installId,
            'consentVersion': consentVersion,
            'recordingIndicatorAcknowledged': recordingIndicatorAcknowledged,
            'appVersion': ?appVersion,
            'osVersion': ?osVersion,
            'displayName': ?displayName,
            'legalRegion': ?legalRegion,
          }),
        )
        .timeout(requestTimeout);
    final body = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_errorMessage(body, 'Device registration failed.'));
    }
    final deviceToken = body['deviceToken'] as String?;
    if (deviceToken == null || deviceToken.trim().isEmpty) {
      throw StateError('Registration did not return a device token.');
    }
    return DeviceRegistration(
      accountId: body['accountId'] as String? ?? '',
      deviceId: body['deviceId'] as String? ?? '',
      deviceToken: deviceToken,
    );
  }

  Future<void> deleteAccount({
    required AppConfig config,
    required CloudSecrets secrets,
  }) async {
    final uri = _apiUri(config, '/api/mobile/v1/account');
    final response = await _httpClient
        .delete(uri, headers: _identityHeaders(secrets))
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _errorMessage(_decode(response), 'Account deletion failed.'),
      );
    }
  }

  /// Reports the device's current transfer gate to the backend so server-managed
  /// (Google Drive / OneDrive) copies are held while the device defers cloud
  /// streaming for low battery or a network-policy constraint, and resume when
  /// the device reports it is no longer paused. Returns null on success, or a
  /// short error string. Best-effort: callers treat failures as non-fatal.
  Future<String?> reportTransferState({
    required AppConfig config,
    required CloudSecrets secrets,
    required bool paused,
    required String? reason,
    required String networkPolicy,
    int? batteryLevel,
    bool? charging,
  }) async {
    try {
      final uri = _apiUri(config, '/api/mobile/v1/devices/transfer-state');
      final response = await _httpClient
          .post(
            uri,
            headers: _jsonHeaders(secrets),
            body: jsonEncode({
              'paused': paused,
              'reason': ?reason,
              'networkPolicy': networkPolicy,
              'batteryLevel': ?batteryLevel,
              'charging': ?charging,
            }),
          )
          .timeout(requestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }
      return _errorMessage(_decode(response), 'Transfer-state report failed.');
    } catch (error) {
      return 'Transfer-state report failed: $error';
    }
  }

  Future<List<Map<String, dynamic>>> listCloudConnections({
    required AppConfig config,
    required CloudSecrets secrets,
  }) async {
    final uri = _apiUri(config, '/api/mobile/v1/cloud-connections');
    final response = await _httpClient
        .get(uri, headers: _jsonHeaders(secrets))
        .timeout(requestTimeout);
    final body = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _errorMessage(body, 'Listing cloud connections failed.'),
      );
    }
    return _mapList(body['connections']);
  }

  /// Revokes a linked cloud destination, clearing its sealed credentials and
  /// skipping its pending copy jobs server-side.
  Future<void> revokeCloudConnection({
    required AppConfig config,
    required CloudSecrets secrets,
    required String connectionId,
  }) async {
    final uri = _apiUri(
      config,
      '/api/mobile/v1/cloud-connections/$connectionId/revoke',
    );
    final response = await _httpClient
        .post(uri, headers: _jsonHeaders(secrets))
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _errorMessage(_decode(response), 'Revoking cloud connection failed.'),
      );
    }
  }

  /// Begins a cloud link. Returns the parsed `oauth/start` response (state,
  /// authorizationUrl, requiredScope, ...).
  Future<Map<String, dynamic>> startCloudLink({
    required AppConfig config,
    required CloudSecrets secrets,
    required CloudProvider provider,
    String? redirectUri,
    String? folderPath,
    String? rootFolderId,
    String? displayName,
  }) async {
    final uri = _apiUri(config, '/api/mobile/v1/cloud-connections/oauth/start');
    final response = await _httpClient
        .post(
          uri,
          headers: _jsonHeaders(secrets),
          body: jsonEncode({
            'provider': canonicalProviderName(provider),
            'redirectUri': ?redirectUri,
            'folderPath': ?folderPath,
            'rootFolderId': ?rootFolderId,
            'displayName': ?displayName,
          }),
        )
        .timeout(requestTimeout);
    final body = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_errorMessage(body, 'Starting cloud link failed.'));
    }
    return body;
  }

  /// Completes a cloud link. For Google Drive / OneDrive pass either a
  /// Supabase-brokered [providerAccessToken] (preferred) or an
  /// [authorizationCode]. For iCloud pass [clientManagedAcknowledged] = true.
  Future<Map<String, dynamic>> completeCloudLink({
    required AppConfig config,
    required CloudSecrets secrets,
    required CloudProvider provider,
    required String state,
    String? providerAccessToken,
    String? providerRefreshToken,
    int? providerTokenExpiresIn,
    String? providerTokenScope,
    String? authorizationCode,
    String? redirectUri,
    bool? clientManagedAcknowledged,
    String? displayName,
    String? providerAccountId,
    String? folderPath,
    String? rootFolderId,
  }) async {
    final uri = _apiUri(
      config,
      '/api/mobile/v1/cloud-connections/oauth/complete',
    );
    final response = await _httpClient
        .post(
          uri,
          headers: _jsonHeaders(secrets),
          body: jsonEncode({
            'provider': canonicalProviderName(provider),
            'state': state,
            'providerAccessToken': ?providerAccessToken,
            'providerRefreshToken': ?providerRefreshToken,
            'providerTokenExpiresIn': ?providerTokenExpiresIn,
            'providerTokenScope': ?providerTokenScope,
            'authorizationCode': ?authorizationCode,
            'redirectUri': ?redirectUri,
            'clientManagedAcknowledged': ?clientManagedAcknowledged,
            'displayName': ?displayName,
            'providerAccountId': ?providerAccountId,
            'folderPath': ?folderPath,
            'rootFolderId': ?rootFolderId,
          }),
        )
        .timeout(requestTimeout);
    final body = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_errorMessage(body, 'Completing cloud link failed.'));
    }
    return body;
  }

  /// Lists iCloud client-managed copy jobs the iOS client must mirror into the
  /// user's iCloud container, each with a short-lived S3 download link.
  Future<List<Map<String, dynamic>>> listCloudCopyJobs({
    required AppConfig config,
    required CloudSecrets secrets,
    CloudProvider provider = CloudProvider.iCloudDrive,
    int limit = 25,
  }) async {
    final uri = _apiUri(config, '/api/mobile/v1/cloud-copy-jobs').replace(
      queryParameters: {
        'provider': canonicalProviderName(provider),
        'limit': '$limit',
      },
    );
    final response = await _httpClient
        .get(uri, headers: _jsonHeaders(secrets))
        .timeout(requestTimeout);
    final body = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_errorMessage(body, 'Listing cloud copy jobs failed.'));
    }
    return _mapList(body['jobs']);
  }

  /// Marks a client-managed (iCloud) copy job complete after the native layer
  /// has written the file into the user's iCloud container.
  Future<void> completeCloudCopyJob({
    required AppConfig config,
    required CloudSecrets secrets,
    required String jobId,
    String? providerFileId,
    String? destinationKey,
  }) async {
    final uri = _apiUri(
      config,
      '/api/mobile/v1/cloud-copy-jobs/$jobId/complete',
    );
    final response = await _httpClient
        .post(
          uri,
          headers: _jsonHeaders(secrets),
          body: jsonEncode({
            'providerFileId': ?providerFileId,
            'destinationKey': ?destinationKey,
          }),
        )
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _errorMessage(_decode(response), 'Completing cloud copy job failed.'),
      );
    }
  }

  List<Map<String, dynamic>> _mapList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value.whereType<Map<String, dynamic>>().toList();
  }

  bool canUseBackend(AppConfig config, CloudSecrets secrets) {
    return config.backendBaseUrl.trim().isNotEmpty &&
        secrets.hasBackendDeviceToken;
  }

  Uri _apiUri(AppConfig config, String path) {
    final base = Uri.parse(config.backendBaseUrl.trim());
    if (base.host.trim().isEmpty) {
      throw const FormatException('Backend URL must include a host.');
    }
    if (base.scheme != 'https' &&
        base.host != 'localhost' &&
        base.host != '127.0.0.1') {
      throw const FormatException(
        'Backend URL must use HTTPS except localhost development.',
      );
    }
    final baseSegments = base.pathSegments.where((part) => part.isNotEmpty);
    return base.replace(
      pathSegments: [
        ...baseSegments,
        ...path.split('/').where((p) => p.isNotEmpty),
      ],
      query: '',
      fragment: '',
    );
  }

  Map<String, String> _jsonHeaders(CloudSecrets secrets) {
    final headers = <String, String>{
      'authorization': 'Bearer ${secrets.backendDeviceToken.trim()}',
      'content-type': 'application/json',
      'accept': 'application/json',
    };
    if (secrets.hasSupabaseToken) {
      headers['x-supabase-auth'] =
          'Bearer ${secrets.supabaseAccessToken.trim()}';
    }
    return headers;
  }

  /// Headers for identity-only calls (registration / cloud linking) that are
  /// authorized by the Supabase token rather than a device token.
  Map<String, String> _identityHeaders(CloudSecrets secrets) {
    final headers = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
    };
    if (secrets.hasSupabaseToken) {
      headers['x-supabase-auth'] =
          'Bearer ${secrets.supabaseAccessToken.trim()}';
    }
    if (secrets.hasBackendDeviceToken) {
      headers['authorization'] = 'Bearer ${secrets.backendDeviceToken.trim()}';
    }
    return headers;
  }

  /// Maps the app's provider enum to the backend's canonical provider strings.
  static String canonicalProviderName(CloudProvider provider) {
    switch (provider) {
      case CloudProvider.googleDrive:
        return 'google_drive';
      case CloudProvider.oneDrive:
        return 'microsoft_onedrive';
      case CloudProvider.iCloudDrive:
        return 'apple_icloud';
      case CloudProvider.s3:
        return 's3';
    }
  }

  Map<String, String> _signedTransferHeaders(
    Map<String, dynamic> upload, {
    required int expectedContentLength,
  }) {
    final headers = <String, String>{};
    final seenHeaderNames = <String>{};
    for (final header in upload['headers'] as List<dynamic>? ?? const []) {
      final item = header as Map<String, dynamic>;
      final name = (item['name'] as String).trim();
      final value = item['value'] as String;
      final lowerName = name.toLowerCase();
      const forbiddenHeaders = {
        'authorization',
        'cookie',
        'host',
        'transfer-encoding',
      };
      if (name.isEmpty ||
          name.contains(':') ||
          name.contains('\r') ||
          name.contains('\n') ||
          value.contains('\r') ||
          value.contains('\n') ||
          forbiddenHeaders.contains(lowerName)) {
        throw FormatException('Signed upload header is not allowed: $name.');
      }
      if (!seenHeaderNames.add(lowerName)) {
        throw FormatException('Signed upload header is duplicated: $name.');
      }
      if (lowerName == 'content-length') {
        final canonicalValue = value.trim();
        final signedLength =
            RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(canonicalValue)
            ? int.tryParse(canonicalValue)
            : null;
        if (signedLength == null) {
          throw const FormatException(
            'Signed upload content-length must be a non-negative integer.',
          );
        }
        if (signedLength != expectedContentLength) {
          throw FormatException(
            'Signed upload content-length $signedLength does not match '
            'payload byte count $expectedContentLength.',
          );
        }
        // http.Request derives its transport content length from bodyBytes.
        // Keeping this identical signed header in the request also satisfies
        // providers whose presigned signature includes content-length.
        headers[name] = canonicalValue;
        continue;
      }
      headers[name] = value;
    }
    return headers;
  }

  Uri _signedUploadUri(Map<String, dynamic> upload) {
    final method = upload['method']?.toString().toUpperCase();
    if (method != 'PUT') {
      throw FormatException('Signed upload method must be PUT, got $method.');
    }
    final uri = Uri.parse(upload['url'] as String);
    if (uri.host.trim().isEmpty) {
      throw const FormatException('Signed upload URL must include a host.');
    }
    if (uri.scheme != 'https' &&
        uri.host != 'localhost' &&
        uri.host != '127.0.0.1') {
      throw const FormatException(
        'Signed upload URL must use HTTPS except localhost development.',
      );
    }
    return uri;
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.body.trim().isEmpty) {
      return const {};
    }
    final value = jsonDecode(response.body);
    return value is Map<String, dynamic> ? value : const {};
  }

  /// Returns [value] as a JSON object, or throws a clean [StateError] (rather
  /// than letting a raw `as` cast surface an uncaught `TypeError`) when an
  /// authenticated-but-malformed backend response omits an expected object.
  Map<String, dynamic> _requireMap(Object? value, String what) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    throw StateError('Backend response is missing a "$what" object.');
  }

  String _errorMessage(Map<String, dynamic> body, String fallback) {
    final message = body['message'] ?? body['error'];
    return message?.toString() ?? fallback;
  }

  Map<String, String> _permanentRemoteKeys(Map<String, dynamic> body) {
    final rawSegments =
        body['segments'] ??
        (body['permanentSave'] is Map<String, dynamic>
            ? (body['permanentSave'] as Map<String, dynamic>)['segments']
            : null);
    final remoteKeys = <String, String>{};
    if (rawSegments is! List<dynamic>) {
      return remoteKeys;
    }
    for (final rawSegment in rawSegments) {
      if (rawSegment is! Map<String, dynamic>) {
        continue;
      }
      final id =
          rawSegment['id'] ??
          rawSegment['segmentId'] ??
          rawSegment['clientSegmentId'];
      final key =
          rawSegment['permanentStorageKey'] ??
          rawSegment['permanentRemoteKey'] ??
          rawSegment['storageKey'];
      if (id != null && key != null && key.toString().trim().isNotEmpty) {
        remoteKeys[id.toString()] = key.toString();
      }
    }
    return remoteKeys;
  }

  DateTime? _dateTime(Object? value) {
    if (value == null) {
      return null;
    }
    return DateTime.tryParse(value.toString())?.toUtc();
  }

  int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  int _maxSegmentBytes(AppConfig config) {
    final bytesPerSecond = config.effectiveBitRate ~/ 8;
    final seconds = config.segmentDuration.inSeconds + config.overlapSeconds;
    return bytesPerSecond * seconds + 44 + 4096;
  }

  void close() {
    _httpClient.close();
  }
}
