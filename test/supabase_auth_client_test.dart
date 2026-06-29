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

  test('signInWithPassword posts to GoTrue and parses the session', () async {
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

    final session = await client.signInWithPassword(
      config: config,
      email: 'user@example.com',
      password: 'hunter2',
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/auth/v1/token');
    expect(captured.url.queryParameters['grant_type'], 'password');
    // The anon key, never the service key, authorizes the request.
    expect(captured.headers['apikey'], 'anon-key-123');
    expect(captured.headers['authorization'], 'Bearer anon-key-123');
    expect(session.accessToken, 'access-1');
    expect(session.refreshToken, 'refresh-1');
    expect(session.email, 'user@example.com');
    expect(session.userId, 'user-1');
    expect(session.expiresAtUtc.isAfter(DateTime.now().toUtc()), isTrue);
  });

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

  test('sendPasswordResetEmail posts to GoTrue recover', () async {
    late http.Request captured;
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('{}', 200);
      }),
    );

    await client.sendPasswordResetEmail(
      config: config,
      email: 'user@example.com',
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/auth/v1/recover');
    expect(captured.headers['apikey'], 'anon-key-123');
    expect(captured.headers['authorization'], 'Bearer anon-key-123');
    expect(jsonDecode(captured.body)['email'], 'user@example.com');
  });

  test('signUp returns null when email confirmation is required', () async {
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        // Confirmation-required projects return the user but no session.
        return http.Response(
          jsonEncode({'id': 'user-1', 'email': 'user@example.com'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final session = await client.signUp(
      config: config,
      email: 'user@example.com',
      password: 'hunter2',
    );

    expect(session, isNull);
  });

  test('signUp returns a session when one is issued immediately', () async {
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
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

    final session = await client.signUp(
      config: config,
      email: 'user@example.com',
      password: 'hunter2',
    );

    expect(session, isNotNull);
    expect(session!.accessToken, 'access-1');
  });

  test('surfaces GoTrue error descriptions', () async {
    final client = SupabaseAuthClient(
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({'error_description': 'Invalid login credentials'}),
          400,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    expect(
      () => client.signInWithPassword(
        config: config,
        email: 'user@example.com',
        password: 'wrong',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Invalid login credentials',
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
      () => client.signInWithPassword(
        config: insecure,
        email: 'user@example.com',
        password: 'hunter2',
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
      () => client.signInWithPassword(
        config: unconfigured,
        email: 'user@example.com',
        password: 'hunter2',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
