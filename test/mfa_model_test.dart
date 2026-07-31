import 'package:flutter_test/flutter_test.dart';
import 'package:sonus_auris_console/src/models/mfa.dart';

void main() {
  test('parses a factors array, skipping entries with no id', () {
    final factors = MfaFactor.listFromUserJson({
      'factors': [
        {
          'id': 't1',
          'factor_type': 'totp',
          'status': 'verified',
          'friendly_name': 'Authy',
        },
        {
          'id': 'p1',
          'factor_type': 'phone',
          'status': 'unverified',
          'phone': '+15551230000',
        },
        {'factor_type': 'totp'}, // no id → skipped
      ],
    });
    expect(factors, hasLength(2));
    expect(factors[0].isTotp, isTrue);
    expect(factors[0].isVerified, isTrue);
    expect(factors[0].typeLabel, 'Authenticator app');
    expect(factors[1].isPhone, isTrue);
    expect(factors[1].isVerified, isFalse);
    expect(factors[1].typeLabel, 'Text message');
    expect(factors[1].phone, '+15551230000');
  });

  test('missing/invalid factors yields an empty list', () {
    expect(MfaFactor.listFromUserJson(const {}), isEmpty);
    expect(MfaFactor.listFromUserJson({'factors': 'nope'}), isEmpty);
  });
}
