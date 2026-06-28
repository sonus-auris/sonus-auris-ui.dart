import 'dart:convert';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

AppConfig _roundTrip(AppConfig c) =>
    AppConfig.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);

void main() {
  test('sleep defaults are 90-min cycle, 5/6 target/backstop, sensors off', () {
    const c = AppConfig(deviceId: 'd');
    expect(c.sleepSmartAlarmEnabled, isTrue);
    expect(c.sleepDefaultCycleMinutes, 90);
    expect(c.sleepTargetCycle, 5);
    expect(c.sleepBackstopCycle, 6);
    expect(c.sleepSmartWindowMinutes, 25);
    expect(c.sleepMotionConsent, isFalse);
    expect(c.sleepLightConsent, isFalse);
  });

  test('sleep fields survive a JSON round-trip', () {
    const c = AppConfig(
      deviceId: 'd',
      sleepSmartAlarmEnabled: false,
      sleepDefaultCycleMinutes: 75,
      sleepTargetCycle: 4,
      sleepBackstopCycle: 5,
      sleepSmartWindowMinutes: 40,
      sleepMotionConsent: true,
      sleepLightConsent: true,
    );
    final back = _roundTrip(c);
    expect(back.sleepSmartAlarmEnabled, isFalse);
    expect(back.sleepDefaultCycleMinutes, 75);
    expect(back.sleepTargetCycle, 4);
    expect(back.sleepBackstopCycle, 5);
    expect(back.sleepSmartWindowMinutes, 40);
    expect(back.sleepMotionConsent, isTrue);
    expect(back.sleepLightConsent, isTrue);
  });

  test('copyWith updates only the named sleep fields', () {
    const c = AppConfig(deviceId: 'd');
    final c2 = c.copyWith(sleepMotionConsent: true, sleepDefaultCycleMinutes: 100);
    expect(c2.sleepMotionConsent, isTrue);
    expect(c2.sleepDefaultCycleMinutes, 100);
    // Untouched.
    expect(c2.sleepLightConsent, isFalse);
    expect(c2.sleepTargetCycle, 5);
  });

  test('fromJson clamps out-of-range values', () {
    final json = const AppConfig(deviceId: 'd').toJson()
      ..['sleepDefaultCycleMinutes'] = 999.0
      ..['sleepSmartWindowMinutes'] = -5.0
      ..['sleepTargetCycle'] = 99;
    final c = AppConfig.fromJson(json);
    expect(c.sleepDefaultCycleMinutes, lessThanOrEqualTo(130));
    expect(c.sleepDefaultCycleMinutes, greaterThanOrEqualTo(60));
    expect(c.sleepSmartWindowMinutes, greaterThanOrEqualTo(0));
    expect(c.sleepTargetCycle, lessThanOrEqualTo(12));
  });

  test('fromJson supplies defaults when sleep keys are absent', () {
    // Simulate an older persisted config with no sleep keys.
    final json = const AppConfig(deviceId: 'd').toJson();
    for (final k in [
      'sleepSmartAlarmEnabled',
      'sleepDefaultCycleMinutes',
      'sleepTargetCycle',
      'sleepBackstopCycle',
      'sleepSmartWindowMinutes',
      'sleepMotionConsent',
      'sleepLightConsent',
    ]) {
      json.remove(k);
    }
    final c = AppConfig.fromJson(json);
    expect(c.sleepSmartAlarmEnabled, isTrue);
    expect(c.sleepDefaultCycleMinutes, 90);
    expect(c.sleepMotionConsent, isFalse);
  });
}
