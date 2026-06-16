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
        DaySchedule(windows: [
          const RecordingWindow(startMinute: 540, endMinute: 1020),
        ]),
        ...List.generate(5, (_) => DaySchedule.empty),
      ],
    );
    final config = const AppConfig(deviceId: 'd').copyWith(
      recordingSchedule: schedule,
    );
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
}
