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
}

/// No-op platform used on desktop and in tests.
class NoopSchedulePlatform implements SchedulePlatform {
  const NoopSchedulePlatform();

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> register(List<ScheduleTransition> transitions) async {}
}

/// Drives start/stop of recording from a [RecordingSchedule].
///
/// Two tiers of enforcement:
///  1. An in-app [Timer] armed to the next transition, so while the app's main
///     isolate is alive (including backgrounded under the foreground service)
///     the schedule is honored to the minute via [onTransition].
///  2. OS-level events registered through [SchedulePlatform], which wake the app
///     at a barrier when it isn't running; the controller then reconciles actual
///     capture against [RecordingSchedule.isActiveAt].
class RecordingScheduler {
  RecordingScheduler({
    DiagnosticLog? diagnostics,
    SchedulePlatform? platform,
    DateTime Function()? now,
  })  : _diagnostics = diagnostics,
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

  /// Whether recording should be active right now per the (last synced) schedule.
  bool isActiveNow(RecordingSchedule schedule) => schedule.isActiveAt(_now());

  /// Re-evaluate [schedule]: (re)register OS events and (re)arm the in-app timer.
  /// Cancels everything when the schedule is disabled.
  Future<void> sync(RecordingSchedule schedule) async {
    _schedule = schedule;
    _timer?.cancel();
    _timer = null;
    if (!schedule.enabled) {
      _diagnostics?.add('Recording schedule disabled; clearing OS events.');
      await _platform.cancelAll();
      return;
    }
    final from = _now();
    final transitions = schedule.upcomingTransitions(from);
    _diagnostics?.add(
      'Recording schedule sync: ${transitions.length} upcoming transition(s).',
    );
    try {
      await _platform.register(transitions);
    } catch (error) {
      _diagnostics?.add('Schedule OS registration failed: $error');
    }
    _armTimer(schedule, from);
  }

  void _armTimer(RecordingSchedule schedule, DateTime from) {
    // Cancel any timer armed by a concurrent sync() so exactly one is live —
    // otherwise an orphaned timer would fire a duplicate transition.
    _timer?.cancel();
    _timer = null;
    final next = schedule.nextTransitionAfter(from);
    if (next == null) {
      return;
    }
    var wait = next.at.difference(from);
    if (wait.isNegative) {
      wait = Duration.zero;
    }
    _timer = Timer(wait, () {
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
    _timer?.cancel();
    _timer = null;
  }
}
