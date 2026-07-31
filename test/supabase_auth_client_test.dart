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
  final access1 = _accessToken(subject: 'user-1');
  final access2 = _accessToken(subject: 'user-1');
  const config = AppConfig(
    deviceId: 'device-a',
    supabaseUrl: 'https://project.supabase.co',
    supabaseAnonKey: 'anon-key-123',
  );

  test('sendEmailOtp posts to GoTrue otp and enables sign-up', () async {
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
    // The anon key, never the service key, authorizes the request.
    expect(captured.headers['apikey'], 'anon-key-123');
    expect(captured.headers['authorization'], 'Bearer anon-key-123');
    // create_user makes the same call the sign-up path: an unknown address is
    // created the moment its first code is verified.
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

  test(
    'verifyEmailOtp posts to GoTrue verify and parses the session',
    () async {
      late http.Request captured;
      final client = SupabaseAuthClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'access_token': access1,
              'refresh_token': 'refresh-1',
              'expires_in': 3600,
              'user': {'id': 'user-1', 'email': 'user@example.com'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final session = await client.verifyEmailOtp(
        config: config,
        email: 'user@example.com',
        code: '123456',
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/auth/v1/verify');
      expect(captured.headers['apikey'], 'anon-key-123');
      expect(captured.headers['authorization'], 'Bearer anon-key-123');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['type'], 'email');
      expect(body['email'], 'user@example.com');
      expect(body['token'], '123456');
      expect(session.accessToken, access1);
      expect(session.refreshToken, 'refresh-1');
      expect(session.email, 'user@example.com');
      expect(session.userId, 'user-1');
      expect(session.expiresAtUtc.isAfter(DateTime.now().toUtc()), isTrue);
    },
  );

  test('consumeMagicLink accepts only the configured app callback', () async {
    final client = SupabaseAuthClient(
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    );
    final callback = Uri.parse(
      'sonusauris://auth/callback'
      '#access_token=$access1&refresh_token=refresh-1&expires_in=3600',
    );

    final session = await client.consumeMagicLink(
      config: config,
      callback: callback,
    );
    expect(session.accessToken, access1);
    expect(session.refreshToken, 'refresh-1');
    expect(
      () => client.consumeMagicLink(
        config: config,
        callback: callback.replace(host: 'another-app'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('magic-link PKCE code is exchanged without URL bearer tokens', () async {
    final accessOther = _accessToken(subject: 'user-2');
    late http.Request captured;
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'access_token': accessOther,
            'refresh_token': 'refresh-2',
            'expires_in': 1800,
            'user': {'id': 'user-2', 'email': 'user@example.com'},
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
    expect(session.accessToken, accessOther);
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
            'access_token': access2,
            'refresh_token': 'refresh-2',
            'expires_in': 3600,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final session = await client.refreshSession(
      config: config,
      refreshToken: 'refresh-1',
    );

    expect(captured.url.queryParameters['grant_type'], 'refresh_token');
    expect(jsonDecode(captured.body)['refresh_token'], 'refresh-1');
    expect(session.accessToken, access2);
    expect(session.refreshToken, 'refresh-2');
  });

  test(
    'verifyEmailOtp requires exactly six digits before making a request',
    () async {
      var called = false;
      final client = SupabaseAuthClient(
        httpClient: MockClient((request) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      for (final invalidCode in ['   ', '12345', '1234567', '12x456', '12345a']) {
        await expectLater(
          client.verifyEmailOtp(
            config: config,
            email: 'user@example.com',
            code: invalidCode,
          ),
          throwsA(isA<FormatException>()),
        );
      }
      expect(called, isFalse);
    },
  );

  test('rejects malformed, subjectless, and expired access tokens', () async {
    for (final token in [
      'not-a-jwt',
      _accessToken(subject: ''),
      _accessToken(subject: 'user-1', includeExpiry: false),
      _accessToken(
        subject: 'user-1',
        expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      ),
    ]) {
      final client = SupabaseAuthClient(
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'access_token': token, 'refresh_token': 'refresh-1'}),
            200,
          ),
        ),
      );
      await expectLater(
        client.verifyEmailOtp(
          config: config,
          email: 'user@example.com',
          code: '123456',
        ),
        throwsA(isA<StateError>()),
      );
    }
  });

  test(
    'rejects a response identity that disagrees with the JWT subject',
    () async {
      final client = SupabaseAuthClient(
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'access_token': _accessToken(subject: 'user-1'),
              'refresh_token': 'refresh-1',
              'user': {'id': 'user-2'},
            }),
            200,
          ),
        ),
      );

      await expectLater(
        client.verifyEmailOtp(
          config: config,
          email: 'user@example.com',
          code: '123456',
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('surfaces GoTrue error descriptions', () async {
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({'error_description': 'Token has expired or is invalid'}),
          400,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    expect(
      () => client.verifyEmailOtp(
        config: config,
        email: 'user@example.com',
        code: '000000',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Token has expired or is invalid',
        ),
      ),
    );
  });

  test('rejects non-HTTPS Supabase URLs', () async {
    const insecure = AppConfig(
      deviceId: 'device-a',
      supabaseUrl: 'http://project.supabase.co',
      supabaseAnonKey: 'anon-key-123',
    );
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async => http.Response('{}', 200)),
    );

    expect(
      () => client.sendEmailOtp(
        config: insecure,
        email: 'user@example.com',
        codeVerifier: verifier,
        redirectTo: 'sonusauris://auth/callback',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('requires Supabase URL and anon key to be configured', () async {
    const unconfigured = AppConfig(deviceId: 'device-a');
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async => http.Response('{}', 200)),
    );

    expect(
      () => client.sendEmailOtp(
        config: unconfigured,
        email: 'user@example.com',
        codeVerifier: verifier,
        redirectTo: 'sonusauris://auth/callback',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a malformed email without making a request', () async {
    var called = false;
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      client.sendEmailOtp(
        config: config,
        email: 'not-an-email',
        codeVerifier: verifier,
        redirectTo: 'sonusauris://auth/callback',
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      client.verifyEmailOtp(
        config: config,
        email: 'not-an-email',
        code: '123456',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(called, isFalse);
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

  test('rejects a service-role project key before making a request', () async {
    var called = false;
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );
    const unsafe = AppConfig(
      deviceId: 'device-a',
      supabaseUrl: 'https://project.supabase.co',
      supabaseAnonKey: 'sb_secret_never-ship',
    );

    await expectLater(
      client.sendEmailOtp(
        config: unsafe,
        email: 'user@example.com',
        codeVerifier: verifier,
        redirectTo: 'sonusauris://auth/callback',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('never a secret or service-role key'),
        ),
      ),
    );
    expect(called, isFalse);
  });

  test('uses a stable fallback for a non-JSON server error', () async {
    final client = SupabaseAuthClient(
      httpClient: MockClient(
        (request) async => http.Response('<html>bad gateway</html>', 502),
      ),
    );

    await expectLater(
      client.verifyEmailOtp(
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
  });

  test('turns request timeouts into a user-facing error', () async {
    final client = SupabaseAuthClient(
      requestTimeout: const Duration(milliseconds: 1),
      httpClient: MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      client.sendEmailOtp(
        config: config,
        email: 'user@example.com',
        codeVerifier: verifier,
        redirectTo: 'sonusauris://auth/callback',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('did not respond in time'),
        ),
      ),
    );
  });

  test('recognizes passwordless AAL2 and rejects password-backed MFA', () {
    final firstFactor = _accessToken(subject: 'user-1');
    final passwordless = _accessToken(
      subject: 'user-1',
      aal: 'aal2',
      methods: const ['otp', 'totp'],
    );
    final passwordBacked = _accessToken(
      subject: 'user-1',
      aal: 'aal2',
      methods: const ['password', 'totp'],
    );

    expect(supabaseJwtHasPasswordlessFirstFactor(firstFactor), isTrue);
    expect(supabaseJwtIsPasswordlessAal2(firstFactor), isFalse);
    expect(supabaseJwtIsPasswordlessAal2(passwordless), isTrue);
    expect(supabaseJwtHasPasswordlessFirstFactor(passwordBacked), isFalse);
    expect(supabaseJwtIsPasswordlessAal2(passwordBacked), isFalse);
    expect(supabaseJwtIsPasswordlessAal2('not-a-jwt'), isFalse);
  });
}

String _accessToken({
  required String subject,
  DateTime? expiresAt,
  String aal = 'aal1',
  List<String> methods = const ['otp'],
  bool includeExpiry = true,
}) {
  final header = base64Url.encode(utf8.encode('{"alg":"none","typ":"JWT"}'));
  final expiry =
      (expiresAt ?? DateTime.now().toUtc().add(const Duration(hours: 1)))
          .millisecondsSinceEpoch ~/
      1000;
  final payload = base64Url.encode(
    utf8.encode(
      jsonEncode({
        'sub': subject,
        'email': 'user@example.com',
        'aal': aal,
        'amr': methods.map((method) => {'method': method}).toList(),
        if (includeExpiry) 'exp': expiry,
      }),
    ),
  );
  return '$header.$payload.signature';
}
