import 'package:audio_dashcam/src/models/voice_command.dart';
import 'package:audio_dashcam/src/services/voice/voice_command_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = VoiceCommandParser();

  group('timer', () {
    test('parses minutes into seconds', () {
      final cmd = parser.parse('Set a timer for 12 minutes.');
      expect(cmd.intent, VoiceIntent.setTimer);
      expect(cmd.slot('durationSeconds'), '720');
    });

    test('parses seconds and hours', () {
      expect(parser.parse('timer 90 seconds').slot('durationSeconds'), '90');
      expect(
        parser.parse('set a timer for 1 hour').slot('durationSeconds'),
        '3600',
      );
    });

    test('focus session defaults to 25 minutes', () {
      final cmd = parser.parse('Start a focus session.');
      expect(cmd.intent, VoiceIntent.startFocusSession);
      expect(cmd.slot('durationSeconds'), '1500');
    });

    test('focus session honors a stated duration', () {
      final cmd = parser.parse('start a 25-minute focus session');
      expect(cmd.slot('durationSeconds'), '1500');
    });
  });

  group('notes & tasks', () {
    test('captures note body after the colon', () {
      final cmd = parser.parse('Take a note: customer requested PDF export.');
      expect(cmd.intent, VoiceIntent.takeNote);
      expect(cmd.slot('text'), 'customer requested pdf export');
    });

    test('save this idea maps to a note', () {
      final cmd = parser.parse('Save this idea: add dark mode');
      expect(cmd.intent, VoiceIntent.takeNote);
      expect(cmd.slot('text'), 'add dark mode');
    });

    test('create a task extracts the task text', () {
      final cmd = parser.parse('Create a task: renew passport');
      expect(cmd.intent, VoiceIntent.createTask);
      expect(cmd.slot('text'), 'renew passport');
    });
  });

  group('recording control', () {
    test('start recording', () {
      expect(
        parser.parse('Start recording').intent,
        VoiceIntent.startRecording,
      );
      expect(
        parser.parse('begin the recording').intent,
        VoiceIntent.startRecording,
      );
    });

    test('stop recording', () {
      expect(parser.parse('Stop recording.').intent, VoiceIntent.stopRecording);
    });

    test('confirm recording', () {
      expect(
        parser.parse('Confirm recording').intent,
        VoiceIntent.confirmRecording,
      );
      expect(
        parser.parse('hey sonus, am I recording?').intent,
        VoiceIntent.confirmRecording,
      );
      expect(
        parser.parse('are you still recording').intent,
        VoiceIntent.confirmRecording,
      );
    });

    test('pause recording is its own intent, not stop', () {
      final bare = parser.parse('Pause recording');
      expect(bare.intent, VoiceIntent.pauseRecording);
      expect(bare.slot('durationSeconds'), isNull);

      final timed = parser.parse('pause the recording for 10 minutes');
      expect(timed.intent, VoiceIntent.pauseRecording);
      expect(timed.slot('durationSeconds'), '600');
    });

    test('spoken durations parse numerals, words, and idioms', () {
      expect(VoiceCommandParser.spokenDurationSeconds('90 seconds'), 90);
      expect(VoiceCommandParser.spokenDurationSeconds('twenty minutes'), 1200);
      expect(VoiceCommandParser.spokenDurationSeconds('an hour'), 3600);
      expect(VoiceCommandParser.spokenDurationSeconds('half an hour'), 1800);
      expect(
        VoiceCommandParser.spokenDurationSeconds('forty five minutes'),
        2700,
      );
      expect(VoiceCommandParser.spokenDurationSeconds('no idea'), isNull);
    });
  });

  group('wake word & normalization', () {
    test('strips a leading wake word', () {
      final cmd = parser.parse('Hey Sonus, set a timer for 5 minutes');
      expect(cmd.intent, VoiceIntent.setTimer);
      expect(cmd.slot('durationSeconds'), '300');
    });
  });

  group('scaffolded intents still parse', () {
    test('reminder', () {
      final cmd = parser.parse('Remind me to call John tomorrow at 9 AM');
      expect(cmd.intent, VoiceIntent.setReminder);
      expect(cmd.slot('text'), contains('call john'));
    });

    test('navigation', () {
      final cmd = parser.parse('Navigate to the nearest gas station');
      expect(cmd.intent, VoiceIntent.navigateTo);
      expect(cmd.slot('destination'), 'the nearest gas station');
    });

    test('weather tomorrow', () {
      final cmd = parser.parse("What's the weather tomorrow?");
      expect(cmd.intent, VoiceIntent.queryWeather);
      expect(cmd.slot('when'), 'tomorrow');
    });

    test('smart home', () {
      final cmd = parser.parse('Turn off the living room lights');
      expect(cmd.intent, VoiceIntent.smartHomeControl);
    });
  });

  group('unknown', () {
    test('gibberish is unrecognized with zero confidence', () {
      final cmd = parser.parse('asdf qwerty zxcv');
      expect(cmd.intent, VoiceIntent.unknown);
      expect(cmd.isRecognized, isFalse);
      expect(cmd.confidence, 0);
    });

    test('empty transcript is unknown', () {
      expect(parser.parse('   ').intent, VoiceIntent.unknown);
    });
  });
}
