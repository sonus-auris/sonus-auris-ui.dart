// Isolated Android runtime-permission denial probe.
//
// The host must build this target with SONUS_PERMISSION_LAB_ANDROID=1, which
// selects com.ores.sonus_auris.permission_lab, and set RECORD_AUDIO to the
// user-fixed denied state before launch. The test proves denial is surfaced
// without capture, foreground-service startup, or plaintext segment creation.
import 'dart:io';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/services/background_capture_service.dart';
import 'package:audio_dashcam/src/services/segment_index.dart';
import 'package:audio_dashcam/src/services/segment_recorder.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const bool _compiledForPermissionLab = bool.fromEnvironment(
  'SONUS_DEVICE_LAB_PERMISSION_DENIAL',
);

Future<List<File>> _audioArtifacts(Directory directory) async {
  if (!await directory.exists()) return const <File>[];
  return directory
      .list(recursive: true, followLinks: false)
      .where(
        (entity) =>
            entity is File &&
            (entity.path.toLowerCase().endsWith('.wav') ||
                entity.path.toLowerCase().endsWith('.part')),
      )
      .cast<File>()
      .toList();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();

  testWidgets(
    'user-fixed microphone denial fails closed without audio artifacts',
    (tester) async {
      expect(Platform.isAndroid, isTrue);
      expect(
        _compiledForPermissionLab,
        isTrue,
        reason: 'refusing to exercise permission state outside the lab build',
      );

      final index = SegmentIndex();
      await index.clearAll();
      final directory = await index.segmentsDirectory;
      final recorder = SegmentRecorder(segmentIndex: index);
      final background = BackgroundCaptureService();
      background.init();

      Object? startError;
      try {
        await background.stop();
        expect(await FlutterForegroundTask.isRunningService, isFalse);

        try {
          await recorder.start(
            const AppConfig(
              deviceId: 'isolated-android-permission-lab',
              segmentMinutes: 0,
              overlapSeconds: 1,
              autoGain: false,
              noiseSuppress: false,
            ),
          ).timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail(
              'permission-denied recorder start did not return promptly',
            ),
          );
        } catch (error) {
          startError = error;
        }

        expect(startError, isNotNull);
        expect(
          startError.toString().toLowerCase(),
          contains('permission'),
          reason: 'denial should surface as an actionable permission error',
        );
        expect(recorder.isRecording, isFalse);
        expect(recorder.snapshots.value.isRecording, isFalse);
        expect(recorder.snapshots.value.isStarting, isFalse);
        expect(
          recorder.snapshots.value.error?.toLowerCase(),
          contains('permission'),
        );
        expect(await FlutterForegroundTask.isRunningService, isFalse);
        expect(await _audioArtifacts(directory), isEmpty);

        // Content-free marker consumed by the host evidence contract.
        // ignore: avoid_print
        print(
          'SONUS_PERMISSION_DENIAL_RESULT '
          'errorSurfaced=true serviceStarted=false audioArtifacts=0',
        );
      } finally {
        if (recorder.isRecording) {
          await recorder.stop();
        }
        await recorder.dispose();
        await background.stop();
        await index.clearAll();
      }

      expect(await _audioArtifacts(directory), isEmpty);
      // ignore: avoid_print
      print('SONUS_PERMISSION_DENIAL_CLEANUP_PASSED');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
