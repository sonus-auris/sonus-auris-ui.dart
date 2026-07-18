import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonus_auris_console/src/util/checkout_link.dart';
import 'package:sonus_auris_console/src/util/jwt_claims.dart';

String jwt(Map<String, Object?> payload) {
  String seg(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'HS256'})}.${seg(payload)}.sig';
}

void main() {
  group('aalFromJwt', () {
    test('reads aal2 once a factor is verified', () {
      expect(aalFromJwt(jwt({'aal': 'aal2'})), 'aal2');
    });

    test('defaults to aal1 (fail toward requiring MFA) when absent/garbage', () {
      expect(aalFromJwt(jwt({'sub': 'u1'})), 'aal1');
      expect(aalFromJwt('not-a-jwt'), 'aal1');
      expect(aalFromJwt(''), 'aal1');
    });
  });

  group('buildCheckoutUri', () {
    test('attributes the purchase to the user and prefills the email', () {
      final uri = buildCheckoutUri(
        paymentLink: 'https://buy.stripe.com/test_abc',
        userId: 'user-123',
        email: 'a@example.test',
      );
      expect(uri.queryParameters['client_reference_id'], 'user-123');
      expect(uri.queryParameters['prefilled_email'], 'a@example.test');
      expect(uri.origin, 'https://buy.stripe.com');
    });

    test('preserves existing query params on the payment link', () {
      final uri = buildCheckoutUri(
        paymentLink: 'https://buy.stripe.com/test_abc?utm=x',
        userId: 'u1',
        email: '',
      );
      expect(uri.queryParameters['utm'], 'x');
      expect(uri.queryParameters['client_reference_id'], 'u1');
      expect(uri.queryParameters.containsKey('prefilled_email'), isFalse);
    });
  });
}
