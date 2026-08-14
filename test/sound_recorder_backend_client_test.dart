import 'dart:convert';
import 'dart:io';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_provider.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/services/sound_recorder_backend_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory tempDir;
  late File segmentFile;
  late RecordingSegment segment;

  const config = AppConfig(
    deviceId: 'device-a',
    backendBaseUrl: 'https://backend.example',
  );
  const secrets = CloudSecrets(backendDeviceToken: 'device-token');
  const session = BackendUploadSession(
    id: 'session-1',
    expiresAtUtc: null,
    maxSegmentBytes: 10 * 1024 * 1024,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'audio_dashcam_backend_test_',
    );
    segmentFile = File('${tempDir.path}/segment.wav');
    await segmentFile.writeAsBytes(const [0, 0, 1, 0]);
    final startedAtUtc = DateTime.utc(2026, 1, 2, 3, 4, 5);
    segment = RecordingSegment(
      id: 'segment-1',
      startedAtUtc: startedAtUtc,
      endedAtUtc: startedAtUtc.add(const Duration(minutes: 1)),
      localPath: segmentFile.path,
      byteSize: 4,
      uploadStatus: SegmentUploadStatus.pending,
      container: 'wav',
      codec: 'pcm_s16le',
      sampleRate: 16000,
      channels: 1,
      sampleCount: 960000,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('rejects signed upload methods other than PUT', () async {
    final client = SoundRecorderBackendClient(
      httpClient: _presignOnlyClient(
        upload: {
          'method': 'POST',
          'url': 'https://uploads.example/segment.wav',
          'headers': <Object>[],
        },
      ),
    );

    final result = await client.uploadSegment(
      config: config,
      secrets: secrets,
      session: session,
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, contains('PUT'));
    client.close();
  });

  test('rejects non-HTTPS signed upload URLs', () async {
    final client = SoundRecorderBackendClient(
      httpClient: _presignOnlyClient(
        upload: {
          'method': 'PUT',
          'url': 'http://uploads.example/segment.wav',
          'headers': <Object>[],
        },
      ),
    );

    final result = await client.uploadSegment(
      config: config,
      secrets: secrets,
      session: session,
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, contains('HTTPS'));
    client.close();
  });

  test('rejects forbidden signed upload headers', () async {
    final client = SoundRecorderBackendClient(
      httpClient: _presignOnlyClient(
        upload: {
          'method': 'PUT',
          'url': 'https://uploads.example/segment.wav',
          'headers': [
            {'name': 'Authorization', 'value': 'Bearer not-allowed'},
          ],
        },
      ),
    );

    final result = await client.uploadSegment(
      config: config,
      secrets: secrets,
      session: session,
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, contains('not allowed'));
    client.close();
  });

  test('uses the exact signed content length for the upload PUT', () async {
    var sawPresign = false;
    var sawUpload = false;
    var sawComplete = false;
    await File('${tempDir.path}/segment.features.json').writeAsString(
      jsonEncode({
        'version': 2,
        'summary': {
          'heuristic': true,
          'classificationCounts': {'suddenLoudNoise': 1},
        },
      }),
    );
    final client = SoundRecorderBackendClient(
      httpClient: MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/presign')) {
          sawPresign = true;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['byteCount'], 4);
          final metadata = body['metaData'] as Map<String, dynamic>;
          expect(metadata['acousticAnalysis'], {
            'heuristic': true,
            'classificationCounts': {'suddenLoudNoise': 1},
          });
          return http.Response(
            jsonEncode({
              'upload': {
                'method': 'PUT',
                'url': 'https://uploads.example/segment.wav',
                'headers': [
                  {'name': 'Content-Length', 'value': '4'},
                  {'name': 'Content-Type', 'value': 'audio/wav'},
                ],
              },
              'segment': {
                'id': 'server-segment-1',
                'storageKey': 'audio-dashcam/device-a/segment.wav',
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PUT' && request.url.host == 'uploads.example') {
          sawUpload = true;
          expect(request.headers['content-length'], '4');
          expect(request.headers['content-type'], 'audio/wav');
          expect(request.contentLength, 4);
          expect(request.bodyBytes, const [0, 0, 1, 0]);
          return http.Response('', 200, headers: const {'etag': 'etag-1'});
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/complete')) {
          sawComplete = true;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['byteCount'], 4);
          expect(body['etag'], 'etag-1');
          return http.Response(
            jsonEncode({
              'segment': {
                'id': 'server-segment-1',
                'storageKey': 'audio-dashcam/device-a/segment.wav',
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        fail('unexpected request: ${request.method} ${request.url}');
      }),
    );

    final result = await client.uploadSegment(
      config: config,
      secrets: secrets,
      session: session,
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isTrue);
    expect(result.remoteKey, 'audio-dashcam/device-a/segment.wav');
    expect(sawPresign, isTrue);
    expect(sawUpload, isTrue);
    expect(sawComplete, isTrue);
    client.close();
  });

  test('rejects a signed content length that mismatches the payload', () async {
    var uploadAttempted = false;
    final client = SoundRecorderBackendClient(
      httpClient: MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/presign')) {
          return http.Response(
            jsonEncode({
              'upload': {
                'method': 'PUT',
                'url': 'https://uploads.example/segment.wav',
                'headers': [
                  {'name': 'Content-Length', 'value': '5'},
                ],
              },
              'segment': {
                'id': 'server-segment-1',
                'storageKey': 'audio-dashcam/device-a/segment.wav',
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PUT') {
          uploadAttempted = true;
        }
        fail('unexpected request: ${request.method} ${request.url}');
      }),
    );

    final result = await client.uploadSegment(
      config: config,
      secrets: secrets,
      session: session,
      segment: segment,
      file: segmentFile,
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, contains('does not match payload byte count 4'));
    expect(uploadAttempted, isFalse);
    client.close();
  });

  test('returns an alert error for unsafe backend URLs', () async {
    final client = SoundRecorderBackendClient(
      httpClient: MockClient((_) async {
        fail('unsafe backend URL should fail before an HTTP request is sent');
      }),
    );

    final error = await client.postAlert(
      config: const AppConfig(
        deviceId: 'device-a',
        backendBaseUrl: 'http://backend.example',
      ),
      secrets: secrets,
      trigger: 'manual',
      occurredAtUtc: DateTime.utc(2026, 1, 2, 3, 4, 5),
      segmentId: 'segment-1',
      sequence: 1,
    );

    expect(error, contains('HTTPS'));
    client.close();
  });

  test('deletes account with Supabase identity header', () async {
    final client = SoundRecorderBackendClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/mobile/v1/account');
        expect(request.headers['x-supabase-auth'], 'Bearer user-jwt');
        expect(request.headers['authorization'], isNull);
        expect(jsonDecode(request.body), {'confirmEmail': 'user@example.com'});
        return http.Response('{"ok":true}', 200);
      }),
    );

    await client.deleteAccount(
      config: config,
      secrets: const CloudSecrets(supabaseAccessToken: 'user-jwt'),
      confirmedEmail: ' user@example.com ',
    );

    client.close();
  });

  test('posts the durable Rust device heartbeat with the device token', () async {
    final client = SoundRecorderBackendClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/mobile/v1/devices/heartbeat');
        expect(request.headers['authorization'], 'Bearer device-token');
        return http.Response(
          '{"ok":true,"deviceId":"device-a","serverTime":"2026-07-25T12:00:00Z"}',
          200,
        );
      }),
    );

    final error = await client.heartbeatDevice(
      config: config,
      secrets: secrets,
    );

    expect(error, isNull);
    client.close();
  });

  test('revokes a Rust device token with Supabase identity', () async {
    final client = SoundRecorderBackendClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/mobile/v1/devices/device-a/revoke');
        expect(request.headers['x-supabase-auth'], 'Bearer user-jwt');
        expect(request.headers['authorization'], isNull);
        return http.Response(
          '{"ok":true,"installId":"device-a","backendTokensRevoked":1}',
          200,
        );
      }),
    );

    final error = await client.revokeDevice(
      config: config,
      secrets: const CloudSecrets(supabaseAccessToken: 'user-jwt'),
      installId: 'device-a',
    );

    expect(error, isNull);
    client.close();
  });

  test(
    'completes the desktop manual cloud OAuth flow with the pinned redirect',
    () async {
      var requestNumber = 0;
      final client = SoundRecorderBackendClient(
        httpClient: MockClient((request) async {
          requestNumber += 1;
          expect(request.method, 'POST');
          expect(request.headers['authorization'], 'Bearer device-token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (requestNumber == 1) {
            expect(
              request.url.path,
              '/api/mobile/v1/cloud-connections/oauth/start',
            );
            expect(body['provider'], 'microsoft_onedrive');
            expect(
              body['redirectUri'],
              'https://backend.example/oauth/manual-callback',
            );
            return http.Response(
              jsonEncode({
                'ok': true,
                'provider': 'microsoft_onedrive',
                'state': 'state-1',
                'authorizationUrl':
                    'https://login.microsoftonline.com/authorize',
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          expect(
            request.url.path,
            '/api/mobile/v1/cloud-connections/oauth/complete',
          );
          expect(body['provider'], 'microsoft_onedrive');
          expect(body['state'], 'state-1');
          expect(body['authorizationCode'], 'one-time-code');
          expect(
            body['redirectUri'],
            'https://backend.example/oauth/manual-callback',
          );
          return http.Response(
            jsonEncode({
              'ok': true,
              'connection': {
                'id': 'connection-1',
                'provider': 'microsoft_onedrive',
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

      final started = await client.startCloudLink(
        config: config,
        secrets: secrets,
        provider: CloudProvider.oneDrive,
        redirectUri: 'https://backend.example/oauth/manual-callback',
      );
      expect(started['state'], 'state-1');

      final completed = await client.completeCloudLink(
        config: config,
        secrets: secrets,
        provider: CloudProvider.oneDrive,
        state: started['state'] as String,
        authorizationCode: 'one-time-code',
        redirectUri: 'https://backend.example/oauth/manual-callback',
      );
      expect(
        (completed['connection'] as Map<String, dynamic>)['id'],
        'connection-1',
      );
      expect(requestNumber, 2);
      client.close();
    },
  );

  test(
    'records R2 account status without sending direct storage credentials',
    () async {
      var requestNumber = 0;
      final client = SoundRecorderBackendClient(
        httpClient: MockClient((request) async {
          requestNumber += 1;
          expect(request.headers['authorization'], 'Bearer device-token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['provider'], 'cloudflare_r2');
          expect(request.body, isNot(contains('r2-secret')));
          expect(request.body, isNot(contains('r2-access')));
          if (requestNumber == 1) {
            expect(
              request.url.path,
              '/api/mobile/v1/cloud-connections/oauth/start',
            );
            expect(body['displayName'], 'sonus-backups');
            expect(body['folderPath'], 'recordings');
            return http.Response(
              jsonEncode({
                'ok': true,
                'provider': 'cloudflare_r2',
                'clientManaged': true,
                'state': 'r2-state',
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          expect(
            request.url.path,
            '/api/mobile/v1/cloud-connections/oauth/complete',
          );
          expect(body['state'], 'r2-state');
          expect(body['clientManagedAcknowledged'], isTrue);
          return http.Response(
            jsonEncode({
              'ok': true,
              'connection': {
                'id': 'r2-connection',
                'provider': 'cloudflare_r2',
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

      final result = await client.registerClientManagedStorageConnection(
        config: config,
        secrets: secrets.copyWith(
          s3AccessKeyId: 'r2-access',
          s3SecretAccessKey: 'r2-secret',
        ),
        provider: 'cloudflare_r2',
        displayName: 'sonus-backups',
        folderPath: 'recordings',
      );

      expect(
        (result['connection'] as Map<String, dynamic>)['id'],
        'r2-connection',
      );
      expect(requestNumber, 2);
      client.close();
    },
  );

  test('detects Cloudflare R2 endpoints without misclassifying S3', () {
    expect(
      SoundRecorderBackendClient.directStorageProviderName(
        'https://account.r2.cloudflarestorage.com',
      ),
      'cloudflare_r2',
    );
    expect(
      SoundRecorderBackendClient.directStorageProviderName(
        'https://s3.us-east-1.amazonaws.com',
      ),
      'amazon_s3',
    );
  });

  test('posts permanent save requests and maps storage keys', () async {
    final client = SoundRecorderBackendClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/mobile/v1/permanent-saves');
        expect(request.headers['authorization'], 'Bearer device-token');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(
          body['provider'],
          SoundRecorderBackendClient.canonicalProviderName(
            CloudProvider.googleDrive,
          ),
        );
        expect(body['provider'], 'google_drive');
        expect(body['rangeStartedAt'], '2026-01-02T03:04:05.000Z');
        final segments = body['segments'] as List<dynamic>;
        expect(segments, hasLength(1));
        expect(
          (segments.single as Map<String, dynamic>)['storageKey'],
          'audio-dashcam/device-a/segment.wav',
        );
        return http.Response(
          jsonEncode({
            'segments': [
              {
                'id': 'segment-1',
                'permanentStorageKey':
                    'permanent/google-drive/device-a/segment.wav',
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    final result = await client.saveSegmentsPermanently(
      config: const AppConfig(
        deviceId: 'device-a',
        cloudProvider: CloudProvider.googleDrive,
        backendBaseUrl: 'https://backend.example',
      ),
      secrets: secrets,
      rangeStartedAtUtc: DateTime.utc(2026, 1, 2, 3, 4, 5),
      rangeEndedAtUtc: DateTime.utc(2026, 1, 2, 3, 5, 5),
      segments: [
        segment.copyWith(
          uploadStatus: SegmentUploadStatus.uploaded,
          remoteKey: 'audio-dashcam/device-a/segment.wav',
        ),
      ],
    );

    expect(result.isSuccess, isTrue);
    expect(
      result.remoteKeysBySegmentId['segment-1'],
      'permanent/google-drive/device-a/segment.wav',
    );
    client.close();
  });
}

MockClient _presignOnlyClient({required Map<String, Object?> upload}) {
  return MockClient((request) async {
    if (request.method == 'POST' && request.url.path.endsWith('/presign')) {
      return http.Response(
        jsonEncode({
          'upload': upload,
          'segment': {
            'id': 'server-segment-1',
            'storageKey': 'audio-dashcam/device-a/segment.wav',
          },
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    fail('unexpected request: ${request.method} ${request.url}');
  });
}
