import 'dart:convert';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_provider.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/services/icloud_sync_service.dart';
import 'package:audio_dashcam/src/services/sound_recorder_backend_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('audio_dashcam/icloud');
  const config = AppConfig(
    deviceId: 'device-a',
    cloudProvider: CloudProvider.iCloudDrive,
    backendBaseUrl: 'https://backend.example',
  );
  const secrets = CloudSecrets(backendDeviceToken: 'device-token');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> nativeCalls;

  void mockNative({required bool available}) {
    nativeCalls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      switch (call.method) {
        case 'isAvailable':
          return available;
        case 'importSegment':
          return 'icloud://Documents/${call.arguments['destinationKey']}';
      }
      return null;
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  // Builds a backend client + iCloud client sharing one MockClient that serves
  // the job list, the (https) segment download, and the completion call.
  ({SoundRecorderBackendClient backend, IcloudSyncService icloud}) harness(
    String downloadUrl, {
    List<MethodCall> completions = const [],
  }) {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/cloud-copy-jobs')) {
        return http.Response(
          jsonEncode({
            'ok': true,
            'jobs': [
              {
                'job': {'id': 'job-1', 'destinationKey': 'folder/seg-1.wav'},
                'download': {'url': downloadUrl},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.contains('/cloud-copy-jobs/') && path.endsWith('/complete')) {
        return http.Response('{"ok":true}', 200);
      }
      if (request.url.host == 'dl.example') {
        return http.Response.bytes(const [1, 2, 3, 4], 200);
      }
      return http.Response('not found', 404);
    });
    return (
      backend: SoundRecorderBackendClient(httpClient: client),
      icloud: IcloudSyncService(httpClient: client),
    );
  }

  test('skips when iCloud is unavailable', () async {
    mockNative(available: false);
    final h = harness('https://dl.example/seg-1');
    final result = await h.icloud.syncPendingJobs(
      backendClient: h.backend,
      config: config,
      secrets: secrets,
    );
    expect(result.skipped, isTrue);
    expect(nativeCalls.map((c) => c.method), ['isAvailable']);
  });

  test('downloads, writes to iCloud, and completes the job', () async {
    mockNative(available: true);
    final h = harness('https://dl.example/seg-1');
    final result = await h.icloud.syncPendingJobs(
      backendClient: h.backend,
      config: config,
      secrets: secrets,
    );
    expect(result.completed, 1);
    expect(result.failed, 0);
    expect(nativeCalls.any((c) => c.method == 'importSegment'), isTrue);
  });

  test(
    'rejects a non-HTTPS download URL and leaves the job for retry',
    () async {
      mockNative(available: true);
      final h = harness('http://dl.example/seg-1');
      final result = await h.icloud.syncPendingJobs(
        backendClient: h.backend,
        config: config,
        secrets: secrets,
      );
      expect(result.completed, 0);
      expect(result.failed, 1);
      // The insecure URL must never reach the native write path.
      expect(nativeCalls.any((c) => c.method == 'importSegment'), isFalse);
    },
  );
}
