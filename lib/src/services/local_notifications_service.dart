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
  })  : _diagnostics = diagnostics,
        _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final DiagnosticLog? _diagnostics;
  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  /// Invoked (main isolate) when the user taps a "consent" notification while
  /// the app is alive. Set by the controller to start recording.
  void Function()? onConsentTap;

  /// Payload tag identifying the context-trigger consent prompt.
  static const String consentPayload = 'context-consent';

  // Notification id partitions.
  static const int _scheduleStartBase = 780000;
  static const int _scheduleStopBase = 790000;
  static const int _scheduleSpan = 10000;
  static const int _consentId = 800000;

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
    if (response.payload == consentPayload) {
      onConsentTap?.call();
    }
  }

  /// True when the app was launched by tapping a consent notification (cold
  /// start). The controller checks this on init to honor the tap.
  Future<bool> launchedFromConsent() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp ?? false) {
      return details!.notificationResponse?.payload == consentPayload;
    }
    return false;
  }

  Future<bool> requestPermission() async {
    await ensureInitialized();
    if (Platform.isIOS) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: false, sound: true);
      return granted ?? false;
    }
    if (Platform.isAndroid) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
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

  /// Schedule iOS reminders for window barriers (the explicit-consent gate on
  /// iOS, where the app can't silently start the mic in the background).
  Future<void> scheduleTransitions(List<ScheduleTransition> transitions) async {
    await ensureInitialized();
    await cancelScheduled();
    var startIdx = 0;
    var stopIdx = 0;
    final nowLocal = tz.TZDateTime.now(tz.local);
    for (final t in transitions) {
      final when = tz.TZDateTime.from(t.at, tz.local);
      if (when.isBefore(nowLocal)) {
        continue;
      }
      if (t.startsRecording && startIdx < _scheduleSpan) {
        await _plugin.zonedSchedule(
          _scheduleStartBase + startIdx++,
          'Scheduled recording is starting',
          'Tap to begin recording your scheduled window.',
          when,
          _details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: 'schedule-start',
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
          payload: 'schedule-stop',
        );
      }
    }
    _diagnostics?.add(
      'Scheduled $startIdx start + $stopIdx stop reminder(s).',
    );
  }

  Future<void> cancelScheduled() async {
    await ensureInitialized();
    for (var i = 0; i < _scheduleSpan; i++) {
      await _plugin.cancel(_scheduleStartBase + i);
      await _plugin.cancel(_scheduleStopBase + i);
    }
  }

  /// Immediate "an event happened during your window — tap to record" prompt,
  /// used when the app isn't foregrounded to surface an in-app banner.
  Future<void> showConsentPrompt(ContextTriggerEvent event) async {
    await ensureInitialized();
    await _plugin.show(
      _consentId,
      'Start recording?',
      '${event.description} during your recording window. Tap to record.',
      _details,
      payload: consentPayload,
    );
  }

  Future<void> clearConsentPrompt() async {
    await ensureInitialized();
    await _plugin.cancel(_consentId);
  }
}
