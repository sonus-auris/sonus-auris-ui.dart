import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sonus_auris_console/src/config/console_config.dart';
import 'package:sonus_auris_console/src/models/supabase_session.dart';
import 'package:sonus_auris_console/src/services/auth_client.dart';
import 'package:sonus_auris_console/src/services/console_controller.dart';
import 'package:sonus_auris_console/src/services/device_service.dart';
import 'package:sonus_auris_console/src/services/entitlements_service.dart';
import 'package:sonus_auris_console/src/services/events_service.dart';
import 'package:sonus_auris_console/src/services/token_store.dart';

const _config = ConsoleConfig(
  supabaseUrl: 'https://project.supabase.co',
  supabaseAnonKey: 'sb_publishable_test',
  authRedirectUrl: 'https://console.example/auth/callback',
);

class FakeTokenStore implements TokenStore {
  FakeTokenStore([this._session]);
  SupabaseSession? _session;
  PendingMagicLink? _pending;

  @override
  Future<String> deviceInstallId() async => 'console-install-1';

  @override
  Future<SupabaseSession?> readSession() async => _session;

  @override
  Future<void> writeSession(SupabaseSession session) async =>
      _session = session;

  @override
  Future<void> clearSession() async => _session = null;

  @override
  Future<void> writePendingMagicLink(PendingMagicLink pending) async =>
      _pending = pending;

  @override
  Future<PendingMagicLink?> readPendingMagicLink() async => _pending;

  @override
  Future<void> clearPendingMagicLink() async => _pending = null;
}

String token({String aal = 'aal1', String email = 'a@example.test'}) {
  String seg(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'HS256'})}.${seg({'sub': 'user-1', 'email': email, 'aal': aal})}.sig';
}

String sessionJson({String aal = 'aal1', String email = 'a@example.test'}) =>
    jsonEncode({
      'access_token': token(aal: aal, email: email),
      'refresh_token': 'r',
      'expires_in': 3600,
      'user': {'id': 'user-1', 'email': email},
    });

/// A mock GoTrue + PostgREST backend routed by path. [factors] controls whether
/// the account has a verified MFA factor.
ConsoleController controllerWith({
  List<Map<String, Object?>> factors = const [],
  List<Map<String, Object?>> devices = const [],
  List<Map<String, Object?>> entitlements = const [],
  TokenStore? store,
  String authEmail = 'a@example.test',
  Duration tokenDelay = Duration.zero,
  List<String>? requests,
}) {
  final factorState = factors.map(Map<String, Object?>.from).toList();
  final client = MockClient((req) async {
    final path = req.url.path;
    requests?.add(path);
    if (path == '/auth/v1/otp') return http.Response('{}', 200);
    if (path == '/auth/v1/verify') {
      return http.Response(sessionJson(email: authEmail), 200);
    }
    if (path == '/auth/v1/token') {
      if (tokenDelay > Duration.zero) {
        await Future<void>.delayed(tokenDelay);
      }
      return http.Response(sessionJson(email: authEmail), 200);
    }
    if (path == '/auth/v1/user') {
      return http.Response(
        jsonEncode({'id': 'user-1', 'factors': factorState}),
        200,
      );
    }
    if (path == '/auth/v1/factors' && req.method == 'POST') {
      final body = jsonDecode(req.body) as Map<String, Object?>;
      final type = body['factor_type'] as String;
      final factor = <String, Object?>{
        'id': 'new-factor',
        'factor_type': type,
        'status': 'unverified',
        if (type == 'phone') 'phone': body['phone'],
      };
      factorState.add(factor);
      return http.Response(
        jsonEncode({
          ...factor,
          if (type == 'totp')
            'totp': {
              'secret': 'TOTPSECRET',
              'uri': 'otpauth://totp/SonusAuris:test',
            },
        }),
        200,
      );
    }
    if (path.startsWith('/auth/v1/factors/') && path.endsWith('/challenge')) {
      return http.Response(jsonEncode({'id': 'challenge-1'}), 200);
    }
    if (path.startsWith('/auth/v1/factors/') && path.endsWith('/verify')) {
      // A completed second factor yields a fresh aal2 session.
      for (final factor in factorState) {
        if (path.contains('/${factor['id']}/')) {
          factor['status'] = 'verified';
        }
      }
      return http.Response(sessionJson(aal: 'aal2', email: authEmail), 200);
    }
    if (path == '/rest/v1/devices') {
      if (req.method == 'GET') return http.Response(jsonEncode(devices), 200);
      return http.Response('', 201); // register self / mutations
    }
    if (path == '/rest/v1/entitlements') {
      return http.Response(jsonEncode(entitlements), 200);
    }
    if (path == '/rest/v1/acoustic_events') return http.Response('[]', 200);
    return http.Response('{}', 404);
  });
  return ConsoleController(
    config: _config,
    tokenStore: store ?? FakeTokenStore(),
    authClient: AuthClient(config: _config, httpClient: client),
    deviceService: DeviceService(config: _config, httpClient: client),
    entitlementsService: EntitlementsService(
      config: _config,
      httpClient: client,
    ),
    eventsService: EventsService(config: _config, httpClient: client),
  );
}

void main() {
  test('bootstrap with no stored session lands on signedOut', () async {
    final controller = controllerWith();
    await controller.bootstrap();
    expect(controller.phase, AuthPhase.signedOut);
  });

  test('sending an email code advances to the code step', () async {
    final controller = controllerWith();
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    expect(controller.phase, AuthPhase.codeSent);
    expect(controller.pendingEmail, 'a@example.test');
  });

  test('a new account must enroll MFA before any console data loads', () async {
    final controller = controllerWith(
      devices: [
        {
          'user_id': 'user-1',
          'device_id': 'phone-1',
          'display_name': 'Pixel',
          'platform': 'android',
          'role': 'recorder',
          'last_seen_at': '2026-07-17T00:00:00Z',
          'created_at': '2026-07-01T00:00:00Z',
        },
      ],
    );
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    await controller.verifyEmailCode('123456');
    expect(controller.phase, AuthPhase.mfaEnrollmentRequired);
    expect(controller.isSignedIn, isFalse);
    expect(controller.activeRecorderCount, 0);
  });

  test('a PKCE magic-link code signs in without URL bearer tokens', () async {
    final controller = controllerWith();
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    final accepted = await controller.acceptMagicLink(
      Uri.parse(
        'https://console.example/auth/callback?code=authorization-code',
      ),
    );

    expect(accepted, isTrue);
    expect(controller.phase, AuthPhase.mfaEnrollmentRequired);
    expect(controller.email, 'a@example.test');
  });

  test('an implicit-token callback is handled but never signs in', () async {
    final controller = controllerWith();
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');

    final handled = await controller.acceptMagicLink(
      Uri.parse(
        'https://console.example/auth/callback'
        '#access_token=${token()}&refresh_token=stolen',
      ),
    );

    expect(handled, isTrue);
    expect(controller.isSignedIn, isFalse);
    expect(controller.message, contains('older sign-in link'));
  });

  test('magic-link identity must match the requesting email', () async {
    final store = FakeTokenStore();
    final requests = <String>[];
    final controller = controllerWith(
      store: store,
      authEmail: 'attacker@example.test',
      requests: requests,
    );
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');

    final handled = await controller.acceptMagicLink(
      Uri.parse(
        'https://console.example/auth/callback?code=authorization-code',
      ),
    );

    expect(handled, isTrue);
    expect(controller.isSignedIn, isFalse);
    expect(controller.message, contains('did not match'));
    expect(await store.readSession(), isNull);
    expect(await store.readPendingMagicLink(), isNull);
    expect(requests, contains('/auth/v1/logout'));
  });

  test('email-code identity must match the submitted email', () async {
    final store = FakeTokenStore();
    final requests = <String>[];
    final controller = controllerWith(
      store: store,
      authEmail: 'attacker@example.test',
      requests: requests,
    );
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    await controller.verifyEmailCode('123456');

    expect(controller.isSignedIn, isFalse);
    expect(controller.message, contains('did not match'));
    expect(await store.readSession(), isNull);
    expect(requests, contains('/auth/v1/logout'));
  });

  test('expired pending state is cleared before any PKCE exchange', () async {
    final store = FakeTokenStore();
    final requests = <String>[];
    final controller = controllerWith(store: store, requests: requests);
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    store._pending = PendingMagicLink(
      codeVerifier: store._pending!.codeVerifier,
      email: 'a@example.test',
      supabaseUrl: _config.supabaseUrl,
      redirectUrl: _config.authRedirectUrl,
      requestedAtUtc: DateTime.now().toUtc().subtract(
        const Duration(minutes: 16),
      ),
    );

    expect(
      await controller.acceptMagicLink(
        Uri.parse(
          'https://console.example/auth/callback?code=authorization-code',
        ),
      ),
      isTrue,
    );
    expect(controller.isSignedIn, isFalse);
    expect(controller.message, contains('expired'));
    expect(await store.readPendingMagicLink(), isNull);
    expect(requests.where((path) => path == '/auth/v1/token'), isEmpty);
  });

  test('simultaneous callback delivery performs one PKCE exchange', () async {
    final requests = <String>[];
    final controller = controllerWith(
      requests: requests,
      tokenDelay: const Duration(milliseconds: 25),
    );
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    final callback = Uri.parse(
      'https://console.example/auth/callback?code=authorization-code',
    );

    final first = controller.acceptMagicLink(callback);
    final second = controller.acceptMagicLink(callback);

    expect(await second, isTrue);
    expect(await first, isTrue);
    expect(controller.phase, AuthPhase.mfaEnrollmentRequired);
    expect(requests.where((path) => path == '/auth/v1/token'), hasLength(1));
  });

  test('verifying a newly enrolled factor is required before entry', () async {
    final controller = controllerWith();
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    await controller.verifyEmailCode('123456');

    final enrollment = await controller.enrollTotp(name: 'Authenticator');
    expect(enrollment, isNotNull);
    final challenge = await controller.startFactorChallenge(
      enrollment!.factorId,
    );
    expect(challenge, isNotNull);
    final verified = await controller.confirmFactorEnrollment(
      factorId: enrollment.factorId,
      challengeId: challenge!,
      code: '123456',
    );

    expect(verified, isTrue);
    expect(controller.phase, AuthPhase.signedIn);
    expect(controller.isSignedIn, isTrue);
  });

  test('a verified factor forces the MFA challenge before entering', () async {
    final controller = controllerWith(
      factors: [
        {'id': 'f1', 'factor_type': 'totp', 'status': 'verified'},
      ],
    );
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    await controller.verifyEmailCode('123456');
    expect(controller.phase, AuthPhase.mfaRequired);
    expect(controller.pendingChallengeFactor?.id, 'f1');
  });

  test('completing the MFA challenge enters the console', () async {
    final controller = controllerWith(
      factors: [
        {'id': 'f1', 'factor_type': 'totp', 'status': 'verified'},
      ],
    );
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    await controller.verifyEmailCode('123456');
    await controller.beginMfaChallenge('f1');
    // verify returns a fresh aal2 session from the mock, clearing the gate.
    await controller.submitMfaChallenge('123456');
    expect(controller.phase, AuthPhase.signedIn);
  });

  test('over-limit recorders are locked at the free tier of 2', () async {
    final controller = controllerWith(
      factors: [
        {'id': 'f1', 'factor_type': 'totp', 'status': 'verified'},
      ],
      devices: [
        for (var i = 0; i < 3; i++)
          {
            'user_id': 'user-1',
            'device_id': 'd$i',
            'display_name': 'Device $i',
            'platform': 'android',
            'role': 'recorder',
            'last_seen_at': '2026-07-1${i}T00:00:00Z',
            'created_at': '2026-07-01T00:00:00Z',
          },
      ],
    );
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    await controller.verifyEmailCode('123456');
    await controller.beginMfaChallenge('f1');
    await controller.submitMfaChallenge('123456');
    expect(controller.activeRecorderCount, 3);
    expect(controller.lockedDeviceIds, hasLength(1)); // 1 over the limit of 2
  });

  test('sign-out returns to the signedOut phase and clears data', () async {
    final controller = controllerWith();
    await controller.bootstrap();
    await controller.sendEmailCode('a@example.test');
    await controller.verifyEmailCode('123456');
    await controller.signOut();
    expect(controller.phase, AuthPhase.signedOut);
    expect(controller.devices, isEmpty);
  });
}
