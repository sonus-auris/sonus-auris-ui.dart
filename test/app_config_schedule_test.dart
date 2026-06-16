import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recording schedule round-trips through app config JSON', () {
    final config = AppConfig(
      deviceId: 'device-1',
      recordingSchedule: WeeklyRecordingSchedule(
        days: [
          RecordingDaySchedule(
            dayOfWeek: DateTime.monday,
            windows: const [
              RecordingWindow(startMinute: 8 * 60, endMinute: 12 * 60),
              RecordingWindow(startMinute: 13 * 60, endMinute: 17 * 60),
            ],
          ),
          const RecordingDaySchedule(dayOfWeek: DateTime.tuesday, allDay: true),
        ],
      ),
    );

    final restored = AppConfig.fromJson(config.toJson());

    expect(restored.recordingSchedule.day(DateTime.monday).normalizedWindows, [
      const RecordingWindow(startMinute: 8 * 60, endMinute: 12 * 60),
      const RecordingWindow(startMinute: 13 * 60, endMinute: 17 * 60),
    ]);
    expect(restored.recordingSchedule.day(DateTime.tuesday).allDay, isTrue);
  });

  test('touching windows reconnect into one smooth window', () {
    final day = RecordingDaySchedule(
      dayOfWeek: DateTime.wednesday,
      windows: const [
        RecordingWindow(startMinute: 9 * 60, endMinute: 11 * 60),
        RecordingWindow(startMinute: 11 * 60, endMinute: 14 * 60),
      ],
    );

    expect(day.normalizedWindows, [
      const RecordingWindow(startMinute: 9 * 60, endMinute: 14 * 60),
    ]);
  });

  test('active state and next barrier follow local weekly windows', () {
    final schedule = WeeklyRecordingSchedule(
      days: [
        RecordingDaySchedule(
          dayOfWeek: DateTime.monday,
          windows: const [
            RecordingWindow(startMinute: 9 * 60, endMinute: 17 * 60),
          ],
        ),
      ],
    );

    final mondayMorning = DateTime(2026, 6, 15, 10);
    final mondayEvening = DateTime(2026, 6, 15, 18);

    expect(schedule.isActiveAt(mondayMorning), isTrue);
    expect(schedule.nextBarrierAfter(mondayMorning), DateTime(2026, 6, 15, 17));
    expect(schedule.isActiveAt(mondayEvening), isFalse);
    expect(schedule.nextBarrierAfter(mondayEvening), DateTime(2026, 6, 22, 9));
  });
}
