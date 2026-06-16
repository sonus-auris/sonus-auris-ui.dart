import 'package:audio_dashcam/src/models/recording_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

RecordingWindow w(int start, int end) =>
    RecordingWindow(startMinute: start, endMinute: end);

void main() {
  group('DaySchedule.normalize', () {
    test('sorts, drops empties, and clamps out-of-range windows', () {
      final day = DaySchedule(
        windows: [
          w(600, 540), // inverted -> dropped
          w(120, 60), // negative length -> dropped
          w(540, 600),
          w(60, 120),
          w(-30, 30), // clamps to 0..30
        ],
      );
      expect(day.normalizedWindows(), [w(0, 30), w(60, 120), w(540, 600)]);
    });

    test('merges overlapping windows', () {
      final day = DaySchedule(windows: [w(60, 180), w(120, 240)]);
      expect(day.normalizedWindows(), [w(60, 240)]);
    });

    test('merges touching windows (handle dragged onto its neighbour)', () {
      // End of one equals start of the next -> they fuse into one smooth span.
      final day = DaySchedule(windows: [w(60, 120), w(120, 200)]);
      expect(day.normalizedWindows(), [w(60, 200)]);
    });

    test('keeps a real gap between split windows', () {
      final day = DaySchedule(windows: [w(60, 120), w(135, 200)]);
      expect(day.normalizedWindows(), [w(60, 120), w(135, 200)]);
    });

    test('allDay collapses to a single full-day window', () {
      const day = DaySchedule(allDay: true, windows: []);
      expect(day.effectiveWindows(), [w(0, kMinutesPerDay)]);
      expect(day.isActiveAtMinute(0), isTrue);
      expect(day.isActiveAtMinute(kMinutesPerDay - 1), isTrue);
    });
  });

  group('RecordingSchedule.isActiveAt', () {
    test('is false when disabled regardless of windows', () {
      final schedule = RecordingSchedule(
        enabled: false,
        days: List.generate(7, (_) => const DaySchedule(allDay: true)),
      );
      expect(schedule.isActiveAt(DateTime(2026, 6, 15, 10)), isFalse);
    });

    test('respects per-day windows on the correct weekday', () {
      // 2026-06-15 is a Monday (index 0); window 09:00-17:00.
      final schedule = RecordingSchedule(
        enabled: true,
        days: [
          DaySchedule(windows: [w(9 * 60, 17 * 60)]),
          ...List.generate(6, (_) => DaySchedule.empty),
        ],
      );
      expect(schedule.isActiveAt(DateTime(2026, 6, 15, 8, 59)), isFalse);
      expect(schedule.isActiveAt(DateTime(2026, 6, 15, 9, 0)), isTrue);
      expect(schedule.isActiveAt(DateTime(2026, 6, 15, 16, 59)), isTrue);
      expect(schedule.isActiveAt(DateTime(2026, 6, 15, 17, 0)), isFalse);
      // Tuesday has no window.
      expect(schedule.isActiveAt(DateTime(2026, 6, 16, 10, 0)), isFalse);
    });
  });

  group('RecordingSchedule transitions', () {
    final schedule = RecordingSchedule(
      enabled: true,
      days: [
        DaySchedule(windows: [w(9 * 60, 17 * 60)]), // Monday 9-5
        ...List.generate(6, (_) => DaySchedule.empty),
      ],
    );

    test('nextTransitionAfter returns the upcoming start then stop', () {
      final beforeStart = DateTime(2026, 6, 15, 8, 0);
      final start = schedule.nextTransitionAfter(beforeStart);
      expect(start, isNotNull);
      expect(start!.startsRecording, isTrue);
      expect(start.at, DateTime(2026, 6, 15, 9, 0));

      final duringWindow = DateTime(2026, 6, 15, 12, 0);
      final stop = schedule.nextTransitionAfter(duringWindow);
      expect(stop!.startsRecording, isFalse);
      expect(stop.at, DateTime(2026, 6, 15, 17, 0));
    });

    test('upcomingTransitions yields ordered start/stop pairs', () {
      final from = DateTime(2026, 6, 15, 0, 0);
      final transitions = schedule.upcomingTransitions(from, horizonDays: 2);
      expect(transitions.length, 2);
      expect(transitions[0].at, DateTime(2026, 6, 15, 9, 0));
      expect(transitions[0].startsRecording, isTrue);
      expect(transitions[1].at, DateTime(2026, 6, 15, 17, 0));
      expect(transitions[1].startsRecording, isFalse);
    });

    test('end-of-day window stops at the next midnight (wall-clock)', () {
      // A 23:00–24:00 window: start at 23:00, stop at the next day's 00:00.
      final late = RecordingSchedule(
        enabled: true,
        days: [
          DaySchedule(windows: [w(23 * 60, kMinutesPerDay)]),
          ...List.generate(6, (_) => DaySchedule.empty),
        ],
      );
      final start = late.nextTransitionAfter(DateTime(2026, 6, 15, 22, 0));
      expect(start!.at, DateTime(2026, 6, 15, 23, 0));
      expect(start.startsRecording, isTrue);
      final stop = late.nextTransitionAfter(DateTime(2026, 6, 15, 23, 30));
      expect(stop!.at, DateTime(2026, 6, 16, 0, 0));
      expect(stop.startsRecording, isFalse);
    });

    test('back-to-back all-day windows produce no seam transition', () {
      final allWeek = RecordingSchedule(
        enabled: true,
        days: List.generate(7, (_) => const DaySchedule(allDay: true)),
      );
      // Active the whole week -> the only "next" transition is far past horizon.
      final next = allWeek.nextTransitionAfter(
        DateTime(2026, 6, 15, 10, 0),
        horizonDays: 3,
      );
      expect(next, isNull);
    });
  });

  group('JSON round-trip', () {
    test('serializes and restores a populated schedule', () {
      final schedule = RecordingSchedule(
        enabled: true,
        days: [
          DaySchedule(windows: [w(9 * 60, 12 * 60), w(13 * 60, 17 * 60)]),
          const DaySchedule(allDay: true),
          ...List.generate(5, (_) => DaySchedule.empty),
        ],
      );
      final restored = RecordingSchedule.fromJson(schedule.toJson());
      expect(restored, schedule);
    });

    test('null/empty JSON yields the disabled default', () {
      final restored = RecordingSchedule.fromJson(null);
      expect(restored.enabled, isFalse);
      expect(restored.days.length, 7);
    });

    test('pads a short day list to seven days', () {
      final restored = RecordingSchedule.fromJson({
        'enabled': true,
        'days': [
          {
            'allDay': false,
            'windows': [
              {'start': 60, 'end': 120},
            ],
          },
        ],
      });
      expect(restored.days.length, 7);
      expect(restored.days[0].normalizedWindows(), [w(60, 120)]);
      expect(restored.days[6], DaySchedule.empty);
    });

    test('accepts legacy startMinute/endMinute window fields', () {
      final restored = RecordingSchedule.fromJson({
        'enabled': true,
        'days': [
          {
            'allDay': false,
            'windows': [
              {'startMinute': 480, 'endMinute': 540},
            ],
          },
        ],
      });
      expect(restored.days[0].normalizedWindows(), [w(480, 540)]);
    });

    test('places legacy dayOfWeek entries on the matching weekday', () {
      final restored = RecordingSchedule.fromJson({
        'enabled': true,
        'days': [
          {
            'dayOfWeek': 3,
            'allDay': false,
            'windows': [
              {'startMinute': 600, 'endMinute': 660},
            ],
          },
        ],
      });
      expect(restored.days[0], DaySchedule.empty);
      expect(restored.days[2].normalizedWindows(), [w(600, 660)]);
    });
  });
}
