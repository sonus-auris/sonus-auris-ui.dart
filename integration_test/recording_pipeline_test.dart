// On-device functional test of the core capture pipeline: drive the REAL
// SegmentRecorder (real `record` mic stream, real platform channels, real file
// I/O) on an emulator and assert it writes a valid WAV segment to disk. This
// covers the one layer unit tests (which use fakes) cannot: that audio actually
// flows from the device microphone through the recorder to an on-disk segment.
//
// Runs in CI on the KVM emulator (see .github/workflows/android-emulator-test.yml).
// RECORD_AUDIO is granted out-of-band by the workflow before recording starts.
import 'dart:io';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/services/segment_index.dart';
import 'package:audio_dashcam/src/services/segment_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:record/record.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'device mic -> recorder writes a valid WAV segment to disk',
    (tester) async {
      final index = SegmentIndex();
      final dir = await index.segmentsDirectory;

      // The CI harness grants RECORD_AUDIO out-of-band after flutter drive
      // installs the APK. Poll without requesting so Android never opens a
      // permission dialog in front of this non-interactive device test.
      final permissionProbe = AudioRecorder();
      final permissionGranted = await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!await permissionProbe.hasPermission(request: false)) {
          if (DateTime.now().isAfter(deadline)) {
            return false;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        return true;
      });
      await permissionProbe.dispose();
      expect(
        permissionGranted,
        isTrue,
        reason: 'CI did not grant RECORD_AUDIO within 30 seconds',
      );

      // Clean slate so the assertion is about THIS run's output.
      for (final e in dir.listSync()) {
        e.deleteSync(recursive: true);
      }

      final recorder = SegmentRecorder(segmentIndex: index);
      const config = AppConfig(deviceId: 'integration-test');

      var sawActiveSnapshot = false;
      final snapSub = recorder.snapshots.listen((s) {
        // Anything past the seeded idle means the meter is live.
        if (s.isRecording) sawActiveSnapshot = true;
      });

      // ignore: avoid_print
      print('recording-integration: calling recorder.start()');
      // Fail fast with a clear message if start() ever blocks, instead of
      // burning the whole test timeout.
      await recorder
          .start(config)
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () => fail(
              'recorder.start() did not complete in 45s '
              '(mic device likely unavailable — is emulator audio enabled?)',
            ),
          );
      // ignore: avoid_print
      print(
        'recording-integration: started, isRecording=${recorder.isRecording}',
      );
      expect(recorder.isRecording, isTrue, reason: 'recorder did not start');

      // Capture ~6s of the emulator's virtual mic (silence is fine — it is still
      // real PCM flowing through the platform channel and the WAV writer).
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 6)),
      );

      await recorder.stop(); // finalizes the active (partial) segment
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );

      // A .wav segment must exist and be a real, non-trivial RIFF/WAVE file.
      final wavs = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.wav'))
          .toList();
      expect(wavs, isNotEmpty, reason: 'no .wav segment was written to $dir');

      final bytes = await wavs.first.readAsBytes();
      expect(
        bytes.length,
        greaterThan(1000),
        reason: 'WAV has only a header — no captured audio was written',
      );
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');

      // Informational: the live meter should have reported an active state.
      // Not a hard gate (emulator mic timing varies), but logged for diagnosis.
      // ignore: avoid_print
      print(
        'recording-integration: sawActiveSnapshot=$sawActiveSnapshot '
        'wavBytes=${bytes.length} file=${wavs.first.path}',
      );

      await snapSub.cancel();
      await recorder.dispose();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
