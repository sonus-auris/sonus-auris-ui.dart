import 'dart:convert';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/supabase_session.dart';
import 'package:audio_dashcam/src/services/supabase_auth_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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

    await client.sendEmailOtp(config: config, email: '  user@example.com ');

    expect(captured.method, 'POST');
    expect(captured.url.path, '/auth/v1/otp');
    expect(
      captured.url.queryParameters['redirect_to'],
      'sonusauris://auth/callback',
    );
    // The anon key, never the service key, authorizes the request.
    expect(captured.headers['apikey'], 'anon-key-123');
    expect(captured.headers['authorization'], 'Bearer anon-key-123');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['email'], 'user@example.com');
    // create_user makes the same call the sign-up path: an unknown address is
    // created the moment its first code is verified.
    expect(body['create_user'], true);
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

      for (final invalidCode in ['   ', '12345', '1234567', '12x456']) {
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
      () => client.sendEmailOtp(config: insecure, email: 'user@example.com'),
      throwsA(isA<FormatException>()),
    );
  });

  test('requires Supabase URL and anon key to be configured', () async {
    const unconfigured = AppConfig(deviceId: 'device-a');
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async => http.Response('{}', 200)),
    );

    expect(
      () =>
          client.sendEmailOtp(config: unconfigured, email: 'user@example.com'),
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
      client.sendEmailOtp(config: config, email: 'not-an-email'),
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
      client.sendEmailOtp(config: unsafe, email: 'user@example.com'),
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
      client.sendEmailOtp(config: config, email: 'user@example.com'),
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
