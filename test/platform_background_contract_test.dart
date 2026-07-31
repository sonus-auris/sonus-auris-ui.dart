import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android keeps active capture alive and re-arms schedules on reboot', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android.permission.RECORD_AUDIO'));
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_MICROPHONE'),
    );
    expect(manifest, contains('android:foregroundServiceType="microphone"'));
    expect(manifest, contains('android:stopWithTask="false"'));
    expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    expect(manifest, contains('android.intent.action.BOOT_COMPLETED'));
    expect(
      manifest,
      contains(
        'dev.fluttercommunity.plus.androidalarmmanager.RebootBroadcastReceiver',
      ),
    );
  });

  test(
    'Android deliberately does not cold-start a microphone service at boot',
    () {
      final service = File(
        'lib/src/services/background_capture_service.dart',
      ).readAsStringSync();

      expect(service, contains('allowAutoRestart: false'));
      expect(
        service,
        contains(
          'Android 14+ forbids starting a microphone-typed foreground service',
        ),
      );
    },
  );

  test(
    'iOS declares audio background continuation for user-started capture',
    () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      final entitlements = File(
        'ios/Runner/Runner.entitlements',
      ).readAsStringSync();

      expect(plist, contains('<key>UIBackgroundModes</key>'));
      expect(plist, contains('<string>audio</string>'));
      expect(plist, contains('<key>NSMicrophoneUsageDescription</key>'));
      expect(plist, contains('<key>NSUbiquitousContainers</key>'));
      expect(plist, contains('iCloud.com.ores.audioDashcam'));
      expect(
        entitlements,
        contains('com.apple.developer.ubiquity-container-identifiers'),
      );
    },
  );

  test('collision reminders are wired to device motion while recording', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final sensor = File(
      'lib/src/services/collision_sensor_service.dart',
    ).readAsStringSync();
    final controller = File(
      'lib/src/app/app_controller.dart',
    ).readAsStringSync();
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(pubspec, contains('sensors_plus:'));
    expect(sensor, contains('userAccelerometerEventStream'));
    expect(controller, contains('_collisionSensors.start()'));
    expect(controller, contains('showPossibleCollision'));
    expect(controller, contains('sleepMotionSensorConsent'));
    expect(plist, contains('<key>NSMotionUsageDescription</key>'));
  });

  test('iCloud mirroring remains additive with other cloud destinations', () {
    final controller = File(
      'lib/src/app/app_controller.dart',
    ).readAsStringSync();

    expect(
      controller,
      isNot(contains('config.cloudProvider != CloudProvider.iCloudDrive')),
    );
    expect(
      controller,
      contains('return linkICloud();'),
      reason: 'the public link result must reflect iCloud availability/failure',
    );
  });

  test('an unavailable Supabase instance cannot block local app startup', () {
    final controller = File(
      'lib/src/app/app_controller.dart',
    ).readAsStringSync();
    final initBody = controller.substring(
      controller.indexOf('Future<void> init() async'),
      controller.indexOf(
        'Future<void> _initializeRemoteAccountServices() async',
      ),
    );

    expect(initBody, contains('unawaited(_initializeRemoteAccountServices())'));
    expect(initBody, isNot(contains('await _ensureSupabaseReady();')));
    expect(
      controller,
      contains('Account services will retry in the background'),
    );
  });

  test('desktop entrypoint wires launch-at-login after recording consent', () {
    final desktop = File('lib/main_desktop.dart').readAsStringSync();

    expect(desktop, contains('DesktopAutostart.setup()'));
    expect(desktop, contains('DesktopAutostart.enableByDefaultOnce()'));
    expect(desktop, contains('hasValidRecordingConsent'));
    expect(desktop, contains('_ready = _controller.init();'));
    expect(desktop, contains('unawaited(_startAlwaysOnRecorderAfterInit())'));
    expect(
      desktop,
      isNot(contains('_controller.init().then((_) async')),
      reason: 'microphone startup must not hold the desktop loading screen',
    );
  });

  test('desktop close keeps recording alive with tray and safe fallback', () {
    final desktop = File('lib/main_desktop.dart').readAsStringSync();

    expect(desktop, contains('windowManager.setPreventClose(true)'));
    expect(desktop, contains('trayManager.setContextMenu'));
    expect(desktop, contains("MenuItem(key: 'open'"));
    expect(desktop, contains("MenuItem(key: 'quit'"));
    expect(desktop, contains('void onWindowClose()'));
    expect(desktop, contains('windowManager.hide()'));
    expect(desktop, contains('windowManager.minimize()'));
  });

  test('mobile and desktop navigation stay within the requested limits', () {
    final mobile = File('lib/main.dart').readAsStringSync();
    final desktop = File('lib/main_desktop.dart').readAsStringSync();
    final mobileNav = mobile.substring(
      mobile.indexOf('bottomNavigationBar:'),
      mobile.indexOf('void _selectDestination'),
    );
    final desktopTabs = desktop.substring(
      desktop.indexOf('class _DesktopTabRail'),
      desktop.indexOf('class _NavItem'),
    );

    expect(
      RegExp(r'NavigationDestination\(').allMatches(mobileNav),
      hasLength(5),
    );
    expect(mobileNav, contains("label: 'Connections'"));
    expect(
      RegExp(r"\(Icons\.[^,]+, '[^']+'\)").allMatches(desktopTabs).length,
      lessThanOrEqualTo(7),
    );
    for (final label in [
      'Home',
      'Playback',
      'Configure',
      'Connections',
      'Devices',
    ]) {
      expect(desktopTabs, contains("'$label'"));
    }
    expect(
      desktop,
      contains('overflow: TextOverflow.ellipsis'),
      reason: 'long side-tab labels must remain inside the desktop rail',
    );
  });

  test('desktop Connections can configure direct S3 or R2 without sign-in', () {
    final desktop = File('lib/main_desktop.dart').readAsStringSync();

    expect(desktop, contains('Amazon S3 / Cloudflare R2'));
    expect(desktop, contains('Save and use S3/R2'));
    expect(desktop, contains('Direct storage works without a Sonus Auris'));
    expect(desktop, contains('s3SecretAccessKey'));
    expect(desktop, contains('obscureText: !_showS3Credentials'));
    expect(desktop, contains('widget.controller.saveSecrets(secrets)'));
    expect(
      desktop,
      isNot(contains('setState(() => _connections =')),
      reason: 'setState callbacks must not return the connection Future',
    );
    expect(
      desktop,
      contains('if (!widget.vm.isDeviceRegistered)'),
      reason: 'direct S3/R2 use must not make an account API request',
    );
  });

  test(
    'macOS release can record, use the network, and opt into signed iCloud',
    () {
      final localDebug = File(
        'macos/Runner/Debug.entitlements',
      ).readAsStringSync();
      final signedDebug = File(
        'macos/Runner/DebugProfile.entitlements',
      ).readAsStringSync();
      final release = File(
        'macos/Runner/Release.entitlements',
      ).readAsStringSync();
      final store = File('macos/Runner/Store.entitlements').readAsStringSync();
      final project = File(
        'macos/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();
      final plist = File('macos/Runner/Info.plist').readAsStringSync();
      final bridge = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      final notifications = File(
        'lib/src/services/local_notifications_service.dart',
      ).readAsStringSync();

      expect(release, contains('com.apple.security.device.audio-input'));
      expect(release, contains('com.apple.security.network.client'));
      expect(localDebug, contains('com.apple.security.app-sandbox'));
      expect(localDebug, isNot(contains('keychain-access-groups')));
      expect(signedDebug, contains('keychain-access-groups'));
      expect(release, isNot(contains('keychain-access-groups')));
      expect(store, contains('keychain-access-groups'));
      expect(plist, contains('NSMicrophoneUsageDescription'));
      expect(plist, contains('<string>sonusauris</string>'));
      expect(
        store,
        contains('com.apple.developer.icloud-container-identifiers'),
      );
      expect(store, contains('iCloud.com.ores.audioDashcam'));
      expect(
        project,
        contains('CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements'),
      );
      expect(plist, contains('<key>NSUbiquitousContainers</key>'));
      expect(plist, contains('<string>Sonus Auris</string>'));
      expect(bridge, contains('audio_dashcam/icloud'));
      expect(bridge, contains('setUbiquitous'));
      expect(project, contains('CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO'));
      expect(project, contains('ENABLE_HARDENED_RUNTIME = YES'));
      expect(
        notifications,
        contains('macOS: DarwinInitializationSettings('),
        reason:
            'Flutter desktop must not crash while initializing notifications',
      );
      expect(
        notifications,
        contains('MacOSFlutterLocalNotificationsPlugin'),
        reason: 'macOS notification permission needs the macOS plugin',
      );
    },
  );
}
