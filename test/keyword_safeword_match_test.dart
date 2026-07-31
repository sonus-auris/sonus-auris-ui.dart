import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/services/speech_to_text_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SpeechToTextClient client;
  setUp(() => client = SpeechToTextClient());
  tearDown(() => client.close());

  AppConfig config({
    List<String> keywords = const [],
    List<String> safeWords = const [],
  }) => AppConfig(deviceId: 'd', keywords: keywords, safeWords: safeWords);

  test('matches a keyword case-insensitively', () {
    final match = client.matchKeyword(
      config(keywords: ['Fire']),
      'there is a FIRE outside',
    );
    expect(match, isNotNull);
    expect(match!.keyword, 'Fire');
    expect(match.isSafeWord, isFalse);
  });

  test('matches a safe word and flags it as such', () {
    final match = client.matchKeyword(
      config(safeWords: ['pineapple']),
      'ok pineapple now',
    );
    expect(match, isNotNull);
    expect(match!.keyword, 'pineapple');
    expect(match.isSafeWord, isTrue);
  });

  test('a safe word wins when both are present', () {
    final match = client.matchKeyword(
      config(keywords: ['help'], safeWords: ['banana']),
      'help me banana',
    );
    expect(match!.isSafeWord, isTrue);
    expect(match.keyword, 'banana');
  });

  test('no match returns null', () {
    expect(
      client.matchKeyword(config(keywords: ['fire']), 'all quiet here'),
      isNull,
    );
  });

  test('config round-trips safe words and the boost duration', () {
    final json = AppConfig(
      deviceId: 'd',
      keywords: ['fire'],
      safeWords: ['banana', 'pineapple'],
      keywordQualityBoostMinutes: 45,
    ).toJson();
    final restored = AppConfig.fromJson(json);
    expect(restored.safeWords, ['banana', 'pineapple']);
    expect(restored.keywordQualityBoostMinutes, 45);
  });

  test('boost duration defaults to 90 and is clamped to a sane range', () {
    expect(AppConfig(deviceId: 'd').keywordQualityBoostMinutes, 90);
    final absurd = AppConfig.fromJson({
      'deviceId': 'd',
      'keywordQualityBoostMinutes': 999999,
    });
    expect(absurd.keywordQualityBoostMinutes, 24 * 60);
  });
}
