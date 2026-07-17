import 'dart:io';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/services/crypto/key_manager.dart';
import 'package:audio_dashcam/src/services/crypto/segment_cipher.dart';
import 'package:audio_dashcam/src/services/crypto/segment_encryptor.dart';
import 'package:audio_dashcam/src/services/s3_storage_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_key_store.dart';

void main() {
  late Directory tempDir;
  late File segmentFile;
  late RecordingSegment segment;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('audio_dashcam_s3_test_');
    segmentFile = File('${tempDir.path}/segment.m4a');
    await segmentFile.writeAsBytes(const [1, 2, 3, 4]);
    final startedAtUtc = DateTime.utc(2026, 1, 2, 3, 4, 5);
    segment = RecordingSegment(
      id: '2026-01-02T03-04-05-000z',
      startedAtUtc: startedAtUtc,
      endedAtUtc: startedAtUtc.add(const Duration(minutes: 1)),
      localPath: segmentFile.path,
      byteSize: 4,
      uploadStatus: SegmentUploadStatus.pending,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('rejects non-HTTPS custom endpoints before upload', () async {
    final client = S3StorageClient();
    final result = await client.uploadSegment(
      config: const AppConfig(
        deviceId: 'device-a',
        s3Bucket: 'bucket-a',
        s3Region: 'us-east-1',
        s3Endpoint: 'http://example.com',
      ),
      secrets: const CloudSecrets(
        s3AccessKeyId: 'access',
        s3SecretAccessKey: 'secret',
      ),
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, contains('HTTPS'));
    client.close();
  });

  test('rejects invalid direct AWS bucket names before upload', () async {
    final client = S3StorageClient();
    final result = await client.uploadSegment(
      config: const AppConfig(
        deviceId: 'device-a',
        s3Bucket: 'Bad_Bucket',
        s3Region: 'us-east-1',
      ),
      secrets: const CloudSecrets(
        s3AccessKeyId: 'access',
        s3SecretAccessKey: 'secret',
      ),
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, contains('lowercase'));
    client.close();
  });

  test('Cloudflare R2 uses path-style addressing and region auto', () async {
    late http.Request captured;
    final client = S3StorageClient(
      httpClient: MockClient((request) async {
        captured = request;
        expect(request.bodyBytes, const [1, 2, 3, 4]);
        return http.Response('', 200);
      }),
    );

    final result = await client.uploadSegment(
      config: const AppConfig(
        deviceId: 'device-a',
        s3Bucket: 'sonus-audio',
        s3Region: 'auto',
        s3Endpoint: 'https://account-id.r2.cloudflarestorage.com',
      ),
      secrets: const CloudSecrets(
        s3AccessKeyId: 'r2-access',
        s3SecretAccessKey: 'r2-secret',
      ),
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isTrue);
    expect(captured.url.host, 'account-id.r2.cloudflarestorage.com');
    expect(
      captured.url.path,
      '/sonus-audio/audio-dashcam/device-a/2026/01/02/03/2026-01-02T03-04-05-000z.m4a',
    );
    expect(captured.headers, isNot(contains('x-amz-server-side-encryption')));
    expect(
      captured.headers['authorization'],
      contains('/auto/s3/aws4_request'),
    );
    expect(captured.headers['host'], 'account-id.r2.cloudflarestorage.com');
    client.close();
  });

  test('uploads the FFT sidecar beside its audio segment', () async {
    final sidecar = File('${tempDir.path}/segment.features.json');
    await sidecar.writeAsString('{"version":2,"summary":{"maxDb":-4}}');
    final captured = <http.Request>[];
    final client = S3StorageClient(
      httpClient: MockClient((request) async {
        captured.add(request);
        return http.Response('', 200);
      }),
    );

    final result = await client.uploadSegment(
      config: const AppConfig(
        deviceId: 'device-a',
        s3Bucket: 'bucket-a',
        s3Region: 'us-east-1',
      ),
      secrets: const CloudSecrets(
        s3AccessKeyId: 'access',
        s3SecretAccessKey: 'secret',
      ),
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isTrue);
    expect(captured, hasLength(2));
    expect(
      captured.map((request) => request.url.path),
      containsAll([
        '/audio-dashcam/device-a/2026/01/02/03/2026-01-02T03-04-05-000z.m4a',
        '/audio-dashcam/device-a/2026/01/02/03/2026-01-02T03-04-05-000z.features.json',
      ]),
    );
    final sidecarRequest = captured.singleWhere(
      (request) => request.url.path.endsWith('.features.json'),
    );
    expect(sidecarRequest.headers['content-type'], 'application/json');
    expect(sidecarRequest.body, contains('"maxDb":-4'));
    client.close();
  });

  test('encrypts audio and FFT sidecar independently before S3 PUT', () async {
    const sidecarPlaintext = '{"version":2,"summary":{"maxDb":-4}}';
    await File(
      '${tempDir.path}/segment.features.json',
    ).writeAsString(sidecarPlaintext);
    final requests = <http.Request>[];
    final encryptor = SegmentEncryptor(
      keyManager: KeyManager(store: InMemoryKeyStore()),
    );
    final client = S3StorageClient(
      encryptor: encryptor,
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('', 200);
      }),
    );

    final result = await client.uploadSegment(
      config: const AppConfig(
        deviceId: 'device-a',
        s3Bucket: 'bucket-a',
        s3Region: 'us-east-1',
      ),
      secrets: const CloudSecrets(
        s3AccessKeyId: 'access',
        s3SecretAccessKey: 'secret',
      ),
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isTrue);
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(SegmentCipher.looksEncrypted(request.bodyBytes), isTrue);
    }
    final audioRequest = requests.singleWhere(
      (request) => request.url.path.endsWith('.m4a'),
    );
    final sidecarRequest = requests.singleWhere(
      (request) => request.url.path.endsWith('.features.json'),
    );
    expect(await encryptor.open(audioRequest.bodyBytes), const [1, 2, 3, 4]);
    expect(
      String.fromCharCodes(await encryptor.open(sidecarRequest.bodyBytes)),
      sidecarPlaintext,
    );
    expect(sidecarRequest.headers['content-type'], 'application/octet-stream');
    expect(audioRequest.bodyBytes, isNot(equals(sidecarRequest.bodyBytes)));
    client.close();
  });

  test('deletes FFT sidecar before its rolling audio object', () async {
    final paths = <String>[];
    final client = S3StorageClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'DELETE');
        paths.add(request.url.path);
        return http.Response('', 204);
      }),
    );

    final error = await client.deleteSegmentObjects(
      config: const AppConfig(
        deviceId: 'device-a',
        s3Bucket: 'bucket-a',
        s3Region: 'us-east-1',
      ),
      secrets: const CloudSecrets(
        s3AccessKeyId: 'access',
        s3SecretAccessKey: 'secret',
      ),
      audioKey: 'audio-dashcam/device-a/2026/01/02/03/segment.m4a',
    );

    expect(error, isNull);
    expect(paths, [
      '/audio-dashcam/device-a/2026/01/02/03/segment.features.json',
      '/audio-dashcam/device-a/2026/01/02/03/segment.m4a',
    ]);
    client.close();
  });

  test('copies cloud-only segments into the permanent S3 prefix', () async {
    final cloudOnly = segment.copyWith(
      localPath: null,
      uploadStatus: SegmentUploadStatus.uploaded,
      remoteKey: 'audio-dashcam/device-a/2026/01/02/03/segment.m4a',
    );
    final client = S3StorageClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(
          request.url.path,
          '/audio-dashcam/device-a/permanent/2026/01/02/03/2026-01-02T03-04-05-000z.m4a',
        );
        expect(
          request.headers['x-amz-copy-source'],
          'bucket-a/audio-dashcam/device-a/2026/01/02/03/segment.m4a',
        );
        return http.Response('<CopyObjectResult />', 200);
      }),
    );

    final result = await client.saveSegmentPermanently(
      config: const AppConfig(
        deviceId: 'device-a',
        s3Bucket: 'bucket-a',
        s3Region: 'us-east-1',
      ),
      secrets: const CloudSecrets(
        s3AccessKeyId: 'access',
        s3SecretAccessKey: 'secret',
      ),
      segment: cloudOnly,
    );

    expect(result.isSuccess, isTrue);
    expect(
      result.remoteKey,
      'audio-dashcam/device-a/permanent/2026/01/02/03/2026-01-02T03-04-05-000z.m4a',
    );
    client.close();
  });
}
