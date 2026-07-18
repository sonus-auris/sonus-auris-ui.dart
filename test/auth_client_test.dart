import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sonus_auris_console/src/config/console_config.dart';
import 'package:sonus_auris_console/src/services/auth_client.dart';

const _config = ConsoleConfig(
  supabaseUrl: 'https://project.supabase.co',
  supabaseAnonKey: 'sb_publishable_test',
);

String sessionBody({String aal = 'aal1'}) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256"}')).replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode('{"sub":"user-1","email":"a@example.test","aal":"$aal"}'))
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
  test('sendEmailOtp posts to /auth/v1/otp with create_user and the anon key', () async {
    late http.Request captured;
    final client = AuthClient(
      config: _config,
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response('{}', 200);
      }),
    );
    await client.sendEmailOtp('a@example.test');
    expect(captured.url.path, '/auth/v1/otp');
    expect(captured.headers['apikey'], 'sb_publishable_test');
    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['email'], 'a@example.test');
    expect(body['create_user'], true);
  });

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
    final session = await client.verifyEmailOtp(email: 'a@example.test', code: '123456');
    expect(session.userId, 'user-1');
    expect(session.email, 'a@example.test');
    expect(session.aal, 'aal1');
    expect(session.refreshToken, 'refresh-1');
  });

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

  test('a GoTrue error message surfaces to the caller', () async {
    final client = AuthClient(
      config: _config,
      httpClient: MockClient((req) async {
        return http.Response(jsonEncode({'msg': 'Token has expired'}), 401);
      }),
    );
    expect(
      () => client.verifyEmailOtp(email: 'a@example.test', code: '000000'),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('expired'))),
    );
  });

  test('MFA: enrollTotp returns the shared secret and challenge id flows', () async {
    final client = AuthClient(
      config: _config,
      httpClient: MockClient((req) async {
        if (req.url.path == '/auth/v1/factors') {
          return http.Response(
            jsonEncode({
              'id': 'factor-1',
              'totp': {'secret': 'BASE32SECRET', 'uri': 'otpauth://totp/x', 'qr_code': '<svg/>'},
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final enrollment = await client.enrollTotp('token', friendlyName: 'Authy');
    expect(enrollment.factorId, 'factor-1');
    expect(enrollment.secret, 'BASE32SECRET');
    expect(enrollment.uri, 'otpauth://totp/x');
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
      ),
      httpClient: MockClient((req) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      () => client.sendEmailOtp('a@example.test'),
      throwsA(isA<FormatException>()),
    );
    expect(called, isFalse);
  });
}
