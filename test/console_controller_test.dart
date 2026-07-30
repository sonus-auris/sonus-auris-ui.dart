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
);

class FakeTokenStore implements TokenStore {
  FakeTokenStore([this._session]);
  SupabaseSession? _session;

  @override
  Future<String> deviceInstallId() async => 'console-install-1';

  @override
  Future<SupabaseSession?> readSession() async => _session;

  @override
  Future<void> writeSession(SupabaseSession session) async =>
      _session = session;

  @override
  Future<void> clearSession() async => _session = null;
}

String token({String aal = 'aal1', List<String>? methods}) {
  String seg(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final authenticationMethods = methods ?? ['otp', if (aal == 'aal2') 'totp'];
  return '${seg({'alg': 'HS256'})}.${seg({
    'sub': 'user-1',
    'email': 'a@example.test',
    'aal': aal,
    'exp': DateTime.now().toUtc().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    'amr': [
      for (final method in authenticationMethods) {'method': method},
    ],
  })}.sig';
}

String sessionJson({String aal = 'aal1'}) => jsonEncode({
  'access_token': token(aal: aal),
  'refresh_token': 'r',
  'expires_in': 3600,
  'user': {'id': 'user-1', 'email': 'a@example.test'},
});

/// A mock GoTrue + PostgREST backend routed by path. [factors] controls whether
/// the account has a verified MFA factor.
ConsoleController controllerWith({
  List<Map<String, Object?>> factors = const [],
  List<Map<String, Object?>> devices = const [],
  List<Map<String, Object?>> entitlements = const [],
  TokenStore? store,
}) {
  final client = MockClient((req) async {
    final path = req.url.path;
    if (path == '/auth/v1/otp') return http.Response('{}', 200);
    if (path == '/auth/v1/verify') return http.Response(sessionJson(), 200);
    if (path == '/auth/v1/token') return http.Response(sessionJson(), 200);
    if (path == '/auth/v1/user') {
      return http.Response(
        jsonEncode({'id': 'user-1', 'factors': factors}),
        200,
      );
    }
    if (path.startsWith('/auth/v1/factors/') && path.endsWith('/challenge')) {
      return http.Response(jsonEncode({'id': 'challenge-1'}), 200);
    }
    if (path.startsWith('/auth/v1/factors/') && path.endsWith('/verify')) {
      // A completed second factor yields a fresh aal2 session.
      return http.Response(sessionJson(aal: 'aal2'), 200);
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

  test(
    'verifying a code with no MFA requires enrollment and loads no data',
    () async {
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
      expect(controller.entitlement.deviceLimit, 2); // free default, no row
    },
  );

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

  test('password-backed AAL2 never enters the console', () async {
    final storedSession = SupabaseSession(
      accessToken: token(aal: 'aal2', methods: const ['password', 'totp']),
      refreshToken: 'r',
      expiresAtUtc: DateTime.now().toUtc().add(const Duration(hours: 1)),
      userId: 'user-1',
      email: 'a@example.test',
    );
    final store = FakeTokenStore(storedSession);
    final controller = controllerWith(
      factors: [
        {'id': 'f1', 'factor_type': 'totp', 'status': 'verified'},
      ],
      store: store,
    );

    await controller.bootstrap();

    expect(controller.phase, AuthPhase.signedOut);
    expect(controller.isSignedIn, isFalse);
    expect(await store.readSession(), isNull);
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
