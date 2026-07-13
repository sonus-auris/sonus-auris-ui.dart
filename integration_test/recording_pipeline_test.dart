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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'device mic -> recorder writes a valid WAV segment to disk',
    (tester) async {
      final index = SegmentIndex();
      final dir = await index.segmentsDirectory;

      // Clean slate so the assertion is about THIS run's output.
      for (final e in dir.listSync()) {
        e.deleteSync(recursive: true);
      }

      final recorder = SegmentRecorder(segmentIndex: index);
      const config = AppConfig(deviceId: 'integration-test');

      var sawActiveSnapshot = false;
      final finalizedPaths = <String>[];
      final snapSub = recorder.snapshots.listen((s) {
        // Anything past the seeded idle means the meter is live.
        if (s.isRecording) sawActiveSnapshot = true;
      });
      final closedSub = recorder.closedSegments.listen((segment) {
        final path = segment.localPath;
        if (path != null) finalizedPaths.add(path);
      });

      try {
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
          'recording-integration: started, '
          'isRecording=${recorder.isRecording}',
        );
        expect(recorder.isRecording, isTrue, reason: 'recorder did not start');

        // Capture ~6s of the emulator's virtual mic (silence is fine — it is
        // still real PCM flowing through the platform channel and WAV writer).
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 6)),
        );

        await recorder.stop(); // finalizes the active (partial) segment
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );

        // SegmentIndex intentionally shards files under YYYY/MM/DD/HH. Search
        // recursively so this validates the finalized WAV, not just the year
        // directory at the storage root.
        final wavs = await dir
            .list(recursive: true, followLinks: false)
            .where(
              (entity) =>
                  entity is File && entity.path.toLowerCase().endsWith('.wav'),
            )
            .cast<File>()
            .toList();
        expect(
          finalizedPaths,
          isNotEmpty,
          reason: 'recorder.stop() did not finalize an active segment',
        );
        expect(
          wavs.map((file) => file.path),
          contains(finalizedPaths.last),
          reason: 'the finalized segment was not present under $dir',
        );

        final file = File(finalizedPaths.last);
        final bytes = await file.readAsBytes();
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
          'wavBytes=${bytes.length} file=${file.path}',
        );
      } finally {
        await snapSub.cancel();
        await closedSub.cancel();
        await recorder.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
