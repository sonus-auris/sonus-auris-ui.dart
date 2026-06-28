import 'package:audio_dashcam/src/models/consent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('microphone is the only required consent item', () {
    final required =
        ConsentItem.values.where((i) => i.required).toList();
    expect(required, [ConsentItem.microphone]);
  });

  test('fromKey round-trips every item and rejects unknown keys', () {
    for (final item in ConsentItem.values) {
      expect(ConsentItem.fromKey(item.key), item);
    }
    expect(ConsentItem.fromKey('nope'), isNull);
  });

  test('hasRequiredConsents reflects the required grants', () {
    ConsentRecord record(Map<ConsentItem, bool> grants) => ConsentRecord(
          consentVersion: 'v1',
          acceptedAtUtc: DateTime.utc(2026, 6, 28),
          grants: {for (final e in grants.entries) e.key.key: e.value},
        );
    expect(record({ConsentItem.microphone: true}).hasRequiredConsents, isTrue);
    expect(record({ConsentItem.microphone: false}).hasRequiredConsents, isFalse);
    expect(record({}).hasRequiredConsents, isFalse);
  });

  test('JSON round-trip preserves all fields', () {
    final record = ConsentRecord(
      consentVersion: 'audio-dashcam-consent-v1',
      acceptedAtUtc: DateTime.utc(2026, 6, 28, 7, 30),
      platform: 'ios',
      grants: const {
        'microphone': true,
        'location': false,
        'motion': true,
      },
      synced: true,
    );
    final back = ConsentRecord.fromJson(record.toJson());
    expect(back.consentVersion, record.consentVersion);
    expect(back.acceptedAtUtc, record.acceptedAtUtc);
    expect(back.platform, 'ios');
    expect(back.synced, isTrue);
    expect(back.granted(ConsentItem.microphone), isTrue);
    expect(back.granted(ConsentItem.location), isFalse);
    expect(back.granted(ConsentItem.motion), isTrue);
  });

  test('copyWith only flips synced', () {
    final record = ConsentRecord(
      consentVersion: 'v1',
      acceptedAtUtc: DateTime.utc(2026, 6, 28),
      grants: const {'microphone': true},
    );
    final synced = record.copyWith(synced: true);
    expect(synced.synced, isTrue);
    expect(synced.consentVersion, 'v1');
    expect(synced.granted(ConsentItem.microphone), isTrue);
  });

  test('toSupabaseRow carries device id + grants, never a user id', () {
    final row = ConsentRecord(
      consentVersion: 'v1',
      acceptedAtUtc: DateTime.utc(2026, 6, 28, 7),
      platform: 'android',
      grants: const {'microphone': true, 'bluetooth': false},
    ).toSupabaseRow('device-123');
    expect(row['device_id'], 'device-123');
    expect(row['consent_version'], 'v1');
    expect(row['platform'], 'android');
    expect((row['granted'] as Map)['microphone'], isTrue);
    expect(row.containsKey('user_id'), isFalse);
    expect(row['accepted_at'], '2026-06-28T07:00:00.000Z');
  });

  test('fromJson tolerates malformed grants + missing fields', () {
    final record = ConsentRecord.fromJson({
      'consentVersion': 'v2',
      'grants': {'microphone': true, 'bogus': 'not-bool', 7: true},
    });
    expect(record.consentVersion, 'v2');
    expect(record.granted(ConsentItem.microphone), isTrue);
    expect(record.grants.containsKey('bogus'), isFalse);
    expect(record.synced, isFalse);
  });
}
