import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:audio_dashcam/src/models/app_config.dart';

import '../integration_test/support/shared_auth_test_client.dart';

const _email = 'android@automation.example';
const _supabaseUrl = 'https://project-test.supabase.co';
const _config = AppConfig(
  deviceId: 'shared-auth-test-client',
  supabaseUrl: _supabaseUrl,
  supabaseAnonKey: 'public-anon-key',
);

void main() {
  test('request is email-free and verification returns genuine AAL1', () async {
    var requestCount = 0;
    final transport = MockClient((request) async {
      requestCount += 1;
      expect(request.method, 'POST');
      expect(request.url, Uri.parse('https://bridge.automation.test/session'));
      expect(request.headers['authorization'], isNull);
      expect(request.headers['content-type'], 'application/json');
      expect(jsonDecode(request.body), {
        'email': _email,
        'code': '424242',
        'assurance': 'aal1',
      });
      return http.Response(
        jsonEncode(_sessionPayload()),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = SharedAuthTestClient(
      bridgeUrl: 'https://bridge.automation.test/session',
      httpClient: transport,
    );
    addTearDown(client.close);

    await client.sendEmailOtp(
      config: _config,
      email: _email,
      codeVerifier: 'unused-by-the-isolated-test-client',
    );
    expect(requestCount, 0, reason: 'deterministic login must send no email');

    final session = await client.verifyEmailOtp(
      config: _config,
      email: _email,
      code: '424242',
    );
    expect(requestCount, 1);
    expect(session.email, _email);
    expect(session.userId, '00000000-0000-4000-8000-000000000001');
    expect(session.refreshToken, 'rotating-refresh-token');
    expect(session.hasPasswordlessFirstFactor, isTrue);
    expect(session.aal, 'aal1');
    expect(session.isPasswordlessAal2, isFalse);
  });

  test('424242 completes a genuine TOTP-shaped AAL2 exchange', () async {
    final requests = <Map<String, Object?>>[];
    final client = SharedAuthTestClient(
      bridgeUrl: 'https://bridge.automation.test/session',
      httpClient: MockClient((request) async {
        final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
        requests.add(body);
        return http.Response(
          jsonEncode(
            body['assurance'] == 'aal1'
                ? _sessionPayload()
                : _sessionPayload(aal: 'aal2', secondMethod: 'totp'),
          ),
          200,
        );
      }),
    );
    addTearDown(client.close);
    final aal1 = await client.verifyEmailOtp(
      config: _config,
      email: _email,
      code: SharedAuthTestClient.testCode,
    );
    final enrollment = await client.enrollTotp(
      config: _config,
      accessToken: aal1.accessToken,
      friendlyName: 'browser authenticator',
    );
    expect(enrollment.secret, isNotEmpty);
    expect(enrollment.uri, startsWith('otpauth://totp/'));
    final challenge = await client.challengeFactor(
      config: _config,
      accessToken: aal1.accessToken,
      factorId: enrollment.factorId,
    );

    await expectLater(
      client.verifyFactor(
        config: _config,
        accessToken: aal1.accessToken,
        factorId: enrollment.factorId,
        challengeId: challenge,
        code: '424241',
      ),
      throwsStateError,
    );
    final aal2 = await client.verifyFactor(
      config: _config,
      accessToken: aal1.accessToken,
      factorId: enrollment.factorId,
      challengeId: challenge,
      code: SharedAuthTestClient.testCode,
    );
    expect(aal2.isPasswordlessAal2, isTrue);
    expect(requests.last, {
      'email': _email,
      'code': '424242',
      'assurance': 'aal2_totp',
    });
    final factors = await client.listFactors(
      config: _config,
      accessToken: aal2.accessToken,
    );
    expect(factors, hasLength(1));
    expect(factors.single.isTotp, isTrue);
    expect(factors.single.isVerified, isTrue);
  });

  test('424242 completes a genuine phone-shaped AAL2 exchange', () async {
    final requests = <Map<String, Object?>>[];
    final client = SharedAuthTestClient(
      bridgeUrl: 'https://bridge.automation.test/session',
      httpClient: MockClient((request) async {
        final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
        requests.add(body);
        return http.Response(
          jsonEncode(
            body['assurance'] == 'aal1'
                ? _sessionPayload()
                : _sessionPayload(aal: 'aal2', secondMethod: 'mfa/phone'),
          ),
          200,
        );
      }),
    );
    addTearDown(client.close);
    final aal1 = await client.verifyEmailOtp(
      config: _config,
      email: _email,
      code: SharedAuthTestClient.testCode,
    );
    final enrollment = await client.enrollPhone(
      config: _config,
      accessToken: aal1.accessToken,
      phone: '+15005550006',
      friendlyName: 'browser phone',
    );
    final challenge = await client.challengeFactor(
      config: _config,
      accessToken: aal1.accessToken,
      factorId: enrollment.factorId,
    );
    final aal2 = await client.verifyFactor(
      config: _config,
      accessToken: aal1.accessToken,
      factorId: enrollment.factorId,
      challengeId: challenge,
      code: SharedAuthTestClient.testCode,
    );
    expect(aal2.isPasswordlessAal2, isTrue);
    expect(requests.last, {
      'email': _email,
      'code': '424242',
      'assurance': 'aal2_phone',
      'phone': '+15005550006',
    });
    final factors = await client.listFactors(
      config: _config,
      accessToken: aal2.accessToken,
    );
    expect(factors.single.isPhone, isTrue);
    expect(factors.single.phone, '+15005550006');
    expect(factors.single.isVerified, isTrue);
  });

  test('bridge and identity inputs fail closed', () async {
    final transport = MockClient((_) async => throw StateError('no request'));
    expect(
      () => SharedAuthTestClient(
        bridgeUrl: 'http://bridge.automation.test/session',
        httpClient: transport,
      ),
      throwsFormatException,
    );
    expect(
      () => SharedAuthTestClient(
        bridgeUrl: 'https://bridge.automation.test/other',
        httpClient: transport,
      ),
      throwsFormatException,
    );

    final client = SharedAuthTestClient(
      bridgeUrl: 'http://127.0.0.1:41842/session',
      httpClient: transport,
    );
    addTearDown(client.close);
    await expectLater(
      client.sendEmailOtp(
        config: _config,
        email: 'person@sonusauris.app',
        codeVerifier: 'unused',
      ),
      throwsFormatException,
    );
    await expectLater(
      client.verifyEmailOtp(config: _config, email: _email, code: '42424x'),
      throwsFormatException,
    );
  });

  test('issuer, audience, factor and assurance claims are exact', () async {
    Future<void> expectRejected(Map<String, Object?> payload) async {
      final client = SharedAuthTestClient(
        bridgeUrl: 'https://bridge.automation.test/session',
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode(payload), 200),
        ),
      );
      try {
        await expectLater(
          client.verifyEmailOtp(config: _config, email: _email, code: '424242'),
          throwsFormatException,
        );
      } finally {
        client.close();
      }
    }

    await expectRejected(
      _sessionPayload(issuer: 'https://other.supabase.co/auth/v1'),
    );
    await expectRejected(_sessionPayload(audience: 'service_role'));
    await expectRejected(_sessionPayload(aal: 'aal2'));
    await expectRejected(_sessionPayload(method: 'password'));
    await expectRejected(_sessionPayload(email: 'other@automation.example'));
  });

  test('upstream errors and oversized responses remain generic', () async {
    final rejected = SharedAuthTestClient(
      bridgeUrl: 'https://bridge.automation.test/session',
      httpClient: MockClient(
        (_) async => http.Response('sensitive upstream detail', 401),
      ),
    );
    addTearDown(rejected.close);
    await expectLater(
      rejected.verifyEmailOtp(config: _config, email: _email, code: '424242'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'The isolated test sign-in was not accepted.',
        ),
      ),
    );

    final oversized = SharedAuthTestClient(
      bridgeUrl: 'https://bridge.automation.test/session',
      httpClient: MockClient(
        (_) async => http.Response('x' * (256 * 1024 + 1), 200),
      ),
    );
    addTearDown(oversized.close);
    await expectLater(
      oversized.verifyEmailOtp(config: _config, email: _email, code: '424242'),
      throwsA(isA<StateError>()),
    );
  });
}

Map<String, Object?> _sessionPayload({
  String issuer = '$_supabaseUrl/auth/v1',
  String audience = 'authenticated',
  String aal = 'aal1',
  String method = 'otp',
  String? secondMethod,
  String email = _email,
}) {
  const userId = '00000000-0000-4000-8000-000000000001';
  final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 1));
  final accessToken = _jwt({
    'iss': issuer,
    'aud': audience,
    'exp': expiresAt.millisecondsSinceEpoch ~/ 1000,
    'sub': userId,
    'email': email,
    'role': 'authenticated',
    'aal': aal,
    'amr': [
      {
        'method': method,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      if (secondMethod != null)
        {
          'method': secondMethod,
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
    ],
  });
  return {
    'access_token': accessToken,
    'refresh_token': 'rotating-refresh-token',
    'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
    'user': {'id': userId, 'email': email},
  };
}

String _jwt(Map<String, Object?> claims) =>
    '${_segment({'alg': 'RS256', 'typ': 'JWT'})}.${_segment(claims)}.signature';

String _segment(Object value) =>
    base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
