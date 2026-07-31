import 'dart:async';

import 'package:audio_dashcam/src/models/recording_schedule.dart';
import 'package:audio_dashcam/src/services/recording_scheduler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingPlatform implements SchedulePlatform {
  final List<List<ScheduleTransition>> registered = [];
  int cancelCount = 0;
  bool? pendingShouldRecord;
  Completer<void>? registerBlock;
  bool failNextCancellation = false;

  @override
  Future<void> register(List<ScheduleTransition> transitions) async {
    registered.add(transitions);
    final block = registerBlock;
    if (block != null) {
      await block.future;
    }
  }

  @override
  Future<void> cancelAll() async {
    cancelCount++;
    if (failNextCancellation) {
      failNextCancellation = false;
      throw StateError('simulated cancellation failure');
    }
  }

  @override
  Future<bool?> drainPendingShouldRecord() async {
    final pending = pendingShouldRecord;
    pendingShouldRecord = null;
    return pending;
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
        canStartFromTimer: () => true,
        observeAppLifecycle: false,
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
        canStartFromTimer: () => true,
        observeAppLifecycle: false,
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
      clock = DateTime(2026, 6, 15, 9, 0);
      async.elapse(const Duration(hours: 1));
      async.flushMicrotasks();
      expect(fired, [true]);

      scheduler.dispose();
    });
  });

  test(
    'background start is deferred until foreground resume but stop still fires',
    () {
      fakeAsync((async) {
        final start = DateTime(2026, 6, 15, 8); // Monday
        final platform = _RecordingPlatform();
        final fired = <bool>[];
        final scheduler = RecordingScheduler(
          platform: platform,
          now: () => start.add(async.elapsed),
          canStartFromTimer: () => false,
          observeAppLifecycle: false,
        )..onTransition = fired.add;
        final schedule = RecordingSchedule(
          enabled: true,
          days: [
            DaySchedule(windows: [w(9 * 60, 10 * 60)]),
            ...List.generate(6, (_) => DaySchedule.empty),
          ],
        );

        scheduler.sync(schedule);
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        async.flushMicrotasks();
        expect(
          fired,
          isEmpty,
          reason: 'a background timer must not initiate microphone capture',
        );

        // This method is called by AppLifecycleListener only on a real resume.
        scheduler.reconcileAfterForegroundResume();
        expect(fired, [true]);

        async.elapse(const Duration(hours: 1));
        async.flushMicrotasks();
        expect(
          fired,
          [true, false],
          reason: 'schedule-owned capture still stops at the closing barrier',
        );
        scheduler.dispose();
      });
    },
  );

  test('drains pending OS schedule command through the platform', () async {
    final platform = _RecordingPlatform()..pendingShouldRecord = true;
    final scheduler = RecordingScheduler(
      platform: platform,
      canStartFromTimer: () => true,
      observeAppLifecycle: false,
    );

    expect(await scheduler.drainPendingShouldRecord(), isTrue);
    expect(await scheduler.drainPendingShouldRecord(), isNull);
    scheduler.dispose();
  });

  test('a newer sync wins while an older platform registration is pending', () {
    fakeAsync((async) {
      final start = DateTime(2026, 6, 15, 8); // Monday
      final platform = _RecordingPlatform()..registerBlock = Completer<void>();
      final fired = <bool>[];
      final scheduler = RecordingScheduler(
        platform: platform,
        now: () => start.add(async.elapsed),
        canStartFromTimer: () => true,
        observeAppLifecycle: false,
      )..onTransition = fired.add;
      final first = RecordingSchedule(
        enabled: true,
        days: [
          DaySchedule(windows: [w(9 * 60, 10 * 60)]),
          ...List.generate(6, (_) => DaySchedule.empty),
        ],
      );
      final latest = RecordingSchedule(
        enabled: true,
        days: [
          DaySchedule(windows: [w(11 * 60, 12 * 60)]),
          ...List.generate(6, (_) => DaySchedule.empty),
        ],
      );

      scheduler.sync(first);
      async.flushMicrotasks();
      expect(platform.registered, hasLength(1));

      scheduler.sync(latest);
      async.flushMicrotasks();
      expect(platform.registered, hasLength(1));

      async.elapse(const Duration(hours: 1));
      expect(fired, isEmpty, reason: 'the stale 9am timer must not survive');
      async.elapse(const Duration(hours: 2));
      expect(
        fired,
        [true],
        reason: 'the latest in-app timer must not wait on native registration',
      );

      platform.registerBlock!.complete();
      async.flushMicrotasks();
      expect(platform.registered, hasLength(2));

      scheduler.dispose();
    });
  });

  test(
    'a cancellation failure does not poison a later schedule sync',
    () async {
      final platform = _RecordingPlatform()..failNextCancellation = true;
      final scheduler = RecordingScheduler(
        platform: platform,
        canStartFromTimer: () => true,
        observeAppLifecycle: false,
      );

      await scheduler.sync(RecordingSchedule.defaultSchedule());
      final enabled = RecordingSchedule(
        enabled: true,
        days: [
          DaySchedule(windows: [w(9 * 60, 10 * 60)]),
          ...List.generate(6, (_) => DaySchedule.empty),
        ],
      );
      await scheduler.sync(enabled);

      expect(platform.cancelCount, 1);
      expect(platform.registered, hasLength(1));
      scheduler.dispose();
    },
  );
}
