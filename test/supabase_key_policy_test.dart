import 'dart:convert';

import 'package:audio_dashcam/src/services/supabase_key_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('allows public Supabase client key formats', () {
    expect(validateSupabaseClientKey('sb_publishable_project-key'), isNull);
    expect(validateSupabaseClientKey(_jwtWithRole('anon')), isNull);
  });

  test('rejects modern secret keys without echoing them', () {
    const secret = 'sb_secret_do-not-ship-this';
    final error = validateSupabaseClientKey(secret);

    expect(error, unsafeSupabaseKeyMessage);
    expect(error, isNot(contains(secret)));
  });

  test('rejects privileged legacy JWT roles', () {
    for (final role in const ['service_role', 'supabase_admin']) {
      final key = _jwtWithRole(role);
      final error = validateSupabaseClientKey(key);

      expect(error, unsafeSupabaseKeyMessage);
      expect(error, isNot(contains(key)));
    }
  });

  test('malformed nonempty keys are left for Supabase to authenticate', () {
    expect(validateSupabaseClientKey('not.a.valid-jwt'), isNull);
  });
}

String _jwtWithRole(String role) {
  String encode(Map<String, Object?> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode(const {'alg': 'HS256'})}.'
      '${encode({'role': role})}.signature';
}
