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

    test(
      'defaults to aal1 (fail toward requiring MFA) when absent/garbage',
      () {
        expect(aalFromJwt(jwt({'sub': 'u1'})), 'aal1');
        expect(aalFromJwt('not-a-jwt'), 'aal1');
        expect(aalFromJwt(''), 'aal1');
      },
    );
  });

  group('passwordlessAal2FromJwt', () {
    test('accepts an OTP first factor followed by MFA', () {
      expect(
        passwordlessFirstFactorFromJwt(
          jwt({
            'aal': 'aal1',
            'amr': [
              {'method': 'otp'},
            ],
          }),
        ),
        isTrue,
      );
      expect(
        passwordlessAal2FromJwt(
          jwt({
            'aal': 'aal2',
            'amr': [
              {'method': 'otp'},
              {'method': 'totp'},
            ],
          }),
        ),
        isTrue,
      );
    });

    test('rejects password-backed, missing-AMR, and malformed sessions', () {
      expect(
        passwordlessAal2FromJwt(
          jwt({
            'aal': 'aal2',
            'amr': [
              {'method': 'password'},
              {'method': 'totp'},
            ],
          }),
        ),
        isFalse,
      );
      expect(passwordlessAal2FromJwt(jwt({'aal': 'aal2'})), isFalse);
      expect(passwordlessAal2FromJwt('not-a-jwt'), isFalse);
      expect(
        passwordlessFirstFactorFromJwt(
          jwt({
            'aal': 'aal2',
            'amr': [
              {'method': 'password'},
              {'method': 'totp'},
            ],
          }),
        ),
        isFalse,
      );
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
