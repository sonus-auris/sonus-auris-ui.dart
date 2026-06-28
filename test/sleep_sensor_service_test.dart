import 'package:audio_dashcam/src/services/sleep_sensor_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses native sleep sensor snapshot', () {
    final snapshot = SleepSensorSnapshot.fromMap({
      'sampledAtMillis': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      'motionStillnessScore': 0.87,
      'ambientLux': 2.5,
      'screenBrightness': 0.2,
      'motionAvailable': true,
      'ambientLightAvailable': true,
    });

    expect(snapshot.sampledAtUtc, DateTime.utc(2026, 1, 1));
    expect(snapshot.motionStillnessScore, 0.87);
    expect(snapshot.ambientLux, 2.5);
    expect(snapshot.screenBrightness, 0.2);
    expect(snapshot.toSignalValues().motionStillnessScore, 0.87);
    expect(snapshot.toSignalValues().ambientLux, 2.5);
  });

  test('does not expose unavailable native values as signals', () {
    final snapshot = SleepSensorSnapshot.fromMap({
      'motionStillnessScore': 0.1,
      'ambientLux': 900,
      'motionAvailable': false,
      'ambientLightAvailable': false,
    });

    expect(snapshot.toSignalValues().motionStillnessScore, isNull);
    expect(snapshot.toSignalValues().ambientLux, isNull);
  });
}
