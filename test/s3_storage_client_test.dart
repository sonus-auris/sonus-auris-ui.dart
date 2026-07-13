import 'dart:io';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/services/s3_storage_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
