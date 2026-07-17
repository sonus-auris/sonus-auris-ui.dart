import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/context_trigger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults: context triggers off, no kinds', () {
    const config = AppConfig(deviceId: 'd');
    expect(config.contextTriggersEnabled, isFalse);
    expect(config.contextTriggerKindSet, isEmpty);
    expect(config.hasContextTriggers, isFalse);
  });

  test('hasContextTriggers requires enabled + a kind', () {
    final enabledNoKinds = const AppConfig(
      deviceId: 'd',
    ).copyWith(contextTriggersEnabled: true);
    expect(enabledNoKinds.hasContextTriggers, isFalse);

    final armed = enabledNoKinds.copyWith(
      contextTriggerKinds: [ContextTriggerKind.bluetoothConnect.wireName],
    );
    expect(armed.hasContextTriggers, isTrue);
    expect(armed.contextTriggerKindSet, {ContextTriggerKind.bluetoothConnect});
  });

  test('round-trips trigger config through JSON', () {
    final config = const AppConfig(deviceId: 'd').copyWith(
      contextTriggersEnabled: true,
      contextTriggerKinds: [
        ContextTriggerKind.networkChange.wireName,
        ContextTriggerKind.nearbyDevice.wireName,
      ],
      contextTriggerCooldownSeconds: 120,
    );
    final restored = AppConfig.fromJson(config.toJson());
    expect(restored.contextTriggersEnabled, isTrue);
    expect(restored.contextTriggerKindSet, {
      ContextTriggerKind.networkChange,
      ContextTriggerKind.nearbyDevice,
    });
    expect(restored.contextTriggerCooldownSeconds, 120);
  });

  test('back-compat: missing trigger keys default to off', () {
    final json = const AppConfig(deviceId: 'd').toJson()
      ..remove('contextTriggersEnabled')
      ..remove('contextTriggerKinds')
      ..remove('contextTriggerCooldownSeconds');
    final restored = AppConfig.fromJson(json);
    expect(restored.contextTriggersEnabled, isFalse);
    expect(restored.contextTriggerKindSet, isEmpty);
    expect(restored.contextTriggerCooldownSeconds, 300);
  });

  test('unknown trigger wire names are ignored', () {
    final config = const AppConfig(
      deviceId: 'd',
    ).copyWith(contextTriggerKinds: ['network_change', 'bogus_sensor']);
    expect(config.contextTriggerKindSet, {ContextTriggerKind.networkChange});
  });
}
