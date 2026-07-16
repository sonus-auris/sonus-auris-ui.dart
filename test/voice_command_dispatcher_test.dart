import 'package:audio_dashcam/src/models/voice_command.dart';
import 'package:audio_dashcam/src/services/voice/handlers/note_command_handler.dart';
import 'package:audio_dashcam/src/services/voice/handlers/recording_command_handler.dart';
import 'package:audio_dashcam/src/services/voice/handlers/timer_command_handler.dart';
import 'package:audio_dashcam/src/services/voice/voice_command_dispatcher.dart';
import 'package:audio_dashcam/src/services/voice/voice_command_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('timer handler', () {
    test('sets a timer and confirms', () async {
      final dispatcher = VoiceCommandDispatcher();
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch('Set a timer for 10 minutes');
      expect(result.success, isTrue);
      expect(result.spokenResponse, contains('10 minutes'));
      expect(dispatcher.activeTimers, hasLength(1));
      expect(dispatcher.activeTimers.first.duration.inMinutes, 10);
    });

    test('fires the elapsed callback', () async {
      VoiceTimer? fired;
      final dispatcher = VoiceCommandDispatcher(
        onTimerElapsed: (t) => fired = t,
      );
      addTearDown(dispatcher.dispose);

      await dispatcher.dispatch('timer 1 second');
      expect(fired, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(fired, isNotNull);
      expect(dispatcher.activeTimers, isEmpty);
    });

    test('rejects a timer with no duration', () async {
      final dispatcher = VoiceCommandDispatcher();
      addTearDown(dispatcher.dispose);
      // No number → parser won't match setTimer; dispatch is unrecognized.
      final result = await dispatcher.dispatch('set a timer');
      expect(result.success, isFalse);
    });
  });

  group('note handler', () {
    test('captures a note into the sink', () async {
      final sink = InMemoryNoteSink();
      final dispatcher = VoiceCommandDispatcher(noteSink: sink);
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch(
        'Take a note: buy milk and eggs',
      );
      expect(result.success, isTrue);
      expect(sink.notes, hasLength(1));
      expect(sink.notes.first.text, 'buy milk and eggs');
      expect(sink.notes.first.isTask, isFalse);
    });

    test('create a task is flagged as a task', () async {
      final sink = InMemoryNoteSink();
      final dispatcher = VoiceCommandDispatcher(noteSink: sink);
      addTearDown(dispatcher.dispose);

      await dispatcher.dispatch('Create a task: renew passport');
      expect(sink.notes.single.isTask, isTrue);
      expect(sink.notes.single.text, 'renew passport');
    });
  });

  group('recording control handler', () {
    test('start and stop drive the injected control', () async {
      var recording = false;
      final control = RecorderControl(
        start: () async => recording = true,
        stop: () async => recording = false,
        isRecording: () => recording,
      );
      final dispatcher = VoiceCommandDispatcher(recorderControl: control);
      addTearDown(dispatcher.dispose);

      final start = await dispatcher.dispatch('start recording');
      expect(start.success, isTrue);
      expect(recording, isTrue);

      final stop = await dispatcher.dispatch('stop recording');
      expect(stop.success, isTrue);
      expect(recording, isFalse);
    });

    test('starting while already recording is idempotent', () async {
      var recording = true;
      final control = RecorderControl(
        start: () async => recording = true,
        stop: () async => recording = false,
        isRecording: () => recording,
      );
      final dispatcher = VoiceCommandDispatcher(recorderControl: control);
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch('start recording');
      expect(result.success, isTrue);
      expect(result.spokenResponse, contains('Already recording'));
    });

    test('confirm recording speaks the live state back', () async {
      var recording = true;
      final control = RecorderControl(
        start: () async => recording = true,
        stop: () async => recording = false,
        isRecording: () => recording,
      );
      final dispatcher = VoiceCommandDispatcher(recorderControl: control);
      addTearDown(dispatcher.dispose);

      final active = await dispatcher.dispatch('confirm recording');
      expect(active.success, isTrue);
      expect(active.spokenResponse, contains('recording'));
      expect(active.data['recording'], isTrue);

      recording = false;
      final stopped = await dispatcher.dispatch('hey sonus, am I recording?');
      expect(stopped.success, isTrue);
      expect(stopped.data['recording'], isFalse);
    });

    test('pause with a spoken duration pauses immediately', () async {
      var recording = true;
      Duration? pausedFor;
      final control = RecorderControl(
        start: () async => recording = true,
        stop: () async => recording = false,
        isRecording: () => recording,
        pauseFor: (duration) async {
          pausedFor = duration;
          recording = false;
        },
        isPaused: () => pausedFor != null && !recording,
      );
      final dispatcher = VoiceCommandDispatcher(recorderControl: control);
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch(
        'pause recording for 10 minutes',
      );
      expect(result.success, isTrue);
      expect(pausedFor, const Duration(minutes: 10));
      expect(result.spokenResponse, contains('10 minutes'));
    });

    test(
      'pause without a duration asks, then the next utterance answers',
      () async {
        var recording = true;
        Duration? pausedFor;
        final control = RecorderControl(
          start: () async => recording = true,
          stop: () async => recording = false,
          isRecording: () => recording,
          pauseFor: (duration) async {
            pausedFor = duration;
            recording = false;
          },
          isPaused: () => pausedFor != null && !recording,
        );
        final dispatcher = VoiceCommandDispatcher(recorderControl: control);
        addTearDown(dispatcher.dispose);

        final question = await dispatcher.dispatch('pause recording');
        expect(question.handled, isFalse);
        expect(question.spokenResponse, contains('how long'));
        expect(pausedFor, isNull);

        final answer = await dispatcher.dispatch('twenty minutes');
        expect(answer.success, isTrue);
        expect(pausedFor, const Duration(minutes: 20));
      },
    );

    test('a non-answer mid-dialogue falls through to normal parsing', () async {
      var recording = true;
      final control = RecorderControl(
        start: () async => recording = true,
        stop: () async => recording = false,
        isRecording: () => recording,
        pauseFor: (_) async => recording = false,
      );
      final dispatcher = VoiceCommandDispatcher(recorderControl: control);
      addTearDown(dispatcher.dispose);

      await dispatcher.dispatch('pause recording');
      final result = await dispatcher.dispatch('stop recording');
      expect(result.success, isTrue);
      expect(recording, isFalse);
      expect(result.command.intent, VoiceIntent.stopRecording);
    });

    test('pause without a wired pauseFor stays unavailable', () async {
      final control = RecorderControl(
        start: () async {},
        stop: () async {},
        isRecording: () => true,
      );
      final dispatcher = VoiceCommandDispatcher(recorderControl: control);
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch('pause recording for 5 minutes');
      expect(result.handled, isFalse);
      expect(result.success, isFalse);
    });
  });

  group('capability registration & fallbacks', () {
    test('recognized-but-unwired intent is not reported as handled', () async {
      final dispatcher = VoiceCommandDispatcher();
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch('Navigate to the airport');
      expect(result.handled, isFalse);
      expect(result.success, isFalse);
      expect(result.spokenResponse, contains("can't do that yet"));
    });

    test('registered platform executor performs the command', () async {
      String? openedDestination;
      final platformHandler = CallbackCommandHandler({
        VoiceIntent.navigateTo: (command) async {
          openedDestination = command.slot('destination');
          return VoiceCommandResult.ok(command, 'Opening directions.');
        },
      });
      final dispatcher = VoiceCommandDispatcher(
        additionalHandlers: [platformHandler],
      );
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch('Navigate to the airport');
      expect(result.handled, isTrue);
      expect(result.success, isTrue);
      expect(openedDestination, 'the airport');
    });

    test('unrecognized speech is not handled', () async {
      final dispatcher = VoiceCommandDispatcher();
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch('blorp flern z?');
      expect(result.handled, isFalse);
      expect(result.command.intent, VoiceIntent.unknown);
    });

    test('results are published on the stream and spoken', () async {
      final spoken = <String>[];
      final dispatcher = VoiceCommandDispatcher(
        speak: (p) async => spoken.add(p),
      );
      addTearDown(dispatcher.dispose);

      await dispatcher.dispatch('Set a timer for 2 minutes');
      expect(spoken, isNotEmpty);
      expect(dispatcher.results.value.success, isTrue);
    });
  });
}
