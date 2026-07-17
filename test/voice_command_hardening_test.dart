import 'dart:convert';

import 'package:audio_dashcam/src/models/voice_command.dart';
import 'package:audio_dashcam/src/services/voice/handlers/note_command_handler.dart';
import 'package:audio_dashcam/src/services/voice/intent_resolver.dart';
import 'package:audio_dashcam/src/services/voice/voice_command_dispatcher.dart';
import 'package:audio_dashcam/src/services/voice/voice_limits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A stub IntentResolver that returns a fixed command — lets us drive the
/// dispatcher with adversarial values without a network.
class _FixedResolver implements IntentResolver {
  _FixedResolver(this.command);
  final VoiceCommand command;
  @override
  Future<VoiceCommand> resolve(String transcript) async => command;
}

void main() {
  group('confidence gate cannot be bypassed', () {
    test('NaN confidence is treated as failing the threshold', () async {
      final dispatcher = VoiceCommandDispatcher(
        resolver: _FixedResolver(
          VoiceCommand(
            intent: VoiceIntent.takeNote,
            transcript: 'x',
            slots: const {'text': 'sneaky'},
            confidence: double.nan,
          ),
        ),
      );
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch('whatever');
      expect(
        result.success,
        isFalse,
        reason: 'NaN must not slip past the confidence gate',
      );
    });

    test('infinity confidence is clamped, not trusted blindly', () {
      expect(VoiceLimits.sanitizeConfidence(double.infinity), 0);
      expect(VoiceLimits.sanitizeConfidence(-5), 0);
      expect(VoiceLimits.sanitizeConfidence(2), 1);
      expect(VoiceLimits.sanitizeConfidence(0.7), 0.7);
    });
  });

  group('LlmIntentResolver endpoint safety', () {
    test('rejects plaintext http to a remote host at construction', () {
      expect(
        () => LlmIntentResolver(endpoint: Uri.parse('http://evil.example/x')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects non-http(s) schemes', () {
      expect(
        () => LlmIntentResolver(endpoint: Uri.parse('ftp://host/x')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('allows https and http loopback', () {
      expect(
        LlmIntentResolver.isSafeEndpoint(Uri.parse('https://api/x')),
        isTrue,
      );
      expect(
        LlmIntentResolver.isSafeEndpoint(Uri.parse('http://localhost:8080/x')),
        isTrue,
      );
      expect(
        LlmIntentResolver.isSafeEndpoint(Uri.parse('http://127.0.0.1/x')),
        isTrue,
      );
    });

    test('truncates an oversized response instead of acting on it', () async {
      final huge = jsonEncode({
        'intent': 'takeNote',
        'slots': {'text': 'x' * (VoiceLimits.maxResponseBytes + 10)},
        'confidence': 0.99,
      });
      final client = MockClient((_) async => http.Response(huge, 200));
      final resolver = LlmIntentResolver(
        endpoint: Uri.parse('https://api.example/intent'),
        httpClient: client,
      );
      final cmd = await resolver.resolve('take a note: hello');
      expect(
        cmd.intent,
        VoiceIntent.unknown,
        reason: 'oversized bodies are refused',
      );
    });

    test(
      'clamps slot count, slot length and confidence from the server',
      () async {
        final slots = <String, String>{
          for (var i = 0; i < VoiceLimits.maxSlots + 50; i++) 'k$i': 'v',
          'text': 'y' * (VoiceLimits.maxSlotValueChars + 100),
        };
        final body = jsonEncode({
          'intent': 'takeNote',
          'slots': slots,
          'confidence': 999.0,
        });
        final client = MockClient((_) async => http.Response(body, 200));
        final resolver = LlmIntentResolver(
          endpoint: Uri.parse('https://api.example/intent'),
          httpClient: client,
        );
        final cmd = await resolver.resolve('note');
        expect(cmd.slots.length, lessThanOrEqualTo(VoiceLimits.maxSlots));
        expect(cmd.confidence, lessThanOrEqualTo(1.0));
        for (final v in cmd.slots.values) {
          expect(v.length, lessThanOrEqualTo(VoiceLimits.maxSlotValueChars));
        }
      },
    );

    test('a backend error fails soft to unknown', () async {
      final client = MockClient((_) async => http.Response('nope', 500));
      final resolver = LlmIntentResolver(
        endpoint: Uri.parse('https://api.example/intent'),
        httpClient: client,
      );
      expect((await resolver.resolve('x')).intent, VoiceIntent.unknown);
    });
  });

  group('resource bounds', () {
    test('timer duration is capped', () async {
      final dispatcher = VoiceCommandDispatcher();
      addTearDown(dispatcher.dispose);
      final result = await dispatcher.dispatch('set a timer for 9999 hours');
      expect(result.success, isFalse);
      expect(dispatcher.activeTimers, isEmpty);
    });

    test('note text is truncated to the cap', () async {
      final sink = InMemoryNoteSink();
      final dispatcher = VoiceCommandDispatcher(
        noteSink: sink,
        resolver: _FixedResolver(
          VoiceCommand(
            intent: VoiceIntent.takeNote,
            transcript: 'x',
            slots: {'text': 'z' * (VoiceLimits.maxNoteChars + 500)},
          ),
        ),
      );
      addTearDown(dispatcher.dispose);

      final result = await dispatcher.dispatch('take a note');
      expect(result.success, isTrue);
      expect(sink.notes.single.text.length, VoiceLimits.maxNoteChars);
    });

    test('a pathologically long transcript still parses quickly', () async {
      final dispatcher = VoiceCommandDispatcher();
      addTearDown(dispatcher.dispose);
      final sw = Stopwatch()..start();
      await dispatcher.dispatch('a ' * 100000); // 200k chars
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });
  });
}
