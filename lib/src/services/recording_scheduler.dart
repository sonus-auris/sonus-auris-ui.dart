// Pure-Dart timer logic that arms/disarms capture at schedule-window boundaries, plus the SchedulePlatform seam for OS wake-ups.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../models/recording_schedule.dart';
import 'diagnostic_log.dart';

/// OS-level registration of schedule transitions. Implementations register
/// exact alarms (Android) / local notifications (iOS) so the device wakes the
/// app at a window barrier even when it isn't foregrounded. Abstracted so the
/// pure-Dart [RecordingScheduler] timer logic can be unit-tested without the
/// platform plugins.
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

/// Drives start/stop of recording from a [RecordingSchedule].
///
/// Two tiers of enforcement:
///  1. An in-app [Timer] armed to the next transition, so while the app's main
///     isolate is alive (including backgrounded under the foreground service)
///     the schedule is honored to the minute via [onTransition].
///  2. OS-level events registered through [SchedulePlatform], which persist the
///     intended barrier state so the controller can reconcile actual capture
///     against [RecordingSchedule.isActiveAt]. On Android, mic capture still
///     depends on a user-visible foreground service because microphone access is
///     a while-in-use permission.
class RecordingScheduler {
  RecordingScheduler({
    DiagnosticLog? diagnostics,
    SchedulePlatform? platform,
    DateTime Function()? now,
  }) : _diagnostics = diagnostics,
       _platform = platform ?? const NoopSchedulePlatform(),
       _now = now ?? DateTime.now;

  final DiagnosticLog? _diagnostics;
  final SchedulePlatform _platform;
  final DateTime Function() _now;

  /// Called when the in-app timer reaches a transition: `true` = should be
  /// recording now, `false` = should stop. The controller reconciles actual
  /// capture (respecting manual sessions) against this.
  void Function(bool shouldRecord)? onTransition;

  Timer? _timer;
  RecordingSchedule? _schedule;
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
      _diagnostics?.add(
        'Schedule timer fired: ${next.startsRecording ? "start" : "stop"} '
        'recording.',
      );
      onTransition?.call(next.startsRecording);
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
  }
}
