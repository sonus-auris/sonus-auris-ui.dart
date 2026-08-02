import 'dart:async';

typedef DesktopShutdownStep = Future<void> Function();

/// Runs desktop shutdown as a bounded, best-effort sequence.
///
/// Explicit Quit must always terminate the process. Recorder, tray, and native
/// window plugins still receive a grace period to flush/close cleanly, but none
/// can keep Sonus Auris alive forever.
class DesktopShutdownCoordinator {
  const DesktopShutdownCoordinator({
    this.platformStepTimeout = const Duration(seconds: 1),
    this.controllerTimeout = const Duration(seconds: 3),
  });

  final Duration platformStepTimeout;
  final Duration controllerTimeout;

  Future<void> shutdown({
    required DesktopShutdownStep allowClose,
    required DesktopShutdownStep destroyTray,
    required DesktopShutdownStep disposeController,
    required DesktopShutdownStep destroyWindow,
    required void Function(int code) terminateProcess,
  }) async {
    await _bestEffort(allowClose, platformStepTimeout);
    await _bestEffort(destroyTray, platformStepTimeout);
    await _bestEffort(disposeController, controllerTimeout);
    await _bestEffort(destroyWindow, platformStepTimeout);
    terminateProcess(0);
  }

  static Future<void> _bestEffort(
    DesktopShutdownStep step,
    Duration timeout,
  ) async {
    try {
      await step().timeout(timeout);
    } catch (_) {
      // Explicit Quit is fail-open: later cleanup and process termination must
      // continue even if one plugin throws or never completes.
    }
  }
}
