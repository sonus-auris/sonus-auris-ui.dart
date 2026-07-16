// SchedulePlatform implementation registering Android exact alarms / iOS local notifications for schedule-window transitions.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/recording_schedule.dart';
import 'alarm_manager_initialization.dart';
import 'diagnostic_log.dart';
import 'local_notifications_service.dart';
import 'recording_scheduler.dart';

/// Base id for the exact alarms this app registers. Each transition gets
/// `_alarmBaseId + index`; we register at most [_maxAlarms] at a time.
const int _alarmBaseId = 770000;
const int _maxAlarms = 64;

/// SharedPreferences key holding the alarm-id → "should record" map, read by the
/// background isolate when an alarm fires.
const String _kAlarmActionsKey = 'schedule_alarm_actions';

/// SharedPreferences key the alarm callback writes so the main isolate, when it
/// next runs, knows what state the schedule last commanded and reconciles.
const String kSchedulePendingShouldRecordKey = 'schedule_pending_should_record';

enum ScheduleHostPlatform { android, ios, other }

ScheduleHostPlatform _currentHostPlatform() {
  if (Platform.isAndroid) {
    return ScheduleHostPlatform.android;
  }
  if (Platform.isIOS) {
    return ScheduleHostPlatform.ios;
  }
  return ScheduleHostPlatform.other;
}

/// Narrow seam around the static plugin API so readiness and operation ordering
/// can be verified without starting an Android service in a host-side test.
abstract interface class AndroidScheduleAlarmClient {
  Future<bool> initialize();

  Future<bool> cancel(int id);

  Future<bool> schedule(DateTime at, int id);
}

class PluginAndroidScheduleAlarmClient implements AndroidScheduleAlarmClient {
  const PluginAndroidScheduleAlarmClient();

  @override
  Future<bool> initialize() => AndroidAlarmManager.initialize();

  @override
  Future<bool> cancel(int id) => AndroidAlarmManager.cancel(id);

  @override
  Future<bool> schedule(DateTime at, int id) => AndroidAlarmManager.oneShotAt(
    at,
    id,
    scheduleAlarmFired,
    exact: true,
    wakeup: true,
    allowWhileIdle: true,
    rescheduleOnReboot: true,
  );
}

/// Real [SchedulePlatform] backed by exact OS alarms on Android and local
/// notifications on iOS (the latter via the shared [LocalNotificationsService]).
/// A no-op on desktop, where the in-app timer covers scheduling.
class PluginSchedulePlatform implements SchedulePlatform {
  PluginSchedulePlatform({
    required LocalNotificationsService notifications,
    DiagnosticLog? diagnostics,
    AndroidScheduleAlarmClient? androidAlarmClient,
    ScheduleHostPlatform? hostPlatform,
    Duration alarmInitializationTimeout = const Duration(seconds: 3),
  }) : _notifications = notifications,
       _diagnostics = diagnostics,
       _hostPlatform = hostPlatform ?? _currentHostPlatform() {
    final client =
        androidAlarmClient ?? const PluginAndroidScheduleAlarmClient();
    _androidAlarmClient = client;
    _androidAlarmInitialization = AlarmManagerInitializationGate(
      initializer: client.initialize,
      waitTimeout: alarmInitializationTimeout,
    );
  }

  final LocalNotificationsService _notifications;
  final DiagnosticLog? _diagnostics;
  final ScheduleHostPlatform _hostPlatform;
  late final AndroidScheduleAlarmClient _androidAlarmClient;
  late final AlarmManagerInitializationGate _androidAlarmInitialization;

  int _androidOperationRevision = 0;
  Future<void> _androidOperationTail = Future<void>.value();

  @override
  Future<void> register(List<ScheduleTransition> transitions) async {
    switch (_hostPlatform) {
      case ScheduleHostPlatform.android:
        final revision = ++_androidOperationRevision;
        final snapshot = List<ScheduleTransition>.unmodifiable(transitions);
        await _runAndroidWhenReady(
          revision: revision,
          operationName: 'registration',
          operation: () => _registerAndroid(snapshot),
        );
        return;
      case ScheduleHostPlatform.ios:
        await _notifications.scheduleTransitions(transitions);
        return;
      case ScheduleHostPlatform.other:
        return;
    }
  }

  @override
  Future<void> cancelAll() async {
    switch (_hostPlatform) {
      case ScheduleHostPlatform.android:
        final revision = ++_androidOperationRevision;
        // Make any already-delivered stale callback harmless immediately, even
        // if the native alarm service is still lagging after a reboot.
        await _clearAndroidActions();
        await _runAndroidWhenReady(
          revision: revision,
          operationName: 'cancellation',
          operation: _cancelAndroid,
        );
        return;
      case ScheduleHostPlatform.ios:
        await _notifications.cancelScheduled();
        return;
      case ScheduleHostPlatform.other:
        return;
    }
  }

  @override
  Future<bool?> drainPendingShouldRecord() async {
    if (_hostPlatform != ScheduleHostPlatform.android) {
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final pending = prefs.getBool(kSchedulePendingShouldRecordKey);
    if (pending != null) {
      await prefs.remove(kSchedulePendingShouldRecordKey);
    }
    return pending;
  }

  // --- Android: exact alarms + background isolate ---------------------------

  Future<void> _runAndroidWhenReady({
    required int revision,
    required String operationName,
    required Future<void> Function() operation,
  }) async {
    final ready = await _androidAlarmInitialization.ensureInitialized();
    if (ready) {
      await _enqueueAndroidOperation(revision, operation);
      return;
    }
    _diagnostics?.add(
      'Android alarm-manager $operationName deferred; native initialization '
      'was not ready after a bounded '
      '${_androidAlarmInitialization.waitTimeout.inSeconds}s wait.',
    );
    final pending = _androidAlarmInitialization.currentAttemptOrReady;
    if (pending != null) {
      unawaited(
        _recoverAndroidOperation(
          pending: pending,
          revision: revision,
          operationName: operationName,
          operation: operation,
        ),
      );
    }
  }

  Future<void> _recoverAndroidOperation({
    required Future<bool> pending,
    required int revision,
    required String operationName,
    required Future<void> Function() operation,
  }) async {
    try {
      final ready = await pending;
      if (!ready || revision != _androidOperationRevision) {
        return;
      }
      _diagnostics?.add(
        'Android alarm manager recovered; applying deferred $operationName.',
      );
      await _enqueueAndroidOperation(revision, operation);
    } catch (error) {
      _diagnostics?.add(
        'Deferred Android alarm-manager $operationName failed: $error',
      );
    }
  }

  Future<void> _enqueueAndroidOperation(
    int revision,
    Future<void> Function() operation,
  ) {
    final previous = _androidOperationTail;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // A failed older mutation must not poison the latest desired state.
      }
      if (revision != _androidOperationRevision) {
        return;
      }
      await operation();
    }();
    _androidOperationTail = next;
    return next;
  }

  Future<void> _registerAndroid(List<ScheduleTransition> transitions) async {
    await _cancelAndroid();
    final capped = transitions.take(_maxAlarms).toList();
    final actions = <String, bool>{};
    final prefs = await SharedPreferences.getInstance();
    for (var i = 0; i < capped.length; i++) {
      final id = _alarmBaseId + i;
      actions['$id'] = capped[i].startsRecording;
    }
    await prefs.setString(_kAlarmActionsKey, jsonEncode(actions));
    for (var i = 0; i < capped.length; i++) {
      final id = _alarmBaseId + i;
      final ok = await _androidAlarmClient.schedule(capped[i].at, id);
      if (!ok) {
        _diagnostics?.add('Failed to register exact alarm $id.');
      }
    }
    _diagnostics?.add('Registered ${capped.length} exact alarm(s).');
  }

  Future<void> _cancelAndroid() async {
    for (var i = 0; i < _maxAlarms; i++) {
      await _androidAlarmClient.cancel(_alarmBaseId + i);
    }
    await _clearAndroidActions();
  }

  Future<void> _clearAndroidActions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAlarmActionsKey);
  }
}

/// Background-isolate callback fired by an exact alarm. It runs in a separate
/// isolate that can NOT drive the main-isolate recorder, so it deliberately does
/// not touch capture or the foreground service: doing so could stop a *manual*
/// recording (bypassing the ownership guard) or try to create microphone capture
/// from Android background state, which modern Android blocks for while-in-use
/// permissions. Instead it only records the commanded state; the main isolate
/// reconciles against the schedule (the authoritative `isActiveAt`) whenever it
/// is next alive. Reliable Android scheduled capture depends on the user-visible
/// schedule/recording foreground service staying alive after the user arms it.
@pragma('vm:entry-point')
Future<void> scheduleAlarmFired(int id) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final raw = prefs.getString(_kAlarmActionsKey);
  if (raw == null) {
    return;
  }
  final actions = (jsonDecode(raw) as Map).cast<String, dynamic>();
  final shouldRecord = actions['$id'] as bool?;
  if (shouldRecord == null) {
    return;
  }
  await prefs.setBool(kSchedulePendingShouldRecordKey, shouldRecord);
}
