// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/recording_schedule.dart';
import 'background_capture_service.dart';
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

/// Real [SchedulePlatform] backed by exact OS alarms on Android and local
/// notifications on iOS (the latter via the shared [LocalNotificationsService]).
/// A no-op on desktop, where the in-app timer covers scheduling.
class PluginSchedulePlatform implements SchedulePlatform {
  PluginSchedulePlatform({
    required LocalNotificationsService notifications,
    DiagnosticLog? diagnostics,
  })  : _notifications = notifications,
        _diagnostics = diagnostics;

  final LocalNotificationsService _notifications;
  final DiagnosticLog? _diagnostics;

  @override
  Future<void> register(List<ScheduleTransition> transitions) async {
    if (Platform.isAndroid) {
      await _registerAndroid(transitions);
    } else if (Platform.isIOS) {
      await _notifications.scheduleTransitions(transitions);
    }
  }

  @override
  Future<void> cancelAll() async {
    if (Platform.isAndroid) {
      await _cancelAndroid();
    } else if (Platform.isIOS) {
      await _notifications.cancelScheduled();
    }
  }

  // --- Android: exact alarms + background isolate ---------------------------

  Future<void> _registerAndroid(List<ScheduleTransition> transitions) async {
    await _cancelAndroid();
    final capped = transitions.take(_maxAlarms).toList();
    final actions = <String, bool>{};
    for (var i = 0; i < capped.length; i++) {
      final id = _alarmBaseId + i;
      actions['$id'] = capped[i].startsRecording;
      final ok = await AndroidAlarmManager.oneShotAt(
        capped[i].at,
        id,
        scheduleAlarmFired,
        exact: true,
        wakeup: true,
        allowWhileIdle: true,
        rescheduleOnReboot: true,
      );
      if (!ok) {
        _diagnostics?.add('Failed to register exact alarm $id.');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAlarmActionsKey, jsonEncode(actions));
    _diagnostics?.add('Registered ${capped.length} exact alarm(s).');
  }

  Future<void> _cancelAndroid() async {
    for (var i = 0; i < _maxAlarms; i++) {
      await AndroidAlarmManager.cancel(_alarmBaseId + i);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAlarmActionsKey);
  }
}

/// Background-isolate callback fired by an exact alarm. Runs without the app's
/// main isolate, so it can only: record the commanded state for the main isolate
/// to reconcile, and toggle the foreground service (which keeps the process up
/// so the rolling-window recorder in the main isolate can run). When the app is
/// fully killed, actual mic capture resumes once the main isolate is next alive.
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
  final service = BackgroundCaptureService();
  service.init();
  if (shouldRecord) {
    await service.start();
  } else {
    await service.stop();
  }
}
