import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/models/sleep_cycle.dart';
import 'package:audio_dashcam/src/models/sleep_epoch.dart';
import 'package:audio_dashcam/src/models/sleep_session.dart';
import 'package:audio_dashcam/src/models/sleep_stage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SleepStage', () {
    test('isShallow only for awake/light/rem', () {
      expect(SleepStage.awake.isShallow, isTrue);
      expect(SleepStage.light.isShallow, isTrue);
      expect(SleepStage.rem.isShallow, isTrue);
      expect(SleepStage.deep.isShallow, isFalse);
      expect(SleepStage.unknown.isShallow, isFalse);
    });

    test('fromName round-trips and falls back to unknown', () {
      for (final s in SleepStage.values) {
        expect(SleepStage.fromName(s.name), s);
      }
      expect(SleepStage.fromName('nonsense'), SleepStage.unknown);
      expect(SleepStage.fromName(null), SleepStage.unknown);
    });
  });

  test('SleepEpoch JSON round-trip preserves fields', () {
    final e = SleepEpoch(
      startedAtUtc: DateTime.utc(2026, 1, 1, 23),
      endedAtUtc: DateTime.utc(2026, 1, 1, 23, 0, 30),
      meanDb: -55.5,
      movement: 0.12,
      snoreFraction: 0.3,
      breathingRateBpm: 14.2,
      breathingRegularity: 0.66,
      depth: 0.7,
      stage: SleepStage.deep,
    );
    final back = SleepEpoch.fromJson(e.toJson());
    expect(back.meanDb, e.meanDb);
    expect(back.movement, e.movement);
    expect(back.breathingRateBpm, e.breathingRateBpm);
    expect(back.depth, e.depth);
    expect(back.stage, SleepStage.deep);
    expect(back.duration, const Duration(seconds: 30));
  });

  test('SleepCycle length + round-trip', () {
    final c = SleepCycle(
      index: 2,
      startedAtUtc: DateTime.utc(2026, 1, 1, 23),
      endedAtUtc: DateTime.utc(2026, 1, 2, 0, 30),
      minDepth: 0.2,
      maxDepth: 0.9,
    );
    expect(c.lengthMinutes, closeTo(90, 0.001));
    final back = SleepCycle.fromJson(c.toJson());
    expect(back.index, 2);
    expect(back.lengthMinutes, closeTo(90, 0.001));
    expect(back.maxDepth, 0.9);
  });

  test('SleepSession derived getters + round-trip', () {
    final start = DateTime.utc(2026, 1, 1, 23);
    final s = SleepSession(
      id: 'n1',
      startedAtUtc: start,
      endedAtUtc: start.add(const Duration(hours: 8)),
      cycles: [
        SleepCycle(
          index: 1,
          startedAtUtc: start,
          endedAtUtc: start.add(const Duration(minutes: 88)),
          minDepth: 0.3,
          maxDepth: 0.8,
        ),
        SleepCycle(
          index: 2,
          startedAtUtc: start.add(const Duration(minutes: 88)),
          endedAtUtc: start.add(const Duration(minutes: 180)),
          minDepth: 0.3,
          maxDepth: 0.85,
        ),
      ],
      dominantCycleMinutes: 90,
      depthEnvelope: const [0.1, 0.5, 0.9, 0.4],
    );
    expect(s.totalMinutes, closeTo(480, 0.001));
    expect(s.cycleLengthsMinutes, [closeTo(88, 0.1), closeTo(92, 0.1)]);
    // Night filed under the local start date.
    expect(s.nightLocalDate, DateTime(
      start.toLocal().year,
      start.toLocal().month,
      start.toLocal().day,
    ));

    final back = SleepSession.fromJson(s.toJson());
    expect(back.id, 'n1');
    expect(back.cycles, hasLength(2));
    expect(back.dominantCycleMinutes, 90);
    expect(back.depthEnvelope, [0.1, 0.5, 0.9, 0.4]);
  });

  test('SleepSession.fromJson tolerates missing optional fields', () {
    final start = DateTime.utc(2026, 1, 1, 23);
    final json = {
      'id': 'x',
      'startedAtUtc': start.toIso8601String(),
      'endedAtUtc': start.add(const Duration(hours: 7)).toIso8601String(),
      // no cycles, dominant, envelope
    };
    final s = SleepSession.fromJson(json);
    expect(s.cycles, isEmpty);
    expect(s.dominantCycleMinutes, 0);
    expect(s.depthEnvelope, isEmpty);
  });

  group('AcousticDetection sleep kinds', () {
    test('new kinds parse, label, and round-trip', () {
      for (final k in [
        AcousticDetectionKind.sleepEpoch,
        AcousticDetectionKind.sleepCycle,
      ]) {
        expect(AcousticDetectionKind.fromName(k.name), k);
        expect(k.label, isNotEmpty);
      }
      final d = AcousticDetection(
        kind: AcousticDetectionKind.sleepCycle,
        startedAtUtc: DateTime.utc(2026, 1, 1, 23),
        endedAtUtc: DateTime.utc(2026, 1, 2, 0, 30),
        confidence: 0.7,
        details: const {'cycleIndex': 1, 'lengthMinutes': 90.0},
      );
      final back = AcousticDetection.fromJson(d.toJson());
      expect(back.kind, AcousticDetectionKind.sleepCycle);
      expect(back.details['cycleIndex'], 1);
    });
  });
}
