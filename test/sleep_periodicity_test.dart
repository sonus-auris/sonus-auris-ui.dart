import 'dart:math' as math;

import 'package:audio_dashcam/src/services/acoustic/sleep_periodicity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const estimator = SleepPeriodicityEstimator();

  test('recovers a known ~90 min cycle from a depth envelope', () {
    const stepMinutes = 5.0;
    const periodMinutes = 90.0;
    // 8 hours of 5-min depth samples oscillating with a 90-min period.
    final samples = List<double>.generate(96, (i) {
      final t = i * stepMinutes;
      return 0.5 + 0.4 * math.sin(2 * math.pi * t / periodMinutes);
    });

    final est = estimator.estimate(samples, stepMinutes);
    expect(est.isValid, isTrue);
    expect(est.periodMinutes, closeTo(90, 8));
    expect(est.strength, greaterThan(0.2));
  });

  test('recovers a shorter 75 min cycle (per-user variation)', () {
    const stepMinutes = 5.0;
    const periodMinutes = 75.0;
    final samples = List<double>.generate(96, (i) {
      final t = i * stepMinutes;
      return 0.5 + 0.35 * math.sin(2 * math.pi * t / periodMinutes + 0.7);
    });

    final est = estimator.estimate(samples, stepMinutes);
    expect(est.isValid, isTrue);
    expect(est.periodMinutes, closeTo(75, 8));
  });

  test('too little data yields no estimate', () {
    final est = estimator.estimate([0.4, 0.5, 0.6, 0.5], 5.0);
    expect(est.isValid, isFalse);
  });
}
