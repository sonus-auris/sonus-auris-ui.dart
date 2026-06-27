import 'package:audio_dashcam/src/models/sleep_sensor_sample.dart';
import 'package:audio_dashcam/src/models/sleep_stage.dart';
import 'package:audio_dashcam/src/services/sleep_probability_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const model = SleepProbabilityModel();

  test('still + dark + charging => high sleep probability, deep stays deep', () {
    final est = model.fuse(
      acousticDepth: 0.7,
      acousticStage: SleepStage.deep,
      breathingRegularity: 0.8,
      snoreFraction: 0.3,
      sensors: const SleepSensorEpoch(
        movement: 0.02,
        meanLux: 1.0,
        hasMotion: true,
        hasLight: true,
        sampleCount: 30,
      ),
      context: const SleepFusionContext(charging: true),
    );
    expect(est.sleepProbability, greaterThan(0.8));
    expect(est.fusedStage, SleepStage.deep);
    expect(est.fusedDepth, greaterThan(0.6));
  });

  test('strong movement => awake, low depth, even if audio said deep', () {
    final est = model.fuse(
      acousticDepth: 0.7,
      acousticStage: SleepStage.deep,
      breathingRegularity: 0.8,
      snoreFraction: 0.0,
      sensors: const SleepSensorEpoch(
        movement: 0.9,
        meanLux: 1.0,
        hasMotion: true,
        hasLight: true,
        sampleCount: 30,
      ),
    );
    expect(est.fusedStage, SleepStage.awake);
    expect(est.fusedDepth, lessThan(0.3));
    expect(est.sleepProbability, lessThan(0.5));
  });

  test('bright room => awake (morning / lights on)', () {
    final est = model.fuse(
      acousticDepth: 0.6,
      acousticStage: SleepStage.light,
      breathingRegularity: 0.5,
      snoreFraction: 0.0,
      sensors: const SleepSensorEpoch(
        movement: 0.1,
        meanLux: 200,
        hasMotion: true,
        hasLight: true,
        sampleCount: 30,
      ),
    );
    expect(est.fusedStage, SleepStage.awake);
  });

  test('audio-only (no sensors) passes acoustic depth through', () {
    final est = model.fuse(
      acousticDepth: 0.7,
      acousticStage: SleepStage.deep,
      breathingRegularity: 0.8,
      snoreFraction: 0.2,
    );
    expect(est.fusedDepth, closeTo(0.7, 0.001));
    expect(est.fusedStage, SleepStage.deep);
  });

  test('recent phone use forces awake', () {
    final est = model.fuse(
      acousticDepth: 0.6,
      acousticStage: SleepStage.light,
      breathingRegularity: 0.5,
      snoreFraction: 0.0,
      context: const SleepFusionContext(minutesSincePhoneInteraction: 0.5),
    );
    expect(est.fusedStage, SleepStage.awake);
  });

  test('charging raises sleep probability vs not charging', () {
    double prob(bool? charging) => model
        .fuse(
          acousticDepth: 0.55,
          acousticStage: SleepStage.light,
          breathingRegularity: 0.5,
          snoreFraction: 0.0,
          context: SleepFusionContext(charging: charging),
        )
        .sleepProbability;
    expect(prob(true), greaterThan(prob(false)));
  });

  test('within usual bedtime raises sleep probability', () {
    double prob(bool? usual) => model
        .fuse(
          acousticDepth: 0.5,
          acousticStage: SleepStage.light,
          breathingRegularity: 0.5,
          snoreFraction: 0.0,
          context: SleepFusionContext(withinUsualSleepWindow: usual),
        )
        .sleepProbability;
    expect(prob(true), greaterThan(prob(false)));
  });

  test('sleep probability is monotonic decreasing in movement', () {
    double prob(double movement) => model
        .fuse(
          acousticDepth: 0.6,
          acousticStage: SleepStage.light,
          breathingRegularity: 0.6,
          snoreFraction: 0.0,
          sensors: SleepSensorEpoch(
            movement: movement,
            meanLux: 1,
            hasMotion: true,
            hasLight: true,
            sampleCount: 30,
          ),
        )
        .sleepProbability;
    expect(prob(0.05), greaterThan(prob(0.25)));
    expect(prob(0.25), greaterThan(prob(0.6)));
  });

  test('probability stays within 0..1', () {
    for (final d in [0.0, 0.5, 1.0]) {
      final est = model.fuse(
        acousticDepth: d,
        acousticStage: SleepStage.deep,
        breathingRegularity: 1.0,
        snoreFraction: 1.0,
        context: const SleepFusionContext(
          charging: true,
          withinUsualSleepWindow: true,
          minutesSincePhoneInteraction: 60,
        ),
      );
      expect(est.sleepProbability, inInclusiveRange(0.0, 1.0));
      expect(est.fusedDepth, inInclusiveRange(0.0, 1.0));
    }
  });
}
