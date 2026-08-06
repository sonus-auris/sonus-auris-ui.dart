import 'dart:async';

import 'package:audio_dashcam/src/platform/desktop_shutdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quit continues after failed and timed-out cleanup steps', () async {
    final calls = <String>[];
    final never = Completer<void>();
    int? exitCode;

    const coordinator = DesktopShutdownCoordinator(
      platformStepTimeout: Duration(milliseconds: 20),
      controllerTimeout: Duration(milliseconds: 20),
    );

    await coordinator.shutdown(
      allowClose: () async {
        calls.add('allow-close');
        throw StateError('native close failed');
      },
      destroyTray: () {
        calls.add('destroy-tray');
        return never.future;
      },
      disposeController: () async {
        calls.add('dispose-controller');
      },
      destroyWindow: () async {
        calls.add('destroy-window');
      },
      terminateProcess: (code) {
        calls.add('exit');
        exitCode = code;
      },
    );

    expect(calls, <String>[
      'allow-close',
      'destroy-tray',
      'dispose-controller',
      'destroy-window',
      'exit',
    ]);
    expect(exitCode, 0);
  });

  test('controller disposal gets its own bounded grace period', () async {
    final never = Completer<void>();
    var windowDestroyed = false;
    var exited = false;

    const coordinator = DesktopShutdownCoordinator(
      platformStepTimeout: Duration(milliseconds: 10),
      controllerTimeout: Duration(milliseconds: 25),
    );

    await coordinator.shutdown(
      allowClose: () async {},
      destroyTray: () async {},
      disposeController: () => never.future,
      destroyWindow: () async {
        windowDestroyed = true;
      },
      terminateProcess: (_) {
        exited = true;
      },
    );

    expect(windowDestroyed, isTrue);
    expect(exited, isTrue);
  });
}
