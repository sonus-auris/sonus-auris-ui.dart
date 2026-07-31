import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/services/collision_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);
  const g = 9.80665;

  test('resting gravity does not trigger', () {
    final d = CollisionDetector(thresholdG: 2.5);
    expect(d.addMagnitude(t0, g), isNull);
    // Ordinary handling wobble (~1.3g) stays under the threshold.
    expect(d.addMagnitude(t0, g * 1.3), isNull);
  });

  test('an impact past the threshold fires once', () {
    final d = CollisionDetector(thresholdG: 2.5);
    final hit = d.addMagnitude(t0, g * 4); // ~3g deviation
    expect(hit, isNotNull);
    expect(hit!.peakG, closeTo(3.0, 0.001));
  });

  test('free-fall toward 0g is an impact too (deviation is absolute)', () {
    final d = CollisionDetector(thresholdG: 0.8);
    expect(d.addMagnitude(t0, 0), isNotNull); // 1g below rest
  });

  test('the refractory window collapses one impact into a single event', () {
    final d = CollisionDetector(
      thresholdG: 2.5,
      refractory: const Duration(seconds: 3),
    );
    expect(d.addMagnitude(t0, g * 5), isNotNull);
    // Ringing samples within 3s are suppressed.
    expect(d.addMagnitude(t0.add(const Duration(seconds: 1)), g * 5), isNull);
    expect(d.addMagnitude(t0.add(const Duration(seconds: 2)), g * 6), isNull);
    // A fresh impact after the window fires again.
    expect(d.addMagnitude(t0.add(const Duration(seconds: 4)), g * 5), isNotNull);
  });

  test('sensitivity threshold is honoured', () {
    final sensitive = CollisionDetector(thresholdG: 1.0);
    final firm = CollisionDetector(thresholdG: 4.0);
    final magnitude = g * 3; // 2g deviation
    expect(sensitive.addMagnitude(t0, magnitude), isNotNull);
    expect(firm.addMagnitude(t0, magnitude), isNull);
  });

  test('3-axis samples reduce to magnitude', () {
    final d = CollisionDetector(thresholdG: 2.5);
    // 0/0/(4g) → magnitude 4g → 3g deviation → fires.
    expect(d.addSample(t0, x: 0, y: 0, z: g * 4), isNotNull);
  });

  test('config round-trips collision settings with sane clamping', () {
    final restored = AppConfig.fromJson(
      AppConfig(
        deviceId: 'd',
        collisionRemindersEnabled: true,
        collisionSensitivityG: 3.2,
      ).toJson(),
    );
    expect(restored.collisionRemindersEnabled, isTrue);
    expect(restored.collisionSensitivityG, 3.2);

    expect(AppConfig(deviceId: 'd').collisionRemindersEnabled, isFalse);
    expect(AppConfig(deviceId: 'd').collisionSensitivityG, 2.5);
    final absurd = AppConfig.fromJson({
      'deviceId': 'd',
      'collisionSensitivityG': 999.0,
    });
    expect(absurd.collisionSensitivityG, 16.0);
  });
}
