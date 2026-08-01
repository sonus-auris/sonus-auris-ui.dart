// On-device functional tests of the core Android capture pipeline: drive the
// real microphone stream, platform channels, foreground service, segment
// rotation, and file I/O. Unit tests use fakes; these tests prove that audio
// actually moves through the Android stack into valid on-disk WAV segments.
//
// Runs in CI on the KVM emulator (see .github/workflows/android-emulator-test.yml).
// RECORD_AUDIO and POST_NOTIFICATIONS are granted out-of-band by the workflow.
import 'dart:io';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/services/background_capture_service.dart';
import 'package:audio_dashcam/src/services/segment_index.dart';
import 'package:audio_dashcam/src/services/segment_recorder.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _delay(WidgetTester tester, Duration duration) async {
  await tester.runAsync(() => Future<void>.delayed(duration));
}

Future<List<File>> _filesEndingWith(Directory directory, String suffix) async {
  return directory
      .list(recursive: true, followLinks: false)
      .where(
        (entity) =>
            entity is File && entity.path.toLowerCase().endsWith(suffix),
      )
      .cast<File>()
      .toList();
}

Future<void> _expectValidRun(List<RecordingSegment> segments) async {
  expect(
    segments.length,
    greaterThanOrEqualTo(2),
    reason: 'capture did not rotate enough segments to validate continuity',
  );
  expect(
    segments.map((segment) => segment.sequence),
    orderedEquals(List<int>.generate(segments.length, (index) => index)),
  );

  final sessionId = segments.first.captureSessionId;
  expect(sessionId, isNotEmpty);

  for (var index = 0; index < segments.length; index += 1) {
    final segment = segments[index];
    expect(segment.captureSessionId, sessionId);
    expect(segment.sampleRate, 16000);
    expect(segment.channels, 1);
    expect(segment.sampleCount, greaterThan(0));
    expect(segment.storedSampleCount, greaterThanOrEqualTo(segment.sampleCount));
    expect(segment.endedAtUtc.isAfter(segment.startedAtUtc), isTrue);

    if (index == 0) {
      expect(segment.overlapSamples, 0);
      expect(segment.startSample, 0);
    } else {
      final previous = segments[index - 1];
      expect(segment.overlapSamples, greaterThan(0));
      expect(
        segment.startSample,
        previous.startSample + previous.sampleCount,
        reason: 'unique sample timelines must be contiguous across rotation',
      );
      expect(
        segment.startedAtUtc.isBefore(previous.endedAtUtc),
        isFalse,
        reason: 'segment wall-clock timelines must not move backwards',
      );
    }

    final path = segment.localPath;
    expect(path, isNotNull);
    final file = File(path!);
    expect(await file.exists(), isTrue);
    final bytes = await file.readAsBytes();
    expect(bytes.length, segment.byteSize);
    expect(
      bytes.length,
      44 + segment.storedSampleCount * segment.channels * 2,
      reason: 'WAV byte length must match PCM16 metadata plus its header',
    );
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();

  testWidgets(
    'schedule standby never creates a microphone foreground service',
    (tester) async {
      final background = BackgroundCaptureService();
      background.init();
      await background.stop();
      expect(await FlutterForegroundTask.isRunningService, isFalse);

      final error = await background.start(
        mode: BackgroundCaptureMode.scheduleStandby,
      );
      expect(error, isNull);
      expect(
        await FlutterForegroundTask.isRunningService,
        isFalse,
        reason:
            'an armed schedule must use reminders, not a microphone FGS while idle',
      );
      // ignore: avoid_print
      print('SCHEDULE STANDBY POLICY TEST PASSED');
    },
  );

  testWidgets(
    'device mic -> recorder writes a valid WAV segment to disk',
    (tester) async {
      final index = SegmentIndex();
      await index.clearAll();
      final dir = await index.segmentsDirectory;

      final recorder = SegmentRecorder(segmentIndex: index);
      const config = AppConfig(deviceId: 'integration-test');

      var sawActiveSnapshot = false;
      final finalizedPaths = <String>[];
      final snapSub = recorder.snapshots.listen((snapshot) {
        // Anything past the seeded idle means the meter is live.
        if (snapshot.isRecording) sawActiveSnapshot = true;
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
        await _delay(tester, const Duration(seconds: 6));
        final recent = recorder.recentAudio(window: const Duration(seconds: 6));
        final activeSnapshot = recorder.snapshots.value;
        // ignore: avoid_print
        print(
          'recording-integration: before stop '
          'pcmBytes=${recent?.bytes.length ?? 0} '
          'activeSegment=${activeSnapshot.activeSegmentPath ?? "none"} '
          'snapshotRecording=${activeSnapshot.isRecording}',
        );

        await recorder.stop(); // finalizes the active (partial) segment
        await _delay(tester, const Duration(seconds: 1));

        // SegmentIndex intentionally shards files under YYYY/MM/DD/HH. Search
        // recursively so this validates the finalized WAV, not just the year
        // directory at the storage root.
        final wavs = await _filesEndingWith(dir, '.wav');
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

  testWidgets(
    'real mic rotates overlapping segments and the recorder restarts cleanly',
    (tester) async {
      final index = SegmentIndex();
      await index.clearAll();
      final dir = await index.segmentsDirectory;
      final recorder = SegmentRecorder(segmentIndex: index);
      final closed = <RecordingSegment>[];
      final closedSub = recorder.closedSegments.listen(closed.add);

      // Test-only minimum: segmentMinutes=0 is safely clamped by AppConfig to a
      // one-second segment. This exercises several real rotations without making
      // CI wait through production-length one-minute boundaries.
      const config = AppConfig(
        deviceId: 'rotation-integration-test',
        segmentMinutes: 0,
        overlapSeconds: 1,
        autoGain: false,
        noiseSuppress: false,
      );

      Future<List<RecordingSegment>> captureRun(Duration duration) async {
        final before = closed.length;
        await recorder
            .start(config)
            .timeout(
              const Duration(seconds: 45),
              onTimeout: () => fail('rotation test could not start the mic'),
            );
        await _delay(tester, duration);
        expect(recorder.isRecording, isTrue);
        await recorder.stop();
        // PublishSubject delivery and file-close metadata settle asynchronously.
        await _delay(tester, const Duration(milliseconds: 400));
        return List<RecordingSegment>.unmodifiable(closed.skip(before));
      }

      try {
        final firstRun = await captureRun(const Duration(seconds: 4));
        expect(firstRun.length, greaterThanOrEqualTo(3));
        await _expectValidRun(firstRun);

        final secondRun = await captureRun(const Duration(seconds: 3));
        expect(secondRun.length, greaterThanOrEqualTo(2));
        await _expectValidRun(secondRun);
        expect(
          secondRun.first.captureSessionId,
          isNot(firstRun.first.captureSessionId),
          reason: 'a restart must create a new capture-session identity',
        );

        final partials = await _filesEndingWith(dir, '.part');
        expect(
          partials,
          isEmpty,
          reason: 'stop/restart left unfinished plaintext .part files behind',
        );
        // ignore: avoid_print
        print(
          'recording-integration: rotation/restart passed '
          'first=${firstRun.length} second=${secondRun.length}',
        );
      } finally {
        await closedSub.cancel();
        await recorder.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'foreground service keeps real capture alive through an actual Home transition',
    (tester) async {
      final index = SegmentIndex();
      await index.clearAll();
      final recorder = SegmentRecorder(segmentIndex: index);
      final background = BackgroundCaptureService();
      final closed = <RecordingSegment>[];
      final closedSub = recorder.closedSegments.listen(closed.add);
      background.init();

      const config = AppConfig(
        deviceId: 'background-integration-test',
        segmentMinutes: 0,
        overlapSeconds: 1,
        autoGain: false,
        noiseSuppress: false,
      );

      try {
        final backgroundError = await background.start();
        expect(backgroundError, isNull);
        expect(await FlutterForegroundTask.isRunningService, isTrue);

        await recorder
            .start(config)
            .timeout(
              const Duration(seconds: 45),
              onTimeout: () => fail('background test could not start the mic'),
            );
        await _delay(tester, const Duration(seconds: 1));
        expect(recorder.isRecording, isTrue);

        // The host harness watches for this exact marker, presses Home, verifies
        // the process/service/notification while the app is truly backgrounded,
        // then brings the same activity back to the foreground.
        // ignore: avoid_print
        print('SONUS_BACKGROUND_PROBE_READY');
        await _delay(tester, const Duration(seconds: 10));

        final recent = recorder.recentAudio(window: const Duration(seconds: 6));
        expect(recorder.isRecording, isTrue);
        expect(recent, isNotNull);
        expect(recent!.bytes.length, greaterThan(1000));
        expect(closed.length, greaterThanOrEqualTo(3));
        expect(await FlutterForegroundTask.isRunningService, isTrue);
        // ignore: avoid_print
        print(
          'SONUS_BACKGROUND_PROBE_FINISHED '
          'pcmBytes=${recent.bytes.length} closedSegments=${closed.length}',
        );

        await recorder.stop();
        await background.stop();
        expect(await FlutterForegroundTask.isRunningService, isFalse);
      } finally {
        await closedSub.cancel();
        await recorder.dispose();
        await background.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
