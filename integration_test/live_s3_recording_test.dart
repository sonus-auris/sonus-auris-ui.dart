// Opt-in live iOS/Android smoke test: capture real microphone PCM, finalize a
// WAV segment, encrypt it with the same Keychain/Keystore-backed path used by
// AppController, upload it through the app's SigV4 S3 client, then delete it.
import 'dart:async';
import 'dart:io';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/services/crypto/flutter_secure_key_store.dart';
import 'package:audio_dashcam/src/services/crypto/key_manager.dart';
import 'package:audio_dashcam/src/services/crypto/segment_encryptor.dart';
import 'package:audio_dashcam/src/services/s3_storage_client.dart';
import 'package:audio_dashcam/src/services/segment_index.dart';
import 'package:audio_dashcam/src/services/segment_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _bucket = String.fromEnvironment('SONUS_LIVE_S3_BUCKET');
const _region = String.fromEnvironment(
  'SONUS_LIVE_S3_REGION',
  defaultValue: 'us-east-1',
);
const _accessKeyId = String.fromEnvironment('SONUS_LIVE_S3_ACCESS_KEY_ID');
const _secretAccessKey = String.fromEnvironment(
  'SONUS_LIVE_S3_SECRET_ACCESS_KEY',
);
const _sessionToken = String.fromEnvironment('SONUS_LIVE_S3_SESSION_TOKEN');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final liveConfigPresent =
      _bucket.isNotEmpty &&
      _accessKeyId.isNotEmpty &&
      _secretAccessKey.isNotEmpty;

  testWidgets(
    'real mic -> encrypted app upload -> S3 delete',
    (tester) async {
      final index = SegmentIndex();
      final recorder = SegmentRecorder(segmentIndex: index);
      final encryptor = SegmentEncryptor(
        keyManager: KeyManager(store: FlutterSecureKeyStore()),
      );
      final s3 = S3StorageClient(encryptor: encryptor);
      final closedSegment = Completer<RecordingSegment>();
      final closedSubscription = recorder.closedSegments.listen((segment) {
        if (!closedSegment.isCompleted) {
          closedSegment.complete(segment);
        }
      });
      const config = AppConfig(
        deviceId: 'ios-live-smoke',
        s3Bucket: _bucket,
        s3Region: _region,
        s3Prefix: 'codex-smoke/sonus-auris',
      );
      const secrets = CloudSecrets(
        s3AccessKeyId: _accessKeyId,
        s3SecretAccessKey: _secretAccessKey,
        s3SessionToken: _sessionToken,
      );
      String? uploadedKey;

      try {
        await recorder.start(config).timeout(const Duration(seconds: 45));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 6)),
        );
        await recorder.stop();

        final segment = await closedSegment.future.timeout(
          const Duration(seconds: 10),
        );
        final path = segment.localPath;
        expect(path, isNotNull);
        final file = File(path!);
        expect(await file.length(), greaterThan(1000));

        final result = await s3.uploadSegment(
          config: config,
          secrets: secrets,
          segment: segment,
          file: file,
        );
        expect(result.error, isNull);
        expect(result.remoteKey, isNotNull);
        uploadedKey = result.remoteKey;
      } finally {
        if (recorder.isRecording) {
          await recorder.stop();
        }
        if (uploadedKey != null) {
          final deleteError = await s3.deleteObject(
            config: config,
            secrets: secrets,
            key: uploadedKey,
          );
          expect(deleteError, isNull);
        }
        await closedSubscription.cancel();
        await recorder.dispose();
        s3.close();
      }
    },
    skip: !liveConfigPresent,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
