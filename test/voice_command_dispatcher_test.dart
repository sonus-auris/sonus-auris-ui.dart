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
