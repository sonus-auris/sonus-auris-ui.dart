import 'package:flutter_test/flutter_test.dart';
import 'package:audio_dashcam/src/services/keyword_quality_boost.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);

  test('is inactive until triggered', () {
    final boost = KeywordQualityBoost();
    expect(boost.isActive(t0), isFalse);
    expect(boost.activeUntil, isNull);
  });

  test('a trigger opens a window for exactly its duration', () {
    final boost = KeywordQualityBoost()
      ..trigger(t0, const Duration(minutes: 90));
    expect(boost.isActive(t0), isTrue);
    expect(boost.isActive(t0.add(const Duration(minutes: 89))), isTrue);
    // The window is half-open: active strictly before the expiry instant.
    expect(boost.isActive(t0.add(const Duration(minutes: 90))), isFalse);
    expect(boost.isActive(t0.add(const Duration(minutes: 91))), isFalse);
  });

  test('overlapping triggers extend, never shorten, the window', () {
    final boost = KeywordQualityBoost()
      ..trigger(t0, const Duration(minutes: 90));
    // A later, shorter-from-now trigger must not pull the expiry in.
    boost.trigger(t0.add(const Duration(minutes: 10)), const Duration(minutes: 5));
    expect(boost.activeUntil, t0.add(const Duration(minutes: 90)));
    // A trigger that reaches further out wins.
    boost.trigger(t0.add(const Duration(minutes: 80)), const Duration(minutes: 90));
    expect(boost.activeUntil, t0.add(const Duration(minutes: 170)));
  });

  test('clear closes the window', () {
    final boost = KeywordQualityBoost()
      ..trigger(t0, const Duration(minutes: 90))
      ..clear();
    expect(boost.isActive(t0), isFalse);
    expect(boost.activeUntil, isNull);
  });
}
