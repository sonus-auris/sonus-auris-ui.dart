import 'package:audio_dashcam/src/services/sleep_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const model = SleepProbabilityModel();

  test(
    'combines quiet audio, stillness, darkness, idle charging, and bedtime',
    () {
      final estimate = model.estimate(
        consent: const SleepSignalConsent(
          audio: true,
          motion: true,
          ambientLight: true,
          phoneContext: true,
        ),
        sample: const SleepSignalSample(
          acousticSleepScore: 0.84,
          acousticArousalScore: 0.08,
          motionStillnessScore: 0.95,
          tossingEventsPerHour: 0.4,
          ambientLux: 1.5,
          phoneIdleMinutes: 90,
          isCharging: true,
          usualBedtimeScore: 0.9,
        ),
      );

      expect(estimate.sleepProbability, greaterThan(0.85));
      expect(estimate.likelyAsleep, isTrue);
      expect(estimate.activeSignals, [
        'audio',
        'motion',
        'ambientLight',
        'phoneContext',
      ]);
    },
  );

  test('bright room and motion lower sleep probability', () {
    final estimate = model.estimate(
      consent: const SleepSignalConsent(
        audio: true,
        motion: true,
        ambientLight: true,
        phoneContext: true,
      ),
      sample: const SleepSignalSample(
        acousticSleepScore: 0.35,
        acousticArousalScore: 0.7,
        motionStillnessScore: 0.1,
        tossingEventsPerHour: 14,
        gotUp: true,
        ambientLux: 300,
        phoneIdleMinutes: 1,
        isCharging: false,
        usualBedtimeScore: 0.1,
      ),
    );

    expect(estimate.sleepProbability, lessThan(0.25));
    expect(estimate.likelyAsleep, isFalse);
  });

  test('ignores unconsented motion, light, and phone context signals', () {
    final estimate = model.estimate(
      consent: const SleepSignalConsent(audio: true),
      sample: const SleepSignalSample(
        acousticSleepScore: 0.8,
        acousticArousalScore: 0.1,
        motionStillnessScore: 0.0,
        gotUp: true,
        ambientLux: 500,
        phoneIdleMinutes: 0,
        isCharging: false,
        usualBedtimeScore: 0.0,
      ),
    );

    expect(estimate.sleepProbability, greaterThan(0.65));
    expect(estimate.activeSignals, ['audio']);
  });
}
