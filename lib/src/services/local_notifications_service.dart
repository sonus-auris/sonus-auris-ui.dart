// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/context_trigger.dart';
import '../models/recording_schedule.dart';
import 'diagnostic_log.dart';

/// Single owner of [FlutterLocalNotificationsPlugin] so there is exactly one
/// `initialize` (and therefore one tap-response handler) across the app. Both
/// the recording-schedule iOS reminders and the context-trigger consent prompts
/// flow through here.
class LocalNotificationsService {
  LocalNotificationsService({
    DiagnosticLog? diagnostics,
    FlutterLocalNotificationsPlugin? plugin,
  }) : _diagnostics = diagnostics,
       _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final DiagnosticLog? _diagnostics;
  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  /// Invoked (main isolate) when the user taps a "consent" notification while
  /// the app is alive. Set by the controller to start recording.
  void Function()? onConsentTap;

  /// Payload tag identifying the context-trigger consent prompt.
  static const String consentPayload = 'context-consent';
  static const String scheduleStartPayload = 'schedule-start';
  static const String scheduleStopPayload = 'schedule-stop';
  static const String sleepAlarmPayload = 'sleep-alarm';

  // Notification id partitions.
  static const int _scheduleStartBase = 780000;
  static const int _scheduleStopBase = 790000;
  static const int _scheduleSpan = 64;
  static const int _consentId = 800000;
  static const int _sleepAlarmId = 810000;
  static const int _sleepBackstopId = 810001;

  /// Invoked (main isolate) when the user taps a sleep alarm while the app is
  /// alive. Set by the controller to stop the sleep session.
  void Function()? onSleepAlarmTap;

  /// iOS allows at most 64 *pending* local notifications per app. Cap the total
  /// scheduled (start + stop) below that, leaving headroom for the consent
  /// prompt and any other notification, so iOS never silently drops the soonest
  /// reminders. The schedule re-syncs whenever the app is alive, topping this up.
  static const int _maxScheduledNotifications = 56;

  Future<void> ensureInitialized() async {
    if (_ready) {
      return;
    }
    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(DateTime.now().timeZoneName));
    } catch (_) {
      // Best-effort; zonedSchedule still fires close to the wall-clock time.
    }
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onResponse,
    );
    _ready = true;
  }

  void _onResponse(NotificationResponse response) {
    if (response.payload == consentPayload ||
        response.payload == scheduleStartPayload) {
      onConsentTap?.call();
    } else if (response.payload == sleepAlarmPayload) {
      onSleepAlarmTap?.call();
    }
  }

  /// True when the app was launched by tapping a recording-consent notification
  /// (cold start). The controller checks this on init to honor the tap.
  Future<bool> launchedFromConsent() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp ?? false) {
      final payload = details!.notificationResponse?.payload;
      return payload == consentPayload || payload == scheduleStartPayload;
    }
    return false;
  }

  Future<bool> requestPermission() async {
    await ensureInitialized();
    if (Platform.isIOS) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: false, sound: true);
      return granted ?? false;
    }
    if (Platform.isAndroid) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'sonus_auris_schedule',
      'Scheduled recording',
      channelDescription:
          'Reminders and consent prompts for scheduled recording.',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    ),
  );

  /// Schedule iOS reminders for window barriers. If the app is already alive,
  /// the in-app scheduler starts/stops capture directly; these reminders help
  /// the user notice a window and can relaunch the app if it was not live.
  Future<void> scheduleTransitions(List<ScheduleTransition> transitions) async {
    await ensureInitialized();
    await cancelScheduled();
    var startIdx = 0;
    var stopIdx = 0;
    final nowLocal = tz.TZDateTime.now(tz.local);
    for (final t in transitions) {
      // Stay under the iOS pending-notification ceiling. Transitions are
      // chronological, so this keeps the soonest reminders.
      if (startIdx + stopIdx >= _maxScheduledNotifications) {
        break;
      }
      final when = tz.TZDateTime.from(t.at, tz.local);
      if (when.isBefore(nowLocal)) {
        continue;
      }
      if (t.startsRecording && startIdx < _scheduleSpan) {
        await _plugin.zonedSchedule(
          _scheduleStartBase + startIdx++,
          'Scheduled recording is starting',
          'Open Sonus Auris to confirm capture is active.',
          when,
          _details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: scheduleStartPayload,
        );
      } else if (!t.startsRecording && stopIdx < _scheduleSpan) {
        await _plugin.zonedSchedule(
          _scheduleStopBase + stopIdx++,
          'Scheduled recording ended',
          'Your scheduled recording window has finished.',
          when,
          _details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: scheduleStopPayload,
        );
      }
    }
    _diagnostics?.add('Scheduled $startIdx start + $stopIdx stop reminder(s).');
  }

  Future<void> cancelScheduled() async {
    await ensureInitialized();
    for (var i = 0; i < _scheduleSpan; i++) {
      await _plugin.cancel(_scheduleStartBase + i);
      await _plugin.cancel(_scheduleStopBase + i);
    }
  }

  /// Immediate "an event happened during your window — tap to record" prompt,
  /// shown when the app isn't foregrounded. The body uses the generic trigger
  /// category — never the specific SSID / device name — so nothing sensitive
  /// lands on the lock screen; the in-app banner shows the detail.
  Future<void> showConsentPrompt(ContextTriggerEvent event) async {
    await ensureInitialized();
    await _plugin.show(
      _consentId,
      'Start recording?',
      'A ${event.kind.label.toLowerCase()} happened during your recording '
          'window. Tap to record.',
      _details,
      payload: consentPayload,
    );
  }

  Future<void> clearConsentPrompt() async {
    await ensureInitialized();
    await _plugin.cancel(_consentId);
  }

  /// Alarm-grade notification details: loud, high-priority, time-sensitive so it
  /// can rouse a sleeper. Uses a dedicated channel/sound from the schedule one.
  static const NotificationDetails _sleepDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'sonus_auris_sleep_alarm',
      'Sleep alarm',
      channelDescription: 'Cycle-aware wake-up alarms during a sleep session.',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    ),
  );

  /// Fire the cycle-aware wake alarm **now** (the dynamic smart wake — the engine
  /// decided this is a light-sleep moment, or the backstop deadline was hit).
  Future<void> fireSleepAlarm({required bool backstop}) async {
    await ensureInitialized();
    await _plugin.show(
      backstop ? _sleepBackstopId : _sleepAlarmId,
      backstop ? 'Time to wake up' : 'Good morning',
      backstop
          ? 'You reached your latest wake time. Tap to stop the alarm.'
          : 'You\'re in light sleep near your wake window. Tap to stop the alarm.',
      _sleepDetails,
      payload: sleepAlarmPayload,
    );
  }

  /// Schedule the hard backstop wake at [whenUtc] as an OS-level alarm, so the
  /// sleeper is still woken by the backstop cycle even if the app was killed
  /// overnight. The dynamic smart wake is handled in-app via [fireSleepAlarm].
  Future<void> scheduleSleepBackstop(DateTime whenUtc) async {
    await ensureInitialized();
    final when = tz.TZDateTime.from(whenUtc.toLocal(), tz.local);
    if (when.isBefore(tz.TZDateTime.now(tz.local))) {
      return;
    }
    await _plugin.zonedSchedule(
      _sleepBackstopId,
      'Time to wake up',
      'You reached your latest wake time. Tap to stop the alarm.',
      when,
      _sleepDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: sleepAlarmPayload,
    );
    _diagnostics?.add('Scheduled sleep backstop alarm for $when.');
  }

  Future<void> cancelSleepAlarms() async {
    await ensureInitialized();
    await _plugin.cancel(_sleepAlarmId);
    await _plugin.cancel(_sleepBackstopId);
  }

  /// Cancel only the scheduled OS backstop (used once the smart wake has fired,
  /// so the 9 h backstop doesn't also go off later).
  Future<void> cancelSleepBackstop() async {
    await ensureInitialized();
    await _plugin.cancel(_sleepBackstopId);
  }
}
