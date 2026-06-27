import 'package:audio_dashcam/src/models/sleep_cycle.dart';
import 'package:audio_dashcam/src/models/sleep_session.dart';
import 'package:audio_dashcam/src/services/sleep_cycle_profile_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

SleepSession _night(String id, DateTime start, List<double> lengths) {
  var t = start;
  final cycles = <SleepCycle>[];
  for (var i = 0; i < lengths.length; i++) {
    final end = t.add(Duration(seconds: (lengths[i] * 60).round()));
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
    id: id,
    startedAtUtc: start,
    endedAtUtc: t,
    cycles: cycles,
    dominantCycleMinutes: lengths.isEmpty ? 0 : lengths.first,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('round-trips a saved session', () async {
    final store = SleepCycleProfileStore();
    final now = DateTime.utc(2026, 6, 1, 7);
    await store.saveSession(
      _night('a', DateTime.utc(2026, 5, 31, 23), [90, 92, 95]),
      now: now,
    );
    final loaded = await store.loadSessions();
    expect(loaded, hasLength(1));
    expect(loaded.first.cycles, hasLength(3));
  });

  test('prunes sessions older than 35 days', () async {
    final store = SleepCycleProfileStore();
    final now = DateTime.utc(2026, 6, 10, 7);
    // Old (40 days) + recent (2 days).
    await store.saveSession(
      _night('old', now.subtract(const Duration(days: 40)), [90, 90]),
      now: now,
    );
    await store.saveSession(
      _night('recent', now.subtract(const Duration(days: 2)), [88, 91]),
      now: now,
    );
    final loaded = await store.loadSessions();
    expect(loaded.map((s) => s.id), ['recent']);
  });

  test('derives a learned profile from stored nights', () async {
    final store = SleepCycleProfileStore();
    final now = DateTime.utc(2026, 6, 20, 7);
    for (var d = 1; d <= 5; d++) {
      await store.saveSession(
        _night('n$d', now.subtract(Duration(days: d)), [80, 82, 79, 81, 80]),
        now: now,
      );
    }
    final profile = await store.loadProfile();
    expect(profile.sampleNights, 5);
    expect(profile.overallMeanMinutes, closeTo(80, 3));
  });
}
