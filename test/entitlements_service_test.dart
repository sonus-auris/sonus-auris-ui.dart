import 'package:audio_dashcam/src/services/entitlements_service.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 7, 17);

  group('EntitlementsSnapshot', () {
    test('fallback is the free tier with a 2-device limit', () {
      final snap = EntitlementsSnapshot.fallback(nowUtc: now);
      expect(snap.plan, 'free');
      expect(snap.deviceLimit, kFreeTierDeviceLimit);
      expect(snap.deviceLimit, 2);
      expect(snap.isPlus, isFalse);
      expect(snap.hasFeature('permanent_saves'), isFalse);
    });

    test('maps a plus row and its feature flags', () {
      final row = Entitlement(
        userId: 'u1',
        plan: 'plus',
        deviceLimit: 10,
        features: const {'permanent_saves': true},
        source: 'stripe',
        externalRef: 'sub_123',
        currentPeriodEnd: '2026-08-17T00:00:00Z',
        updatedAt: '2026-07-17T00:00:00Z',
        createdAt: '2026-07-01T00:00:00Z',
      );
      final snap = EntitlementsSnapshot.fromRow(row, nowUtc: now);
      expect(snap.isPlus, isTrue);
      expect(snap.deviceLimit, 10);
      expect(snap.source, 'stripe');
      expect(snap.hasFeature('permanent_saves'), isTrue);
      expect(snap.currentPeriodEnd, DateTime.utc(2026, 8, 17));
    });

    test('lifetime purchasers are permanently subscription-exempt', () {
      final row = Entitlement(
        userId: 'founder-1',
        plan: 'lifetime',
        deviceLimit: 10,
        features: const {'founders_lifetime': true, 'permanent_saves': true},
        source: 'play_store',
        externalRef: 'play-license:founder-1',
        updatedAt: '2026-07-29T00:00:00Z',
        createdAt: '2026-07-29T00:00:00Z',
      );
      final snap = EntitlementsSnapshot.fromRow(row, nowUtc: now);
      expect(snap.isLifetime, isTrue);
      expect(snap.isSubscriptionExempt, isTrue);
      expect(snap.hasPaidEntitlement, isTrue);
      expect(snap.isPlus, isFalse);
      expect(snap.currentPeriodEnd, isNull);
    });

    test('a blank plan degrades to free', () {
      final row = Entitlement(
        userId: 'u1',
        plan: '',
        deviceLimit: 2,
        features: const {},
        source: '',
        updatedAt: '2026-07-17T00:00:00Z',
        createdAt: '2026-07-01T00:00:00Z',
      );
      expect(EntitlementsSnapshot.fromRow(row, nowUtc: now).plan, 'free');
    });
  });
}
