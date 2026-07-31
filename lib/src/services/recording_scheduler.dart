// Timer logic that reconciles capture at schedule-window boundaries, plus the SchedulePlatform seam for OS wake-ups.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/recording_schedule.dart';
import 'diagnostic_log.dart';

/// OS-level registration of schedule transitions. Implementations register
/// alarms/reminders so a user can see a window boundary even when the app is not
/// foregrounded. Abstracted so the timer logic can be tested without plugins.
abstract class SchedulePlatform {
  /// Register OS events for [transitions] (already chronological). Replaces any
  /// previously registered events.
  Future<void> register(List<ScheduleTransition> transitions);

  /// Cancel every previously registered OS event.
  Future<void> cancelAll();

  /// Return and clear the last OS barrier command, when a background callback
  /// recorded one for the main isolate to reconcile.
  Future<bool?> drainPendingShouldRecord();
}

/// No-op platform used on desktop and in tests.
class NoopSchedulePlatform implements SchedulePlatform {
  const NoopSchedulePlatform();

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool?> drainPendingShouldRecord() async => null;

  @override
  Future<void> register(List<ScheduleTransition> transitions) async {}
}

bool _appIsForeground() {
  final state = WidgetsBinding.instance.lifecycleState;
  return state == null || state == AppLifecycleState.resumed;
}

/// Drives start/stop reconciliation from a [RecordingSchedule].
///
/// Two tiers of enforcement:
///  1. An in-app [Timer] reaches the next transition. Stop transitions always
///     reconcile. Start transitions reconcile automatically only while the app
///     is foregrounded; a background start is deferred to a user-visible local
///     notification and subsequent foreground resume.
///  2. OS-level events registered through [SchedulePlatform] persist the desired
///     barrier state and display reminders without starting microphone capture.
class RecordingScheduler {
  RecordingScheduler({
    DiagnosticLog? diagnostics,
    SchedulePlatform? platform,
    DateTime Function()? now,
    bool Function()? canStartFromTimer,
    bool observeAppLifecycle = true,
  }) : _diagnostics = diagnostics,
       _platform = platform ?? const NoopSchedulePlatform(),
       _now = now ?? DateTime.now,
       _canStartFromTimer = canStartFromTimer ?? _appIsForeground {
    if (observeAppLifecycle) {
      _lifecycleListener = AppLifecycleListener(
        onResume: reconcileAfterForegroundResume,
      );
    }
  }

  final DiagnosticLog? _diagnostics;
  final SchedulePlatform _platform;
  final DateTime Function() _now;
  final bool Function() _canStartFromTimer;

  /// Called when capture should reconcile against the current schedule:
  /// `true` = should be recording now, `false` = should stop. The controller
  /// preserves manually owned sessions when applying the result.
  void Function(bool shouldRecord)? onTransition;

  Timer? _timer;
  RecordingSchedule? _schedule;
  AppLifecycleListener? _lifecycleListener;
  Future<void> _platformTail = Future<void>.value();
  int _revision = 0;
  bool _disposed = false;

  /// Whether recording should be active right now per the (last synced) schedule.
  bool isActiveNow(RecordingSchedule schedule) => schedule.isActiveAt(_now());

  /// Re-evaluate [schedule]: (re)register OS events and (re)arm the in-app timer.
  /// Cancels everything when the schedule is disabled.
  Future<void> sync(RecordingSchedule schedule) async {
    if (_disposed) {
      return;
    }
    final revision = ++_revision;
    _schedule = schedule;
    _timer?.cancel();
    _timer = null;
    if (!schedule.enabled) {
      _diagnostics?.add('Recording schedule disabled; clearing OS events.');
      await _enqueuePlatformMutation(revision, _platform.cancelAll);
      return;
    }
    final from = _now();
    final transitions = schedule.upcomingTransitions(from);
    _diagnostics?.add(
      'Recording schedule sync: ${transitions.length} upcoming transition(s).',
    );
    // The precise in-app timer must not wait on plugin readiness. Revision
    // checks below make this safe: a newer sync cancels this timer immediately,
    // while OS mutations are serialized independently.
    _armTimer(schedule, from, revision);
    await _enqueuePlatformMutation(
      revision,
      () => _platform.register(transitions),
    );
  }

  Future<bool?> drainPendingShouldRecord() =>
      _platform.drainPendingShouldRecord();

  /// Reconcile the authoritative wall-clock state when Flutter reports that the
  /// app is visible again. This is the foreground half of the schedule-start
  /// contract: a background timer/alarm can notify, but cannot open the mic.
  void reconcileAfterForegroundResume() {
    if (_disposed) {
      return;
    }
    final schedule = _schedule;
    if (schedule == null || !schedule.enabled) {
      return;
    }
    final shouldRecord = schedule.isActiveAt(_now());
    _diagnostics?.add(
      'App resumed; reconciling schedule to '
      '${shouldRecord ? "recording" : "idle"}.',
    );
    onTransition?.call(shouldRecord);
  }

  Future<void> _enqueuePlatformMutation(
    int revision,
    Future<void> Function() mutation,
  ) {
    final previous = _platformTail;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // Keep the queue usable if an older platform implementation escaped an
        // error despite the catch below.
      }
      if (_disposed || revision != _revision) {
        return;
      }
      try {
        await mutation();
      } catch (error) {
        _diagnostics?.add('Schedule OS synchronization failed: $error');
      }
    }();
    _platformTail = next;
    return next;
  }

  void _armTimer(RecordingSchedule schedule, DateTime from, int revision) {
    // Cancel any timer armed by a concurrent sync() so exactly one is live —
    // otherwise an orphaned timer would fire a duplicate transition.
    _timer?.cancel();
    _timer = null;
    if (_disposed || revision != _revision) {
      return;
    }
    final next = schedule.nextTransitionAfter(from);
    if (next == null) {
      return;
    }
    var wait = next.at.difference(from);
    if (wait.isNegative) {
      wait = Duration.zero;
    }
    _timer = Timer(wait, () {
      if (_disposed || revision != _revision) {
        return;
      }
      final action = next.startsRecording ? 'start' : 'stop';
      if (next.startsRecording && !_canStartFromTimer()) {
        _diagnostics?.add(
          'Schedule timer reached a start boundary while the app was not '
          'foregrounded; microphone start deferred to notification tap/resume.',
        );
      } else {
        _diagnostics?.add('Schedule timer fired: $action recording.');
        onTransition?.call(next.startsRecording);
      }
      // Re-arm against the now-current schedule for the following barrier.
      final current = _schedule;
      if (current != null && current.enabled) {
        unawaited(sync(current));
      }
    });
  }

  void dispose() {
    _disposed = true;
    _revision += 1;
    _schedule = null;
    _timer?.cancel();
    _timer = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
  }
}
