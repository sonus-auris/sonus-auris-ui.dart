import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/recording_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults to a disabled schedule', () {
    const config = AppConfig(deviceId: 'd');
    expect(config.recordingSchedule.enabled, isFalse);
    expect(config.recordingSchedule.days.length, 7);
  });

  test('round-trips a populated schedule through JSON', () {
    final schedule = RecordingSchedule(
      enabled: true,
      days: [
        const DaySchedule(allDay: true),
        DaySchedule(
          windows: const [RecordingWindow(startMinute: 540, endMinute: 1020)],
        ),
        ...List.generate(5, (_) => DaySchedule.empty),
      ],
    );
    final config = const AppConfig(
      deviceId: 'd',
    ).copyWith(recordingSchedule: schedule);

    final restored = AppConfig.fromJson(config.toJson());

    expect(restored.recordingSchedule, schedule);
  });

  test('config JSON without recordingSchedule stays back-compatible', () {
    final json = const AppConfig(deviceId: 'd').toJson()
      ..remove('recordingSchedule');

    final restored = AppConfig.fromJson(json);

    expect(restored.recordingSchedule.enabled, isFalse);
    expect(restored.recordingSchedule.days.length, 7);
  });

  test('touching windows reconnect into one smooth window', () {
    final day = DaySchedule(
      windows: const [
        RecordingWindow(startMinute: 9 * 60, endMinute: 11 * 60),
        RecordingWindow(startMinute: 11 * 60, endMinute: 14 * 60),
      ],
    );

    expect(day.normalizedWindows(), [
      const RecordingWindow(startMinute: 9 * 60, endMinute: 14 * 60),
    ]);
  });

  test('active state and next transition follow local weekly windows', () {
    final schedule = RecordingSchedule(
      enabled: true,
      days: [
        DaySchedule(
          windows: const [
            RecordingWindow(startMinute: 9 * 60, endMinute: 17 * 60),
          ],
        ),
        ...List.generate(6, (_) => DaySchedule.empty),
      ],
    );

    final mondayMorning = DateTime(2026, 6, 15, 10);
    final mondayEvening = DateTime(2026, 6, 15, 18);

    expect(schedule.isActiveAt(mondayMorning), isTrue);
    expect(
      schedule.nextTransitionAfter(mondayMorning)?.at,
      DateTime(2026, 6, 15, 17),
    );
    expect(
      schedule.nextTransitionAfter(mondayMorning)?.startsRecording,
      isFalse,
    );
    expect(schedule.isActiveAt(mondayEvening), isFalse);
    expect(
      schedule.nextTransitionAfter(mondayEvening)?.at,
      DateTime(2026, 6, 22, 9),
    );
    expect(
      schedule.nextTransitionAfter(mondayEvening)?.startsRecording,
      isTrue,
    );
  });
}
