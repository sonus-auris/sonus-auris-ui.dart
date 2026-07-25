import 'dart:convert';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/services/supabase_auth_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
              'access_token': 'access-1',
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
      expect(session.accessToken, 'access-1');
      expect(session.refreshToken, 'refresh-1');
      expect(session.email, 'user@example.com');
      expect(session.userId, 'user-1');
      expect(session.expiresAtUtc.isAfter(DateTime.now().toUtc()), isTrue);
    },
  );

  test('refreshSession uses the refresh_token grant', () async {
    late http.Request captured;
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'access_token': 'access-2',
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
    expect(session.accessToken, 'access-2');
    expect(session.refreshToken, 'refresh-2');
  });

  test('verifyEmailOtp rejects an empty code before making a request', () async {
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
        code: '   ',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(called, isFalse);
  });

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
      () => client.sendEmailOtp(config: unconfigured, email: 'user@example.com'),
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
}
