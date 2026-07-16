// Configures and drives the Android foreground-service notification that keeps audio capture alive in the background.
// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'diagnostic_log.dart';

enum BackgroundCaptureMode {
  scheduleStandby,
  recording;

  String get notificationTitle {
    switch (this) {
      case BackgroundCaptureMode.scheduleStandby:
        return 'Sonus Auris schedule armed';
      case BackgroundCaptureMode.recording:
        return 'Sonus Auris is recording';
    }
  }

  String get notificationText {
    switch (this) {
      case BackgroundCaptureMode.scheduleStandby:
        return 'Waiting for your next declared recording window.';
      case BackgroundCaptureMode.recording:
        return 'Rolling local window and cloud upload are active.';
    }
  }
}

class BackgroundCaptureService {
  BackgroundCaptureService({DiagnosticLog? diagnostics})
    : _diagnostics = diagnostics;

  final DiagnosticLog? _diagnostics;

  void init() {
    if (!Platform.isAndroid) {
      _diagnostics?.add(
        'Foreground task initialization skipped: platform is not Android.',
      );
      return;
    }
    _diagnostics?.add('Initializing Android foreground task options.');
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'audio_dashcam_capture',
        channelName: 'Sonus Auris',
        channelDescription: 'Shows while audio capture is active.',
        onlyAlertOnce: true,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        allowWakeLock: true,
        allowWifiLock: false,
        // Android 14+ forbids starting a microphone-typed foreground service
        // from a boot/restart receiver (ForegroundServiceStartNotAllowedException),
        // and Play policy treats it as background mic access. After reboot the
        // alarm-manager receiver re-arms schedules instead, and capture resumes
        // from a user-visible trigger.
        allowAutoRestart: false,
        stopWithTask: false,
      ),
    );
  }

  Future<String?> start({
    BackgroundCaptureMode mode = BackgroundCaptureMode.recording,
  }) async {
    if (!Platform.isAndroid) {
      _diagnostics?.add('Foreground service skipped: platform is not Android.');
      return null;
    }
    try {
      _diagnostics?.add('Checking Android notification permission.');
      final notificationPermission =
          await FlutterForegroundTask.checkNotificationPermission();
      _diagnostics?.add('Notification permission: $notificationPermission.');
      if (notificationPermission != NotificationPermission.granted) {
        _diagnostics?.add('Requesting notification permission.');
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (await FlutterForegroundTask.isRunningService) {
        _diagnostics?.add(
          'Foreground service already running; updating ${mode.name} notice.',
        );
        final result = await FlutterForegroundTask.updateService(
          notificationTitle: mode.notificationTitle,
          notificationText: mode.notificationText,
          callback: audioDashcamForegroundCallback,
        );
        if (result is ServiceRequestFailure) {
          _diagnostics?.add(
            'Foreground service update failed: ${result.error}.',
          );
          return _friendlyStartError(result.error);
        }
        return null;
      }
      _diagnostics?.add(
        'Starting microphone foreground service (${mode.name}).',
      );
      final result = await FlutterForegroundTask.startService(
        serviceId: 500,
        serviceTypes: const [ForegroundServiceTypes.microphone],
        notificationTitle: mode.notificationTitle,
        notificationText: mode.notificationText,
        callback: audioDashcamForegroundCallback,
      );
      if (result is ServiceRequestFailure) {
        if (await FlutterForegroundTask.isRunningService) {
          _diagnostics?.add(
            'Foreground service reported failure but is running.',
          );
          return null;
        }
        _diagnostics?.add('Foreground service failed: ${result.error}.');
        return _friendlyStartError(result.error);
      }
      _diagnostics?.add('Foreground service started.');
      return null;
    } catch (error) {
      _diagnostics?.add('Foreground service threw: $error.');
      return _friendlyStartError(error);
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) {
      return;
    }
    if (await FlutterForegroundTask.isRunningService) {
      _diagnostics?.add('Stopping foreground service.');
      await FlutterForegroundTask.stopService();
    } else {
      _diagnostics?.add('Foreground service stop skipped: not running.');
    }
  }
}

String _friendlyStartError(Object error) {
  final text = error.toString();
  if (text.contains('ServiceTimeoutException')) {
    return 'Android foreground service timed out. Recording can run while the app stays open, but background recording is not protected yet.';
  }
  return 'Android foreground service failed: $text';
}

@pragma('vm:entry-point')
void audioDashcamForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(AudioDashcamForegroundTaskHandler());
}

class AudioDashcamForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    FlutterForegroundTask.sendDataToMain({
      'type': 'foreground-started',
      'timestamp': timestamp.toIso8601String(),
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.sendDataToMain({
      'type': 'foreground-heartbeat',
      'timestamp': timestamp.toIso8601String(),
    });
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    FlutterForegroundTask.sendDataToMain({
      'type': 'foreground-stopped',
      'timestamp': timestamp.toIso8601String(),
      'isTimeout': isTimeout,
    });
  }
}
