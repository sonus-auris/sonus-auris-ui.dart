import 'package:audio_dashcam/src/models/sleep_cycle.dart';
import 'package:audio_dashcam/src/models/sleep_cycle_profile.dart';
import 'package:audio_dashcam/src/models/sleep_session.dart';
import 'package:flutter_test/flutter_test.dart';

SleepSession _night(int dayOffset, List<double> cycleMinutes) {
  final start = DateTime.utc(2026, 1, 1).add(Duration(days: dayOffset));
  var t = start;
  final cycles = <SleepCycle>[];
  for (var i = 0; i < cycleMinutes.length; i++) {
    final end = t.add(Duration(seconds: (cycleMinutes[i] * 60).round()));
    cycles.add(SleepCycle(
      index: i + 1,
      startedAtUtc: t,
      endedAtUtc: end,
      minDepth: 0.3,
      maxDepth: 0.8,
    ));
    t = end;
  }
  return SleepSession(
    id: 'n$dayOffset',
    startedAtUtc: start,
    endedAtUtc: t,
    cycles: cycles,
    dominantCycleMinutes: cycleMinutes.isEmpty ? 0 : cycleMinutes.first,
  );
}

void main() {
  test('cold start falls back to the default cycle length', () {
    const profile = SleepCycleProfile.initial(defaultCycleMinutes: 90);
    expect(profile.cumulativeMinutesToEndOfCycle(5), 450); // 7.5 h
    expect(profile.cumulativeMinutesToEndOfCycle(6), 540); // 9 h
  });

  test('learns a short-cycle user (~75 min)', () {
    final sessions = [
      for (var d = 0; d < 7; d++) _night(d, [75, 76, 74, 77, 75]),
    ];
    final profile = SleepCycleProfile.learn(sessions);
    expect(profile.overallMeanMinutes, closeTo(75, 3));
    // 5th-cycle target lands near 5 * 75 = 375 min, not the 450 default.
    expect(profile.cumulativeMinutesToEndOfCycle(5), closeTo(375, 20));
    expect(profile.sampleNights, 7);
    expect(profile.confidence, greaterThan(0));
  });

  test('captures within-night drift (later cycles longer)', () {
    final sessions = [
      for (var d = 0; d < 10; d++) _night(d, [70, 80, 90, 100, 110]),
    ];
    final profile = SleepCycleProfile.learn(sessions);
    expect(profile.expectedLengthOfCycle(1),
        lessThan(profile.expectedLengthOfCycle(5)));
    // Cumulative respects the drift rather than meanCycle * n.
    final cum5 = profile.cumulativeMinutesToEndOfCycle(5);
    expect(cum5, closeTo(450, 30));
  });

  test('ignores nights with no measured cycles', () {
    final sessions = [_night(0, const []), _night(1, [90, 92])];
    final profile = SleepCycleProfile.learn(sessions);
    expect(profile.sampleNights, 1);
  });
}
