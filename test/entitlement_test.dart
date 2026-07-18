import 'package:flutter_test/flutter_test.dart';
import 'package:sonus_auris_console/src/services/entitlements_service.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart' as interfaces;

void main() {
  test('the free default is 2 devices, no premium features', () {
    const e = Entitlement.free;
    expect(e.plan, 'free');
    expect(e.deviceLimit, 2);
    expect(e.isPlus, isFalse);
    expect(e.hasFeature('permanent_saves'), isFalse);
  });

  test('a plus row unlocks the raised limit and features', () {
    final e = Entitlement.fromRow(
      interfaces.Entitlement(
        userId: 'u1',
        plan: 'plus',
        deviceLimit: 5,
        features: const {'permanent_saves': true},
        source: 'stripe',
        currentPeriodEnd: '2026-08-01T00:00:00Z',
        updatedAt: '2026-07-17T00:00:00Z',
        createdAt: '2026-07-01T00:00:00Z',
      ),
    );
    expect(e.isPlus, isTrue);
    expect(e.deviceLimit, 5);
    expect(e.source, 'stripe');
    expect(e.hasFeature('permanent_saves'), isTrue);
    expect(e.currentPeriodEnd, DateTime.utc(2026, 8, 1));
  });
}
