import 'package:audio_dashcam/src/models/recording_schedule.dart';
import 'package:audio_dashcam/src/services/recording_scheduler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingPlatform implements SchedulePlatform {
  final List<List<ScheduleTransition>> registered = [];
  int cancelCount = 0;

  @override
  Future<void> register(List<ScheduleTransition> transitions) async {
    registered.add(transitions);
  }

  @override
  Future<void> cancelAll() async {
    cancelCount++;
  }
}

RecordingWindow w(int start, int end) =>
    RecordingWindow(startMinute: start, endMinute: end);

void main() {
  test('disabled schedule cancels OS events and arms no timer', () {
    fakeAsync((async) {
      final platform = _RecordingPlatform();
      final scheduler = RecordingScheduler(
        platform: platform,
        now: () => DateTime(2026, 6, 15, 8, 0),
      );
      scheduler.sync(RecordingSchedule.defaultSchedule());
      async.flushMicrotasks();
      expect(platform.cancelCount, 1);
      expect(platform.registered, isEmpty);
      scheduler.dispose();
    });
  });

  test('registers OS transitions and fires the in-app timer at the barrier', () {
    fakeAsync((async) {
      var clock = DateTime(2026, 6, 15, 8, 0); // Monday, before the 9am window
      final platform = _RecordingPlatform();
      final fired = <bool>[];
      final scheduler = RecordingScheduler(
        platform: platform,
        now: () => clock,
      );
      scheduler.onTransition = fired.add;

      final schedule = RecordingSchedule(
        enabled: true,
        days: [
          DaySchedule(windows: [w(9 * 60, 17 * 60)]),
          ...List.generate(6, (_) => DaySchedule.empty),
        ],
      );
      scheduler.sync(schedule);
      async.flushMicrotasks();

      expect(platform.registered.single.first.startsRecording, isTrue);

      // Advance to 9:00 — the start barrier should fire a "should record" event.
      async.elapse(const Duration(hours: 1));
      clock = DateTime(2026, 6, 15, 9, 0);
      async.flushMicrotasks();
      expect(fired, [true]);

      scheduler.dispose();
    });
  });
}
