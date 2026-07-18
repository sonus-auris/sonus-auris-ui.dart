import 'package:flutter_test/flutter_test.dart';
import 'package:sonus_auris_console/src/services/device_service.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart';

DeviceRecord device(
  String id, {
  String role = 'recorder',
  String? revokedAt,
  String lastSeenAt = '2026-07-17T00:00:00Z',
  String createdAt = '2026-07-01T00:00:00Z',
}) {
  return DeviceRecord(
    userId: 'u1',
    deviceId: id,
    displayName: id,
    platform: 'android',
    role: role,
    lastSeenAt: lastSeenAt,
    revokedAt: revokedAt,
    createdAt: createdAt,
  );
}

void main() {
  group('activeRecorderDevices', () {
    test('keeps non-revoked recorders and drops viewers/revoked', () {
      final ids = activeRecorderDevices([
        device('a'),
        device('console', role: 'viewer'),
        device('gone', revokedAt: '2026-07-16T00:00:00Z'),
        device('b'),
      ]).map((d) => d.deviceId);
      expect(ids, containsAll(<String>['a', 'b']));
      expect(ids, isNot(contains('console')));
      expect(ids, isNot(contains('gone')));
    });
  });

  group('overLimitDeviceIds', () {
    test('nothing locked at or under the free limit of 2', () {
      expect(overLimitDeviceIds([device('a'), device('b')], 2), isEmpty);
    });

    test('locks the stalest recorders beyond the limit', () {
      final devices = [
        device('fresh', lastSeenAt: '2026-07-17T12:00:00Z'),
        device('mid', lastSeenAt: '2026-07-17T06:00:00Z'),
        device('stale', lastSeenAt: '2026-07-17T01:00:00Z'),
      ];
      expect(overLimitDeviceIds(devices, 2), {'stale'});
    });

    test('the console viewer never consumes a recorder slot', () {
      final devices = [
        device('r1'),
        device('r2'),
        device('console', role: 'viewer'),
      ];
      expect(overLimitDeviceIds(devices, 2), isEmpty);
    });

    test('a higher plan limit unlocks everything', () {
      final devices = [
        for (var i = 0; i < 6; i++)
          device('d$i', lastSeenAt: '2026-07-17T0$i:00:00Z'),
      ];
      expect(overLimitDeviceIds(devices, 10), isEmpty);
      expect(overLimitDeviceIds(devices, 2), hasLength(4));
    });
  });
}
