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

  test('estimate is phase-invariant', () {
    const stepMinutes = 5.0;
    const period = 95.0;
    List<double> withPhase(double phase) => List<double>.generate(
          96,
          (i) =>
              0.5 + 0.4 * math.sin(2 * math.pi * i * stepMinutes / period + phase),
        );
    final a = estimator.estimate(withPhase(0), stepMinutes);
    final b = estimator.estimate(withPhase(1.3), stepMinutes);
    expect(a.periodMinutes, closeTo(b.periodMinutes, 3));
  });

  test('recovers a long 120-min cycle', () {
    const stepMinutes = 5.0;
    final samples = List<double>.generate(
      120,
      (i) => 0.5 + 0.4 * math.sin(2 * math.pi * i * stepMinutes / 120.0),
    );
    final est = estimator.estimate(samples, stepMinutes);
    expect(est.periodMinutes, closeTo(120, 10));
  });

  test('flat signal yields no usable peak', () {
    final flat = List<double>.filled(96, 0.5);
    final est = estimator.estimate(flat, 5.0);
    // No oscillation → either invalid or near-zero strength.
    expect(est.strength, lessThan(0.2));
  });

  test('white noise has lower strength than a clean cycle', () {
    const stepMinutes = 5.0;
    final rng = math.Random(7);
    final noise = List<double>.generate(96, (_) => rng.nextDouble());
    final clean = List<double>.generate(
      96,
      (i) => 0.5 + 0.4 * math.sin(2 * math.pi * i * stepMinutes / 90.0),
    );
    final noiseEst = estimator.estimate(noise, stepMinutes);
    final cleanEst = estimator.estimate(clean, stepMinutes);
    expect(cleanEst.strength, greaterThan(noiseEst.strength));
  });
}
