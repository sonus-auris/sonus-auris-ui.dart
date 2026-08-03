// Disposable iOS Simulator microphone-permission denial probe.
//
// The host creates a simulator solely for this test, installs this integration
// target, revokes microphone access for the app bundle, and deletes the entire
// test-created simulator afterward. No existing simulator or physical iPhone is
// selected or mutated by the harness.
import 'dart:io';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/services/segment_index.dart';
import 'package:audio_dashcam/src/services/segment_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const bool _compiledForIosPermissionLab = bool.fromEnvironment(
  'SONUS_IOS_PERMISSION_DENIAL_LAB',
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

  testWidgets(
    'revoked iOS microphone permission fails closed without audio files',
    (_) async {
      expect(Platform.isIOS, isTrue);
      expect(
        _compiledForIosPermissionLab,
        isTrue,
        reason: 'refusing to exercise permission state outside the iOS lab',
      );

      final index = SegmentIndex();
      await index.clearAll();
      final directory = await index.segmentsDirectory;
      final recorder = SegmentRecorder(segmentIndex: index);
      Object? startError;

      try {
        try {
          await recorder
              .start(
                const AppConfig(
                  deviceId: 'disposable-ios-simulator-permission-lab',
                  segmentMinutes: 0,
                  overlapSeconds: 1,
                  autoGain: false,
                  noiseSuppress: false,
                ),
              )
              .timeout(
                const Duration(seconds: 30),
                onTimeout: () => fail(
                  'permission-denied iOS recorder start did not return promptly',
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
        expect(await _audioArtifacts(directory), isEmpty);

        // Content-free marker consumed by the host evidence contract.
        // ignore: avoid_print
        print(
          'SONUS_IOS_PERMISSION_DENIAL_RESULT '
          'errorSurfaced=true recordingStarted=false audioArtifacts=0',
        );
      } finally {
        if (recorder.isRecording) {
          await recorder.stop();
        }
        await recorder.dispose();
        await index.clearAll();
      }

      expect(await _audioArtifacts(directory), isEmpty);
      // ignore: avoid_print
      print('SONUS_IOS_PERMISSION_DENIAL_CLEANUP_PASSED');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
