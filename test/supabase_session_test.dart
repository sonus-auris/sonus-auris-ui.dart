import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonus_auris_console/src/models/supabase_session.dart';

String tokenWith(Map<String, Object?> claims) {
  String seg(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'HS256'})}.${seg(claims)}.sig';
}

void main() {
  test('parses a verify/token response with an absolute expiry', () {
    final session = SupabaseSession.fromJson({
      'access_token': tokenWith({'sub': 's', 'aal': 'aal1'}),
      'refresh_token': 'r',
      'expires_at': 2000000000,
      'user': {'id': 'user-9', 'email': 'z@example.test'},
    });
    expect(session.userId, 'user-9');
    expect(session.email, 'z@example.test');
    expect(session.refreshToken, 'r');
    expect(session.expiresAtUtc, DateTime.fromMillisecondsSinceEpoch(2000000000 * 1000, isUtc: true));
    expect(session.aal, 'aal1');
    expect(session.isEmpty, isFalse);
  });

  test('falls back to expires_in seconds from now', () {
    final before = DateTime.now().toUtc();
    final session = SupabaseSession.fromJson({
      'access_token': tokenWith({'sub': 's'}),
      'expires_in': 3600,
    });
    expect(session.expiresAtUtc.isAfter(before.add(const Duration(minutes: 59))), isTrue);
  });

  test('reads identity from JWT claims when the user object is absent', () {
    final session = SupabaseSession.fromJson({
      'access_token': tokenWith({'sub': 'from-claim', 'email': 'c@example.test'}),
      'expires_in': 3600,
    });
    expect(session.userId, 'from-claim');
    expect(session.email, 'c@example.test');
  });

  test('throws when there is no access token', () {
    expect(
      () => SupabaseSession.fromJson(const {'refresh_token': 'r'}),
      throwsA(isA<FormatException>()),
    );
  });

  test('needsRefresh trips within the skew window', () {
    final now = DateTime.utc(2026, 7, 17, 12);
    final session = SupabaseSession(
      accessToken: tokenWith({'sub': 's'}),
      refreshToken: 'r',
      expiresAtUtc: now.add(const Duration(minutes: 1)),
      userId: 's',
      email: '',
    );
    expect(session.needsRefresh(now: now), isTrue);
    expect(
      session.needsRefresh(now: now.subtract(const Duration(minutes: 10))),
      isFalse,
    );
  });
}
