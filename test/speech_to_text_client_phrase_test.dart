import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/services/speech_to_text_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final client = SpeechToTextClient();

  tearDownAll(client.close);

  test('safety words take precedence over duplicate keywords', () {
    const config = AppConfig(
      deviceId: 'device-1',
      keywords: ['help'],
      safeWords: ['help'],
    );

    final match = client.matchKeyword(config, 'Please HELP me.');

    expect(match, isNotNull);
    expect(match!.keyword, 'help');
    expect(match.kind, SpokenPhraseKind.safeWord);
    expect(match.isSafeWord, isTrue);
  });

  test('ordinary keyword matches are labeled separately', () {
    const config = AppConfig(deviceId: 'device-1', keywords: ['new idea']);

    final match = client.matchKeyword(config, 'I have a New Idea!');

    expect(match, isNotNull);
    expect(match!.kind, SpokenPhraseKind.keyword);
    expect(match.isSafeWord, isFalse);
  });

  test('short phrases do not match inside unrelated words', () {
    const config = AppConfig(deviceId: 'device-1', safeWords: ['he']);

    expect(client.matchKeyword(config, 'the theater'), isNull);
    expect(client.matchKeyword(config, 'He said it.'), isNotNull);
  });

  test('configured punctuation is treated literally', () {
    const config = AppConfig(deviceId: 'device-1', keywords: ['case closed']);

    expect(client.matchKeyword(config, 'Okay—case closed.'), isNotNull);
    expect(client.matchKeyword(config, 'showcase closed'), isNull);
  });
}
