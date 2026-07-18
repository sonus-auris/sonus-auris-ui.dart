import 'dart:convert';

import 'package:audio_dashcam/src/models/supabase_mfa.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds an unsigned JWT with the given payload (signature is irrelevant to
/// the client-side, signature-agnostic decoder).
String jwt(Map<String, Object?> payload) {
  String seg(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.${seg(payload)}.sig';
}

void main() {
  group('MfaFactor parsing', () {
    test('lists verified and pending factors, skipping malformed entries', () {
      final user = <String, dynamic>{
        'factors': [
          {'id': 'f1', 'factor_type': 'totp', 'status': 'verified', 'friendly_name': 'Authy'},
          {'id': 'f2', 'factor_type': 'phone', 'status': 'unverified', 'phone': '+15551234567'},
          {'factor_type': 'totp', 'status': 'verified'}, // no id → skipped
          'garbage',
        ],
      };
      final factors = MfaFactor.listFromUserJson(user);
      expect(factors, hasLength(2));
      expect(factors[0].isTotp, isTrue);
      expect(factors[0].isVerified, isTrue);
      expect(factors[0].friendlyName, 'Authy');
      expect(factors[1].isPhone, isTrue);
      expect(factors[1].isVerified, isFalse);
      expect(factors[1].phone, '+15551234567');
    });

    test('missing or non-list factors yields an empty list', () {
      expect(MfaFactor.listFromUserJson(const {}), isEmpty);
      expect(MfaFactor.listFromUserJson({'factors': 'nope'}), isEmpty);
    });
  });

  group('decodeSupabaseAal', () {
    test('reads aal2 from a completed-MFA session token', () {
      expect(decodeSupabaseAal(jwt({'aal': 'aal2', 'sub': 'u1'})), 'aal2');
    });

    test('reads aal1 from a first-factor-only token', () {
      expect(decodeSupabaseAal(jwt({'aal': 'aal1'})), 'aal1');
    });

    test('returns null when the claim is absent or the token is malformed', () {
      expect(decodeSupabaseAal(jwt({'sub': 'u1'})), isNull);
      expect(decodeSupabaseAal('not-a-jwt'), isNull);
      expect(decodeSupabaseAal(''), isNull);
      expect(decodeSupabaseAal('a.b'), isNull);
    });
  });

  group('decodeJwtPayload', () {
    test('decodes claims regardless of base64url padding', () {
      final token = jwt({'sub': 'user-1234', 'email': 'a@example.test'});
      final payload = decodeJwtPayload(token);
      expect(payload, isNotNull);
      expect(payload!['sub'], 'user-1234');
      expect(payload['email'], 'a@example.test');
    });
  });
}
