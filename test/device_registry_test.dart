import 'package:audio_dashcam/src/services/device_registry.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart';
import 'package:flutter_test/flutter_test.dart';

DeviceRecord device(
  String id, {
  String role = 'recorder',
  String? revokedAt,
  String lastSeenAt = '2026-07-17T00:00:00Z',
  String createdAt = '2026-07-01T00:00:00Z',
}) {
  return DeviceRecord(
    userId: 'user-1',
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
  group('defaultDeviceDisplayName', () {
    test('maps each contract platform to a friendly name', () {
      expect(defaultDeviceDisplayName('android'), 'Android phone');
      expect(defaultDeviceDisplayName('ios'), 'iPhone');
      expect(defaultDeviceDisplayName('macos'), 'Mac');
      expect(defaultDeviceDisplayName('windows'), 'Windows PC');
      expect(defaultDeviceDisplayName('linux'), 'Linux device');
      expect(defaultDeviceDisplayName('web'), 'Web browser');
      expect(defaultDeviceDisplayName('unknown'), 'Sonus Auris device');
    });
  });

  group('activeRecorderDevices', () {
    test('keeps only non-revoked recorders', () {
      final devices = [
        device('a'),
        device('b', role: 'viewer'),
        device('c', revokedAt: '2026-07-16T00:00:00Z'),
        device('d'),
      ];
      final active = activeRecorderDevices(devices).map((d) => d.deviceId);
      expect(active, containsAll(<String>['a', 'd']));
      expect(active, isNot(contains('b'))); // viewer excluded
      expect(active, isNot(contains('c'))); // revoked excluded
    });
  });

  group('selectDeviceIdsOverLimit', () {
    test('none over the line when at or under the limit', () {
      expect(selectDeviceIdsOverLimit([device('a')], 2), isEmpty);
      expect(
        selectDeviceIdsOverLimit([device('a'), device('b')], 2),
        isEmpty,
      );
    });

    test('the stalest devices beyond the limit are excess (free tier of 2)', () {
      final devices = [
        device('new', lastSeenAt: '2026-07-17T10:00:00Z'),
        device('mid', lastSeenAt: '2026-07-17T05:00:00Z'),
        device('old', lastSeenAt: '2026-07-17T01:00:00Z'),
      ];
      // Limit 2 keeps the two most-recently-seen; 'old' is over the line.
      expect(selectDeviceIdsOverLimit(devices, 2), {'old'});
    });

    test('a higher plan limit admits more devices', () {
      final devices = [
        for (var i = 0; i < 5; i++)
          device('d$i', lastSeenAt: '2026-07-17T0$i:00:00Z'),
      ];
      expect(selectDeviceIdsOverLimit(devices, 10), isEmpty);
    });

    test('revoked and viewer devices never count toward the limit', () {
      final devices = [
        device('r1'),
        device('r2'),
        device('viewer', role: 'viewer'),
        device('revoked', revokedAt: '2026-07-16T00:00:00Z'),
      ];
      // Only r1 + r2 are active recorders; both fit under limit 2.
      expect(selectDeviceIdsOverLimit(devices, 2), isEmpty);
    });

    test('ties break deterministically by created_at then device_id', () {
      final devices = [
        device('b', lastSeenAt: '2026-07-17T00:00:00Z', createdAt: '2026-07-01T00:00:00Z'),
        device('a', lastSeenAt: '2026-07-17T00:00:00Z', createdAt: '2026-07-01T00:00:00Z'),
      ];
      // Same timestamps → newer created_at wins, then device_id ascending: 'a'
      // sorts before 'b', so with limit 1 'b' is the excess.
      expect(selectDeviceIdsOverLimit(devices, 1), {'b'});
    });

    test('a negative limit selects nothing (guards misconfig)', () {
      expect(selectDeviceIdsOverLimit([device('a')], -1), isEmpty);
    });
  });
}
