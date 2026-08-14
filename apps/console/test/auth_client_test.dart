import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sonus_auris_console/src/config/console_config.dart';
import 'package:sonus_auris_console/src/services/auth_client.dart';

const _config = ConsoleConfig(
  supabaseUrl: 'https://project.supabase.co',
  supabaseAnonKey: 'sb_publishable_test',
  authRedirectUrl: 'https://console.example/auth/callback',
);
const _verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const _challenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

String sessionBody({String aal = 'aal1'}) {
  final header = base64Url
      .encode(utf8.encode('{"alg":"HS256"}'))
      .replaceAll('=', '');
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sub': 'user-1',
            'email': 'a@example.test',
            'aal': aal,
            'exp':
                DateTime.now()
                    .toUtc()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000,
            'amr': [
              {'method': 'otp'},
              if (aal == 'aal2') {'method': 'totp'},
            ],
          }),
        ),
      )
      .replaceAll('=', '');
  final token = '$header.$payload.sig';
  return jsonEncode({
    'access_token': token,
    'refresh_token': 'refresh-1',
    'expires_in': 3600,
    'user': {'id': 'user-1', 'email': 'a@example.test'},
  });
}

void main() {
  test(
    'sendEmailOtp posts to /auth/v1/otp with create_user and the anon key',
    () async {
      late http.Request captured;
      final client = AuthClient(
        config: _config,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('{}', 200);
        }),
      );
      await client.sendEmailOtp('a@example.test', codeVerifier: _verifier);
      expect(captured.url.path, '/auth/v1/otp');
      expect(
        captured.url.queryParameters['redirect_to'],
        'https://console.example/auth/callback',
      );
      expect(captured.headers['apikey'], 'sb_publishable_test');
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      expect(body['email'], 'a@example.test');
      expect(body['create_user'], true);
      expect(body['code_challenge'], _challenge);
      expect(body['code_challenge_method'], 's256');
    },
  );

  test('sendEmailOtp surfaces the Supabase email delivery error', () async {
    final client = AuthClient(
      config: _config,
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'code': 429,
            'error_code': 'over_email_send_rate_limit',
            'msg': 'email rate limit exceeded',
          }),
          429,
        ),
      ),
    );

    await expectLater(
      client.sendEmailOtp('a@example.test', codeVerifier: _verifier),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'email rate limit exceeded',
        ),
      ),
    );
  });

  test(
    'PKCE callback exchanges one code and rejects implicit tokens',
    () async {
      final client = AuthClient(
        config: _config,
        httpClient: MockClient((req) async {
          expect(req.url.queryParameters['grant_type'], 'pkce');
          expect(jsonDecode(req.body), {
            'auth_code': 'authorization-code',
            'code_verifier': _verifier,
          });
          return http.Response(sessionBody(), 200);
        }),
      );
      final code = client.authorizationCodeFromCallback(
        Uri.parse(
          'https://console.example/auth/callback?code=authorization-code',
        ),
      );
      final session = await client.exchangePkceCode(
        authorizationCode: code,
        codeVerifier: _verifier,
      );
      expect(session.userId, 'user-1');

      expect(
        () => client.authorizationCodeFromCallback(
          Uri.parse(
            'https://console.example/auth/callback'
            '#access_token=stolen&refresh_token=stolen',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'PKCE verifiers are unique and malformed values never reach the network',
    () async {
      final generated = {
        for (var i = 0; i < 128; i++) AuthClient.createPkceVerifier(),
      };
      expect(generated, hasLength(128));
      for (final candidate in generated) {
        expect(candidate.length, inInclusiveRange(43, 128));
        expect(candidate, matches(RegExp(r'^[A-Za-z0-9._~-]+$')));
      }

      var calls = 0;
      final client = AuthClient(
        config: _config,
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      for (final invalid in [
        'short',
        List.filled(129, 'a').join(),
        '${List.filled(42, 'a').join()}!',
      ]) {
        await expectLater(
          client.sendEmailOtp('a@example.test', codeVerifier: invalid),
          throwsA(isA<FormatException>()),
        );
      }
      expect(calls, 0);
    },
  );

  test(
    'callback parser rejects tokens, duplicates, errors, and near matches',
    () {
      final client = AuthClient(
        config: _config,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      for (final callback in [
        'https://console.example/auth/callback',
        'https://console.example/auth/callback?code=',
        'https://console.example/auth/callback?code=one&code=two',
        'https://console.example/auth/callback?code=%0A',
        'https://console.example/auth/callback?code=one&access_token=stolen',
        'https://console.example/auth/callback?code=one&refresh_token=stolen',
        'https://console.example/auth/callback?code=one&error=access_denied',
        'https://user@console.example/auth/callback?code=one',
        'https://console.example:8443/auth/callback?code=one',
        'https://console.example/auth/callback/?code=one',
        'https://attacker.example/auth/callback?code=one',
      ]) {
        expect(
          () => client.authorizationCodeFromCallback(Uri.parse(callback)),
          throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
        );
      }
    },
  );

  test('unsafe Supabase origins are rejected before any request', () async {
    var calls = 0;
    for (final url in [
      'http://project.supabase.co',
      'https://user:secret@project.supabase.co',
      'https://project.supabase.co?tenant=other',
      'https://project.supabase.co#other',
    ]) {
      final client = AuthClient(
        config: ConsoleConfig(
          supabaseUrl: url,
          supabaseAnonKey: 'sb_publishable_test',
          authRedirectUrl: 'https://console.example/auth/callback',
        ),
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        client.sendEmailOtp('a@example.test', codeVerifier: _verifier),
        throwsA(isA<FormatException>()),
      );
    }
    expect(calls, 0);
  });

  test(
    'PKCE exchange errors are surfaced and malformed success fails closed',
    () async {
      final rejected = AuthClient(
        config: _config,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'msg': 'internal account and project details'}),
            400,
          ),
        ),
      );
      await expectLater(
        rejected.exchangePkceCode(
          authorizationCode: 'authorization-code',
          codeVerifier: _verifier,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'internal account and project details',
          ),
        ),
      );

      final malformed = AuthClient(
        config: _config,
        httpClient: MockClient((_) async => http.Response('[]', 200)),
      );
      await expectLater(
        malformed.exchangePkceCode(
          authorizationCode: 'authorization-code',
          codeVerifier: _verifier,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('verifyEmailOtp exchanges a code for a session', () async {
    final client = AuthClient(
      config: _config,
      httpClient: MockClient((req) async {
        expect(req.url.path, '/auth/v1/verify');
        final body = jsonDecode(req.body) as Map<String, Object?>;
        expect(body['type'], 'email');
        expect(body['token'], '123456');
        return http.Response(sessionBody(), 200);
      }),
    );
    final session = await client.verifyEmailOtp(
      email: 'a@example.test',
      code: '123456',
    );
    expect(session.userId, 'user-1');
    expect(session.email, 'a@example.test');
    expect(session.aal, 'aal1');
    expect(session.refreshToken, 'refresh-1');
  });

  test(
    'verifyEmailOtp requires exactly six digits without a request',
    () async {
      var called = false;
      final client = AuthClient(
        config: _config,
        httpClient: MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      for (final invalidCode in [' ', '12345', '1234567', '12x456', '12345a']) {
        await expectLater(
          client.verifyEmailOtp(email: 'a@example.test', code: invalidCode),
          throwsA(isA<FormatException>()),
        );
      }
      expect(called, isFalse);
    },
  );

  test('consumeMagicLink accepts only the configured callback URI', () async {
    var called = false;
    final client = AuthClient(
      config: _config,
      httpClient: MockClient((req) async {
        called = true;
        expect(req.url.path, '/auth/v1/verify');
        return http.Response(sessionBody(), 200);
      }),
    );

    final session = await client.consumeMagicLink(
      Uri.parse(
        'https://console.example/auth/callback?token_hash=server-verified',
      ),
    );
    expect(called, isTrue);
    expect(session.userId, 'user-1');
    expect(session.refreshToken, 'refresh-1');

    for (final wrongTarget in [
      'another-app://console.example/auth/callback?token_hash=t',
      'https://evil.example/auth/callback?token_hash=t',
      'https://console.example/auth/other?token_hash=t',
      'https://console.example:8443/auth/callback?token_hash=t',
    ]) {
      expect(
        () => client.consumeMagicLink(Uri.parse(wrongTarget)),
        throwsA(isA<FormatException>()),
        reason: '$wrongTarget must not be treated as our callback',
      );
    }
  });

  test(
    'consumeMagicLink refuses URL bearer tokens (no implicit flow)',
    () async {
      final encoded = jsonDecode(sessionBody()) as Map<String, Object?>;
      var called = false;
      final client = AuthClient(
        config: _config,
        httpClient: MockClient((_) async {
          called = true;
          return http.Response(sessionBody(), 200);
        }),
      );

      // A session handed to us in the URL is bound to no PKCE verifier this
      // client generated, so it must never become a signed-in session.
      for (final implicit in [
        'https://console.example/auth/callback'
            '#access_token=${encoded['access_token']}'
            '&refresh_token=${encoded['refresh_token']}&expires_in=3600',
        'https://console.example/auth/callback'
            '?access_token=${encoded['access_token']}&refresh_token=refresh-1',
        'https://console.example/auth/callback?refresh_token=refresh-1',
      ]) {
        await expectLater(
          client.consumeMagicLink(Uri.parse(implicit)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('older sign-in link'),
            ),
          ),
        );
      }
      expect(
        called,
        isFalse,
        reason: 'no token should be exchanged for an implicit link',
      );
    },
  );

  test(
    'consumeMagicLink fails closed when no redirect is allow-listed',
    () async {
      var called = false;
      final client = AuthClient(
        // A scheme outside the allowlist makes `magicLinkRedirectUri` null; the
        // weaker `ConsoleConfig.authRedirectUri` must not be used as a fallback.
        config: const ConsoleConfig(
          supabaseUrl: 'https://project.supabase.co',
          supabaseAnonKey: 'sb_publishable_test',
          authRedirectUrl: 'ftp://console.example/auth/callback',
        ),
        httpClient: MockClient((_) async {
          called = true;
          return http.Response(sessionBody(), 200);
        }),
      );

      expect(client.magicLinkRedirectUri, isNull);
      await expectLater(
        client.consumeMagicLink(
          Uri.parse('ftp://console.example/auth/callback?token_hash=t'),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(called, isFalse);
    },
  );

  test('refreshSession uses the refresh_token grant', () async {
    final client = AuthClient(
      config: _config,
      httpClient: MockClient((req) async {
        expect(req.url.path, '/auth/v1/token');
        expect(req.url.queryParameters['grant_type'], 'refresh_token');
        return http.Response(sessionBody(aal: 'aal2'), 200);
      }),
    );
    final session = await client.refreshSession('refresh-1');
    expect(session.aal, 'aal2');
  });

  test('a GoTrue verification error exposes the real server message', () async {
    final client = AuthClient(
      config: _config,
      httpClient: MockClient((req) async {
        return http.Response(jsonEncode({'msg': 'Token has expired'}), 401);
      }),
    );
    expect(
      () => client.verifyEmailOtp(email: 'a@example.test', code: '000000'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Token has expired',
        ),
      ),
    );
  });

  test(
    'MFA: enrollTotp returns the shared secret and challenge id flows',
    () async {
      late http.Request enrollmentRequest;
      final client = AuthClient(
        config: _config,
        httpClient: MockClient((req) async {
          if (req.url.path == '/auth/v1/factors') {
            enrollmentRequest = req;
            return http.Response(
              jsonEncode({
                'id': 'factor-1',
                'totp': {
                  'secret': 'BASE32SECRET',
                  'uri': 'otpauth://totp/x',
                  'qr_code': '<svg/>',
                },
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
      final enrollment = await client.enrollTotp(
        'token',
        friendlyName: 'Authy',
      );
      expect(enrollment.factorId, 'factor-1');
      expect(enrollment.secret, 'BASE32SECRET');
      expect(enrollment.uri, 'otpauth://totp/x');
      expect(jsonDecode(enrollmentRequest.body), {
        'factor_type': 'totp',
        'friendly_name': 'Authy',
        'issuer': 'sonus-auris:live',
      });
    },
  );

  test('MFA: authenticator issuer separates local and live accounts', () {
    for (final url in [
      'http://localhost:54321',
      'http://127.0.0.1:54321',
      'http://10.0.2.2:54321',
      'http://[::1]:54321',
    ]) {
      expect(consoleTotpIssuerForUrl(url), 'sonus-auris:localhost');
    }
    expect(
      consoleTotpIssuerForUrl('https://project.supabase.co'),
      'sonus-auris:live',
    );
  });

  test('challengeFactor returns the challenge id', () async {
    final client = AuthClient(
      config: _config,
      httpClient: MockClient((req) async {
        expect(req.url.path, '/auth/v1/factors/factor-1/challenge');
        return http.Response(jsonEncode({'id': 'challenge-1'}), 200);
      }),
    );
    expect(await client.challengeFactor('token', 'factor-1'), 'challenge-1');
  });

  test('verifyFactor adopts the new aal2 session', () async {
    final client = AuthClient(
      config: _config,
      httpClient: MockClient((req) async {
        expect(req.url.path, '/auth/v1/factors/factor-1/verify');
        final body = jsonDecode(req.body) as Map<String, Object?>;
        expect(body['challenge_id'], 'challenge-1');
        expect(body['code'], '123456');
        return http.Response(sessionBody(aal: 'aal2'), 200);
      }),
    );
    final session = await client.verifyFactor(
      'token',
      factorId: 'factor-1',
      challengeId: 'challenge-1',
      code: '123456',
    );
    expect(session.aal, 'aal2');
  });

  test('a service-role key is refused before any request', () async {
    var called = false;
    final client = AuthClient(
      config: const ConsoleConfig(
        supabaseUrl: 'https://project.supabase.co',
        supabaseAnonKey: 'sb_secret_do_not_use',
        authRedirectUrl: 'https://console.example/auth/callback',
      ),
      httpClient: MockClient((req) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      () => client.sendEmailOtp('a@example.test', codeVerifier: _verifier),
      throwsA(isA<FormatException>()),
    );
    expect(called, isFalse);
  });
}
