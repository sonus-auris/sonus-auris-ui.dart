import 'package:audio_dashcam/src/models/sleep_cycle_profile.dart';
import 'package:flutter_test/flutter_test.dart';

SleepCycleObservation obs({
  required DateTime endedAtUtc,
  required int cycleIndex,
  required double observed,
  List<double> vector = const [],
}) {
  return SleepCycleObservation(
    endedAtUtc: endedAtUtc,
    cycleIndex: cycleIndex,
    observedCycleMinutes: observed,
    estimatedCycleMinutes: observed,
    cycleMinutesByIndex: vector,
  );
}

void main() {
  test('prunes observations older than 35 days', () {
    final now = DateTime.utc(2026, 6, 27, 8);
    final profile = SleepCycleProfile(
      observations: [
        obs(
          endedAtUtc: now.subtract(const Duration(days: 36)),
          cycleIndex: 1,
          observed: 80,
        ),
        obs(
          endedAtUtc: now.subtract(const Duration(days: 35)),
          cycleIndex: 1,
          observed: 85,
        ),
        obs(
          endedAtUtc: now.subtract(const Duration(days: 2)),
          cycleIndex: 2,
          observed: 100,
        ),
      ],
    ).pruned(now);

    expect(profile.observations, hasLength(2));
    expect(profile.observations.first.observedCycleMinutes, 85);
  });

  test('summarizes each cycle index separately', () {
    final now = DateTime.utc(2026, 6, 27, 8);
    final profile = SleepCycleProfile(
      observations: [
        obs(
          endedAtUtc: now.subtract(const Duration(days: 3)),
          cycleIndex: 1,
          observed: 75,
        ),
        obs(
          endedAtUtc: now.subtract(const Duration(days: 2)),
          cycleIndex: 1,
          observed: 90,
        ),
        obs(
          endedAtUtc: now.subtract(const Duration(days: 1)),
          cycleIndex: 5,
          observed: 115,
        ),
      ],
    ).pruned(now);

    final seeds = profile.cycleMinuteSeeds(maxCycles: 6);
    expect(seeds[0], closeTo(85, 0.1));
    expect(seeds[4], 115);
    expect(seeds[5], 115);
  });

  test(
    'uses latest detector vector when a cycle has no direct observation',
    () {
      final now = DateTime.utc(2026, 6, 27, 8);
      final profile = SleepCycleProfile(
        observations: [
          obs(
            endedAtUtc: now,
            cycleIndex: 1,
            observed: 90,
            vector: const [90, 95, 100, 105, 110, 115],
          ),
        ],
      );

      expect(profile.cycleMinuteSeeds(maxCycles: 6), [
        90,
        95,
        100,
        105,
        110,
        115,
      ]);
    },
  );

  test('skips malformed persisted observations', () {
    final profile = SleepCycleProfile.fromJson({
      'observations': [
        {'endedAtUtc': 'not-a-date', 'cycleIndex': 1},
        {'endedAtUtc': DateTime.utc(2026, 6, 27).toIso8601String()},
        {
          'endedAtUtc': DateTime.utc(2026, 6, 27, 8).toIso8601String(),
          'cycleIndex': 2,
          'observedCycleMinutes': 82,
          'estimatedCycleMinutes': 90,
        },
      ],
    });

    expect(profile.observations, hasLength(1));
    expect(profile.observations.single.cycleIndex, 2);
    expect(profile.observations.single.observedCycleMinutes, 82);
  });
}
