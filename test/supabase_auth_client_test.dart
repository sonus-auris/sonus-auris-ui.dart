import 'dart:convert';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/supabase_session.dart';
import 'package:audio_dashcam/src/services/supabase_auth_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
  const challenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
  const config = AppConfig(
    deviceId: 'device-a',
    supabaseUrl: 'https://project.supabase.co',
    supabaseAnonKey: 'anon-key-123',
  );

  test('sendEmailOtp requests one magic link for sign-up or sign-in', () async {
    late http.Request captured;
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('{}', 200);
      }),
    );

    await client.sendEmailOtp(
      config: config,
      email: ' user@example.com ',
      codeVerifier: verifier,
      redirectTo: 'sonusauris://auth/callback',
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/auth/v1/otp');
    expect(
      captured.url.queryParameters['redirect_to'],
      'sonusauris://auth/callback',
    );
    expect(captured.headers['apikey'], 'anon-key-123');
    expect(captured.headers['authorization'], 'Bearer anon-key-123');
    expect(jsonDecode(captured.body), {
      'email': 'user@example.com',
      'create_user': true,
      'code_challenge': challenge,
      'code_challenge_method': 's256',
    });
  });

  test('PKCE uses an RFC 7636 S256 challenge and strong verifier', () {
    expect(SupabaseAuthClient.pkceChallengeForVerifier(verifier), challenge);
    final generated = {
      for (var i = 0; i < 128; i++) SupabaseAuthClient.createPkceVerifier(),
    };
    expect(generated, hasLength(128));
    for (final candidate in generated) {
      expect(candidate.length, inInclusiveRange(43, 128));
      expect(candidate, matches(RegExp(r'^[A-Za-z0-9._~-]+$')));
    }
  });

  test('verifyEmailOtp redeems a one-time code for a session', () async {
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/auth/v1/verify');
        expect(jsonDecode(request.body), {
          'type': 'email',
          'email': 'user@example.com',
          'token': '123456',
        });
        return http.Response(
          jsonEncode({
            'access_token': 'access-1',
            'refresh_token': 'refresh-1',
            'expires_in': 3600,
            'user': {'id': 'user-1', 'email': 'user@example.com'},
          }),
          200,
        );
      }),
    );

    final session = await client.verifyEmailOtp(
      config: config,
      email: 'user@example.com',
      code: '123456',
    );

    expect(session.accessToken, 'access-1');
    expect(session.refreshToken, 'refresh-1');
    expect(session.userId, 'user-1');
  });

  test('verifyEmailOtp rejects malformed codes before any request', () async {
    var called = false;
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      client.verifyEmailOtp(
        config: config,
        email: 'user@example.com',
        code: '12345a',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(called, isFalse);
  });

  test('magic-link PKCE code is exchanged without URL bearer tokens', () async {
    late http.Request captured;
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'access_token': 'access-2',
            'refresh_token': 'refresh-2',
            'expires_in': 1800,
            'user': {'id': 'user-2', 'email': 'listener@example.com'},
          }),
          200,
        );
      }),
    );
    final callback = Uri.parse(
      'sonusauris://auth/callback?code=authorization-code',
    );
    final code = SupabaseAuthClient.authorizationCodeFromCallback(
      callbackUri: callback,
      expectedRedirectUri: Uri.parse('sonusauris://auth/callback'),
    );

    final session = await client.exchangePkceCode(
      config: config,
      authorizationCode: code,
      codeVerifier: verifier,
    );

    expect(captured.url.path, '/auth/v1/token');
    expect(captured.url.queryParameters['grant_type'], 'pkce');
    expect(jsonDecode(captured.body), {
      'auth_code': 'authorization-code',
      'code_verifier': verifier,
    });
    expect(session.accessToken, 'access-2');
    expect(session.refreshToken, 'refresh-2');
    expect(session.userId, 'user-2');
  });

  test(
    'callback rejects tokens, duplicates, errors, controls, and near matches',
    () {
      final expected = Uri.parse('sonusauris://auth/callback');
      for (final callback in [
        Uri.parse(
          'sonusauris://auth/callback'
          '#access_token=stolen&refresh_token=stolen-too',
        ),
        Uri.parse('sonusauris://auth/callback?code=one&code=two'),
        Uri.parse('sonusauris://auth/callback?access_token=stolen&code=one'),
        Uri.parse('sonusauris://auth/callback?refresh_token=stolen&code=one'),
        Uri.parse('sonusauris://attacker/callback?code=one'),
        Uri.parse('sonusauris://user@auth/callback?code=one'),
        Uri.parse('sonusauris://auth:443/callback?code=one'),
        Uri.parse('sonusauris://auth/callback/?code=one'),
        Uri.parse('sonusauris://auth/Callback?code=one'),
        Uri.parse('sonusauris://auth/callback'),
        Uri.parse('sonusauris://auth/callback?code='),
        Uri.parse('sonusauris://auth/callback?code=%0A'),
        Uri.parse(
          'sonusauris://auth/callback?code=${List.filled(2049, 'a').join()}',
        ),
        Uri.parse('sonusauris://auth/callback?error=access_denied'),
        Uri.parse('sonusauris://auth/callback?error_code=otp_expired&code=one'),
      ]) {
        expect(
          () => SupabaseAuthClient.authorizationCodeFromCallback(
            callbackUri: callback,
            expectedRedirectUri: expected,
          ),
          throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
        );
      }
    },
  );

  test('callback accepts exactly one bounded code on an exact HTTPS port', () {
    final expected = Uri.parse('https://console.example:8443/auth/callback');
    final maximumCode = List.filled(2048, 'a').join();
    expect(
      SupabaseAuthClient.authorizationCodeFromCallback(
        callbackUri: Uri.parse(
          'https://console.example:8443/auth/callback'
          '?source=email&code=$maximumCode',
        ),
        expectedRedirectUri: expected,
      ),
      maximumCode,
    );
  });

  test('verified session identity is bound to the requested email', () {
    final session = SupabaseSession(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      expiresAtUtc: DateTime.utc(2026, 7, 29, 13),
      userId: 'user-1',
      email: 'Listener@Example.Test',
    );

    expect(
      SupabaseAuthClient.sessionMatchesRequestedEmail(
        session: session,
        requestedEmail: ' listener@example.test ',
      ),
      isTrue,
    );
    for (final requested in ['', 'attacker@example.test']) {
      expect(
        SupabaseAuthClient.sessionMatchesRequestedEmail(
          session: session,
          requestedEmail: requested,
        ),
        isFalse,
      );
    }
  });

  test('invalid PKCE verifiers fail before any network request', () async {
    var calls = 0;
    final client = SupabaseAuthClient(
      httpClient: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    for (final invalid in [
      'short',
      List.filled(129, 'a').join(),
      '${List.filled(42, 'a').join()}!',
      '${List.filled(42, 'a').join()} ',
    ]) {
      await expectLater(
        client.sendEmailOtp(
          config: config,
          email: 'user@example.com',
          codeVerifier: invalid,
          redirectTo: 'sonusauris://auth/callback',
        ),
        throwsA(isA<FormatException>()),
      );
    }
    expect(calls, 0);
  });

  test(
    'auth failures hide server details and malformed success fails closed',
    () async {
      final rejected = SupabaseAuthClient(
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'msg': 'internal rate-limit and account details'}),
            429,
          ),
        ),
      );
      await expectLater(
        rejected.verifyEmailOtp(
          config: config,
          email: 'user@example.com',
          code: '123456',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'That code was not accepted. Request a fresh one and try again.',
          ),
        ),
      );

      final malformed = SupabaseAuthClient(
        httpClient: MockClient((_) async => http.Response('[]', 200)),
      );
      await expectLater(
        malformed.exchangePkceCode(
          config: config,
          authorizationCode: 'authorization-code',
          codeVerifier: verifier,
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('refreshSession uses the refresh_token grant', () async {
    late http.Request captured;
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'access_token': 'access-3',
            'refresh_token': 'refresh-3',
            'expires_in': 3600,
          }),
          200,
        );
      }),
    );

    final session = await client.refreshSession(
      config: config,
      refreshToken: 'refresh-2',
    );

    expect(captured.url.queryParameters['grant_type'], 'refresh_token');
    expect(jsonDecode(captured.body)['refresh_token'], 'refresh-2');
    expect(session.accessToken, 'access-3');
  });

  test('rejects unsafe client keys and redirect URLs', () async {
    var calls = 0;
    final client = SupabaseAuthClient(
      httpClient: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );

    for (final unsafeConfig in [
      config.copyWith(supabaseUrl: 'https://user:secret@project.supabase.co'),
      config.copyWith(supabaseUrl: 'https://project.supabase.co?tenant=other'),
      config.copyWith(supabaseUrl: 'https://project.supabase.co#other'),
      config.copyWith(supabaseUrl: 'http://project.supabase.co'),
      config.copyWith(supabaseAnonKey: 'sb_secret_never-ship'),
    ]) {
      await expectLater(
        client.sendEmailOtp(
          config: unsafeConfig,
          email: 'user@example.com',
          codeVerifier: verifier,
          redirectTo: 'sonusauris://auth/callback',
        ),
        throwsA(isA<FormatException>()),
      );
    }
    for (final redirect in [
      'http://attacker.example/callback',
      'https://user:secret@console.example/auth/callback',
      'https://console.example/auth/callback?next=attacker',
      'https://console.example/auth/callback#token',
      'sonusauris://auth/callback/extra',
    ]) {
      await expectLater(
        client.sendEmailOtp(
          config: config,
          email: 'user@example.com',
          codeVerifier: verifier,
          redirectTo: redirect,
        ),
        throwsA(isA<FormatException>()),
      );
    }
    expect(calls, 0);
  });
}
