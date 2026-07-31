import 'package:audio_dashcam/src/services/collision_sensor_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 7, 25, 12);

  MotionSample sample(double x, Duration offset) =>
      MotionSample(x: x, y: 0, z: 0, sampledAtUtc: start.add(offset));

  test(
    'ignores ordinary movement and detects an abrupt collision-sized spike',
    () {
      final detector = CollisionDetector();

      expect(detector.add(sample(3, Duration.zero)), isNull);
      final collision = detector.add(
        sample(31, const Duration(milliseconds: 20)),
      );

      expect(collision, isNotNull);
      expect(collision!.accelerationMetersPerSecondSquared, 31);
    },
  );

  test('rate limits repeated spikes and re-arms after the cooldown', () {
    final detector = CollisionDetector(cooldown: const Duration(seconds: 30));

    expect(detector.add(sample(35, Duration.zero)), isNotNull);
    expect(detector.add(sample(2, const Duration(seconds: 1))), isNull);
    expect(detector.add(sample(38, const Duration(seconds: 2))), isNull);
    expect(detector.add(sample(2, const Duration(seconds: 31))), isNull);
    expect(detector.add(sample(38, const Duration(seconds: 32))), isNotNull);
  });

  test('does not classify smooth high acceleration as a collision', () {
    final detector = CollisionDetector();

    expect(detector.add(sample(22, Duration.zero)), isNull);
    expect(detector.add(sample(27, const Duration(milliseconds: 20))), isNull);
  });
}
