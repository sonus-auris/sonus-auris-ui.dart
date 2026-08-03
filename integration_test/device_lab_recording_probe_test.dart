// Explicitly consented, isolated Android hardware probe.
//
// This target must be built only with SONUS_DEVICE_LAB_ANDROID=1, which changes
// the Android application ID to com.ores.sonus_auris.device_lab, and with
// --dart-define=SONUS_DEVICE_LAB_RECORDING_PROBE=true. The host harness verifies
// that package identity before granting microphone permission or launching it.
// No raw audio is exported: the test validates WAV metadata inside the isolated
// app sandbox, then clears that sandbox before returning.
import 'dart:io';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/services/background_capture_service.dart';
import 'package:audio_dashcam/src/services/segment_index.dart';
import 'package:audio_dashcam/src/services/segment_recorder.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const bool _compiledForDeviceLabRecording = bool.fromEnvironment(
  'SONUS_DEVICE_LAB_RECORDING_PROBE',
);

Future<void> _delay(WidgetTester tester, Duration duration) async {
  await tester.runAsync(() => Future<void>.delayed(duration));
}

Future<List<File>> _filesEndingWith(Directory directory, String suffix) async {
  if (!await directory.exists()) return const <File>[];
  return directory
      .list(recursive: true, followLinks: false)
      .where(
        (entity) =>
            entity is File && entity.path.toLowerCase().endsWith(suffix),
      )
      .cast<File>()
      .toList();
}

Future<void> _validateFinalizedSegments(
  List<RecordingSegment> segments,
) async {
  expect(
    segments.length,
    greaterThanOrEqualTo(3),
    reason: 'the isolated probe did not rotate enough real microphone segments',
  );

  final sessionId = segments.first.captureSessionId;
  expect(sessionId, isNotEmpty);

  for (var index = 0; index < segments.length; index += 1) {
    final segment = segments[index];
    expect(segment.captureSessionId, sessionId);
    expect(segment.sequence, index);
    expect(segment.sampleRate, 16000);
    expect(segment.channels, 1);
    expect(segment.sampleCount, greaterThan(0));
    expect(segment.storedSampleCount, greaterThanOrEqualTo(segment.sampleCount));
    expect(segment.endedAtUtc.isAfter(segment.startedAtUtc), isTrue);

    if (index == 0) {
      expect(segment.startSample, 0);
      expect(segment.overlapSamples, 0);
    } else {
      final previous = segments[index - 1];
      expect(segment.overlapSamples, greaterThan(0));
      expect(
        segment.startSample,
        previous.startSample + previous.sampleCount,
        reason: 'unique sample timelines must remain contiguous',
      );
      expect(
        segment.startedAtUtc.isBefore(previous.endedAtUtc),
        isFalse,
        reason: 'segment wall-clock time must not move backwards',
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
      reason: 'PCM16 byte length must match the finalized WAV metadata',
    );
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();

  testWidgets(
    'isolated Android package records through Home and removes probe audio',
    (tester) async {
      expect(Platform.isAndroid, isTrue);
      expect(
        _compiledForDeviceLabRecording,
        isTrue,
        reason:
            'refusing microphone capture without the device-lab compile-time gate',
      );

      final index = SegmentIndex();
      await index.clearAll();
      final directory = await index.segmentsDirectory;
      final recorder = SegmentRecorder(segmentIndex: index);
      final background = BackgroundCaptureService();
      final closed = <RecordingSegment>[];
      final closedSubscription = recorder.closedSegments.listen(closed.add);
      background.init();

      const config = AppConfig(
        deviceId: 'isolated-android-device-lab',
        segmentMinutes: 0,
        overlapSeconds: 1,
        autoGain: false,
        noiseSuppress: false,
      );

      try {
        await background.stop();
        final backgroundError = await background.start();
        expect(backgroundError, isNull);
        expect(await FlutterForegroundTask.isRunningService, isTrue);

        await recorder
            .start(config)
            .timeout(
              const Duration(seconds: 45),
              onTimeout: () => fail(
                'isolated device-lab recorder could not open the microphone',
              ),
            );
        await _delay(tester, const Duration(seconds: 1));
        expect(recorder.isRecording, isTrue);

        // The host harness watches for this exact marker, presses Home, verifies
        // the isolated process/service/notification, then returns the activity.
        // ignore: avoid_print
        print('SONUS_DEVICE_LAB_BACKGROUND_READY');
        await _delay(tester, const Duration(seconds: 10));

        final recent = recorder.recentAudio(window: const Duration(seconds: 6));
        expect(recorder.isRecording, isTrue);
        expect(recent, isNotNull);
        expect(recent!.bytes.length, greaterThan(1000));
        expect(await FlutterForegroundTask.isRunningService, isTrue);

        await recorder.stop();
        await background.stop();
        await _delay(tester, const Duration(milliseconds: 500));
        expect(await FlutterForegroundTask.isRunningService, isFalse);

        await _validateFinalizedSegments(closed);
        final partials = await _filesEndingWith(directory, '.part');
        expect(
          partials,
          isEmpty,
          reason: 'the isolated stop path left unfinished plaintext files',
        );

        // Only bounded, content-free metrics are emitted to host evidence.
        // ignore: avoid_print
        print(
          'SONUS_DEVICE_LAB_RECORDING_RESULT '
          'segments=${closed.length} '
          'pcmBytes=${recent.bytes.length} '
          'serviceStopped=true',
        );
      } finally {
        await closedSubscription.cancel();
        if (recorder.isRecording) {
          await recorder.stop();
        }
        await recorder.dispose();
        await background.stop();
        await index.clearAll();
      }

      expect(await _filesEndingWith(directory, '.wav'), isEmpty);
      expect(await _filesEndingWith(directory, '.part'), isEmpty);
      // ignore: avoid_print
      print('SONUS_DEVICE_LAB_AUDIO_CLEANUP_PASSED');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
