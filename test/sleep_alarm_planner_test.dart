import 'package:audio_dashcam/src/models/sleep_cycle_profile.dart';
import 'package:audio_dashcam/src/models/sleep_stage.dart';
import 'package:audio_dashcam/src/services/sleep_alarm_planner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const planner = SleepAlarmPlanner();
  const profile = SleepCycleProfile.initial(defaultCycleMinutes: 90);
  final onset = DateTime.utc(2026, 1, 1, 23, 0); // 11pm

  SleepAlarmPlan buildPlan() => planner.plan(
        onsetUtc: onset,
        measuredCycleMinutes: const [],
        profile: profile,
        targetCycle: 5,
        backstopCycle: 6,
        smartWindowMinutes: 25,
      );

  test('default plan targets 7.5h and backstops at 9h', () {
    final plan = buildPlan();
    expect(plan.targetTimeUtc, onset.add(const Duration(minutes: 450)));
    expect(plan.backstopTimeUtc, onset.add(const Duration(minutes: 540)));
    expect(plan.smartWindowStartUtc,
        onset.add(const Duration(minutes: 425))); // 450 - 25
  });

  SleepAlarmDecision evalAt(
    Duration sinceOnset,
    SleepStage stage,
    int cycles,
  ) {
    return planner.evaluate(
      plan: buildPlan(),
      nowUtc: onset.add(sinceOnset),
      smartAlarmEnabled: true,
      stage: stage,
      cyclesCompleted: cycles,
      targetCycle: 5,
      backstopCycle: 6,
    );
  }

  test('before the window: holds regardless of stage', () {
    expect(evalAt(const Duration(hours: 6), SleepStage.light, 4),
        SleepAlarmDecision.hold);
  });

  test('in the window + deep sleep: HOLDS and waits (the key rule)', () {
    // At the 5th-cycle target but in deep sleep → do not wake; wait for light.
    expect(evalAt(const Duration(minutes: 450), SleepStage.deep, 4),
        SleepAlarmDecision.hold);
  });

  test('in the window + light sleep: smart wake', () {
    expect(evalAt(const Duration(minutes: 440), SleepStage.light, 4),
        SleepAlarmDecision.smartWake);
    expect(evalAt(const Duration(minutes: 455), SleepStage.rem, 5),
        SleepAlarmDecision.smartWake);
  });

  test('deep through cycle 5 then light before 9h: still a smart wake', () {
    // Held in deep at 7.5h, then a light arousal at 8.3h → wake (not backstop).
    expect(evalAt(const Duration(minutes: 500), SleepStage.light, 5),
        SleepAlarmDecision.smartWake);
  });

  test('reaching the 6th-cycle backstop wakes even in deep sleep', () {
    expect(evalAt(const Duration(minutes: 540), SleepStage.deep, 5),
        SleepAlarmDecision.backstopWake);
  });

  test('completing the backstop cycle count wakes immediately', () {
    expect(evalAt(const Duration(minutes: 470), SleepStage.deep, 6),
        SleepAlarmDecision.backstopWake);
  });

  test('smart alarm disabled: only the backstop ever fires', () {
    final plan = buildPlan();
    SleepAlarmDecision eval(Duration d, SleepStage s, int c) =>
        planner.evaluate(
          plan: plan,
          nowUtc: onset.add(d),
          smartAlarmEnabled: false,
          stage: s,
          cyclesCompleted: c,
          targetCycle: 5,
          backstopCycle: 6,
        );
    expect(eval(const Duration(minutes: 440), SleepStage.light, 4),
        SleepAlarmDecision.hold);
    expect(eval(const Duration(minutes: 540), SleepStage.deep, 5),
        SleepAlarmDecision.backstopWake);
  });
}
