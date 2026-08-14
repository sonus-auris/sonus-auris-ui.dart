// Configures and drives the Android microphone foreground-service notification
// that keeps an already user-started recording alive in the background.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../platform/runtime_platform.dart';
import 'diagnostic_log.dart';

enum BackgroundCaptureMode {
  /// Compatibility mode used by the schedule orchestrator while it converges on
  /// the desired idle state. It is deliberately notification-only: an armed
  /// schedule must never keep a microphone-typed foreground service alive while
  /// the microphone is closed.
  scheduleStandby,
  recording;

  bool get startsMicrophoneService => this == BackgroundCaptureMode.recording;

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
        return 'A reminder will ask you to open the app at the next window.';
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
    if (!RuntimePlatform.isAndroid) {
      _diagnostics?.add(
        'Foreground task initialization skipped: platform is not Android.',
      );
      return;
    }
    _diagnostics?.add('Initializing Android foreground task options.');
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'audio_dashcam_capture',
        channelName: 'Sonus Auris recording',
        channelDescription:
            'Shows only while microphone recording is actively running.',
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
        // from a boot/restart receiver. Reboot recovery re-arms schedule
        // reminders only; capture starts after foreground user interaction.
        allowAutoRestart: false,
        stopWithTask: false,
      ),
    );
  }

  Future<String?> start({
    BackgroundCaptureMode mode = BackgroundCaptureMode.recording,
  }) async {
    if (!RuntimePlatform.isAndroid) {
      _diagnostics?.add('Foreground service skipped: platform is not Android.');
      return null;
    }

    // Policy boundary: schedule standby is not microphone use. Never start or
    // retain a microphone-typed foreground service merely because a schedule is
    // armed. Exact/inexact local notifications handle the next boundary and the
    // user brings the app to the foreground before capture starts.
    if (!mode.startsMicrophoneService) {
      _diagnostics?.add(
        'Schedule armed without a microphone foreground service; '
        'boundary reminders require foreground user action.',
      );
      await stop();
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
      _diagnostics?.add('Starting microphone foreground service.');
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
    if (!RuntimePlatform.isAndroid) {
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
