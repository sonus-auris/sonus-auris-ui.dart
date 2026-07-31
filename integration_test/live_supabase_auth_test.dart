import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_dashcam/main.dart';
import 'package:audio_dashcam/src/app/app_controller.dart';
import 'package:audio_dashcam/src/services/settings_store.dart';
import 'package:audio_dashcam/src/services/supabase_key_policy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const _uiEmail = String.fromEnvironment('SONUS_TEST_UI_EMAIL');
const _mailpitUrl = String.fromEnvironment('SONUS_TEST_MAILPIT_URL');
const _email = String.fromEnvironment('SONUS_TEST_EMAIL');
const _otp = String.fromEnvironment('SONUS_TEST_EMAIL_OTP');
const _otherEmail = String.fromEnvironment('SONUS_TEST_EMAIL_B');
const _otherOtp = String.fromEnvironment('SONUS_TEST_EMAIL_OTP_B');
const _supabaseUrl = String.fromEnvironment('SONUS_SUPABASE_URL');
const _supabaseKey = String.fromEnvironment('SONUS_SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'live Supabase email OTP reaches the authenticated account state',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final secureValues = _MemorySecretValueStore();
      await tester.pumpWidget(
        AudioDashcamRoot(
          controllerFactory: () => AppController(
            settingsStore: SettingsStore(secretValueStore: secureValues),
          ),
        ),
      );

      await _pumpUntil(
        tester,
        find.text('Welcome to Sonus Auris'),
        timeout: const Duration(seconds: 90),
      );
      await tester.tap(find.text('Continue'));

      final emailField = find.byKey(const ValueKey('supabase-email-field'));
      final sendLinkButton = find.byKey(
        const ValueKey('supabase-send-link-button'),
      );
      await _pumpUntilEnabled(tester, sendLinkButton);

      await tester.enterText(emailField, _uiEmail);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.ensureVisible(sendLinkButton);
      await tester.pump();
      await tester.tap(sendLinkButton);
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('supabase-code-field')),
      );
      final uiOtp = await _waitForLocalEmailOtp(_uiEmail);
      await tester.enterText(
        find.byKey(const ValueKey('supabase-code-field')),
        uiOtp,
      );
      final verifyButton = find.byKey(
        const ValueKey('supabase-verify-code-button'),
      );
      await tester.ensureVisible(verifyButton);
      await tester.pump();
      await tester.tap(verifyButton);

      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('mandatory-mfa-totp-button')),
        timeout: const Duration(seconds: 60),
      );
      await tester.tap(find.byKey(const ValueKey('mandatory-mfa-totp-button')));
      final secretFinder = find.byKey(
        const ValueKey('mandatory-mfa-totp-secret'),
      );
      await _pumpUntil(tester, secretFinder);
      final secret = tester.widget<SelectableText>(secretFinder).data;
      expect(secret, isNotNull);
      await tester.enterText(
        find.byKey(const ValueKey('mandatory-mfa-code-field')),
        _currentTotp(secret!),
      );
      final mfaVerify = find.byKey(
        const ValueKey('mandatory-mfa-enrollment-verify-button'),
      );
      await tester.ensureVisible(mfaVerify);
      await tester.pump();
      await tester.tap(mfaVerify);

      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('onboarding-signed-in-state')),
        timeout: const Duration(seconds: 60),
      );
      expect(find.text('Signed in'), findsOneWidget);
      expect(find.textContaining(_uiEmail), findsOneWidget);
    },
    // This test is opt-in because it targets a real Supabase project. Supply
    // the email and freshly received OTP as dart-defines.
    skip: _uiEmail.isEmpty || _mailpitUrl.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'live Supabase keeps two authenticated users isolated by RLS',
    () async {
      requireSafeSupabaseClientKey(_supabaseKey);
      final first = await _verifyOtp(_email, _otp);
      final second = await _verifyOtp(_otherEmail, _otherOtp);
      expect(first.userId, isNot(second.userId));

      final firstEvent = const Uuid().v4();
      final secondEvent = const Uuid().v4();
      var assertionsCompleted = false;
      try {
        await _insertAcousticEvent(first, firstEvent, 'rls-user-a');
        await _insertAcousticEvent(second, secondEvent, 'rls-user-b');

        expect(await _visibleEventIds(first), contains(firstEvent));
        expect(await _visibleEventIds(first), isNot(contains(secondEvent)));
        expect(await _visibleEventIds(second), contains(secondEvent));
        expect(await _visibleEventIds(second), isNot(contains(firstEvent)));

        final crossUserUpdate = await http.patch(
          _restUri('acoustic_events?id=eq.$firstEvent'),
          headers: _headers(second, prefer: 'return=representation'),
          body: jsonEncode({'kind': 'cross-user-write'}),
        );
        expect(crossUserUpdate.statusCode, 200);
        expect(jsonDecode(crossUserUpdate.body), isEmpty);

        final ownerSpoof = await http.post(
          _restUri('acoustic_events'),
          headers: _headers(second, prefer: 'return=representation'),
          body: jsonEncode(
            _eventRow(const Uuid().v4(), 'owner-spoof')
              ..['user_id'] = first.userId,
          ),
        );
        expect(ownerSpoof.statusCode, anyOf(401, 403));

        final firstRows = await _visibleEvents(first, id: firstEvent);
        expect(firstRows.single['kind'], 'rls-user-a');
        assertionsCompleted = true;
      } finally {
        final cleanupResponses = await Future.wait([
          _deleteAcousticEvent(first, firstEvent),
          _deleteAcousticEvent(second, secondEvent),
        ]);
        if (assertionsCompleted) {
          for (final response in cleanupResponses) {
            expect(
              response.statusCode,
              204,
              reason: 'live RLS fixture cleanup failed',
            );
          }
        }
      }
    },
    skip:
        _email.isEmpty ||
        _otp.isEmpty ||
        _otherEmail.isEmpty ||
        _otherOtp.isEmpty ||
        _supabaseUrl.isEmpty ||
        _supabaseKey.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

final class _MemorySecretValueStore implements SecretValueStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}

Future<String> _waitForLocalEmailOtp(String email) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  final mailbox = _mailpitUrl.replaceFirst(RegExp(r'/+$'), '');
  while (DateTime.now().isBefore(deadline)) {
    final response = await http.get(Uri.parse('$mailbox/api/v1/messages'));
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>? ?? const [];
      for (final candidate in messages.whereType<Map<String, dynamic>>()) {
        final recipients = candidate['To'] as List<dynamic>? ?? const [];
        final matchesRecipient = recipients
            .whereType<Map<String, dynamic>>()
            .any(
              (recipient) =>
                  (recipient['Address'] as String?)?.toLowerCase() ==
                  email.toLowerCase(),
            );
        if (!matchesRecipient) continue;
        final snippet = candidate['Snippet'] as String? ?? '';
        final code = RegExp(r'\b\d{6}\b').firstMatch(snippet)?.group(0);
        if (code != null) {
          return code;
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError('Timed out waiting for the local passwordless email.');
}

class _LiveSession {
  const _LiveSession({required this.userId, required this.accessToken});

  final String userId;
  final String accessToken;
}

Future<_LiveSession> _verifyOtp(String email, String otp) async {
  final response = await http.post(
    Uri.parse(
      '${_supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/auth/v1/verify',
    ),
    headers: {'apikey': _supabaseKey, 'Content-Type': 'application/json'},
    body: jsonEncode({'type': 'email', 'email': email, 'token': otp}),
  );
  expect(
    response.statusCode,
    200,
    reason: 'live Supabase OTP verification failed',
  );
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final user = body['user'] as Map<String, dynamic>;
  final aal1 = _LiveSession(
    userId: user['id'] as String,
    accessToken: body['access_token'] as String,
  );
  return _enrollAndVerifyTotp(aal1);
}

Future<_LiveSession> _enrollAndVerifyTotp(_LiveSession aal1) async {
  final enrollmentResponse = await http.post(
    Uri.parse(
      '${_supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/auth/v1/factors',
    ),
    headers: _headers(aal1),
    body: jsonEncode({'factor_type': 'totp', 'friendly_name': 'Live RLS test'}),
  );
  expect(enrollmentResponse.statusCode, 200);
  final enrollment =
      jsonDecode(enrollmentResponse.body) as Map<String, dynamic>;
  final factorId = enrollment['id'] as String;
  final totp = enrollment['totp'] as Map<String, dynamic>;

  final challengeResponse = await http.post(
    Uri.parse(
      '${_supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/auth/v1/factors/'
      '$factorId/challenge',
    ),
    headers: _headers(aal1),
    body: '{}',
  );
  expect(challengeResponse.statusCode, 200);
  final challenge = jsonDecode(challengeResponse.body) as Map<String, dynamic>;

  final verifyResponse = await http.post(
    Uri.parse(
      '${_supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/auth/v1/factors/'
      '$factorId/verify',
    ),
    headers: _headers(aal1),
    body: jsonEncode({
      'challenge_id': challenge['id'],
      'code': _currentTotp(totp['secret'] as String),
    }),
  );
  expect(verifyResponse.statusCode, 200);
  final verified = jsonDecode(verifyResponse.body) as Map<String, dynamic>;
  return _LiveSession(
    userId: aal1.userId,
    accessToken: verified['access_token'] as String,
  );
}

String _currentTotp(String secret) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var bits = '';
  for (final character in secret.replaceAll('=', '').toUpperCase().split('')) {
    final index = alphabet.indexOf(character);
    if (index < 0) {
      throw FormatException('Invalid base32 TOTP secret.');
    }
    bits += index.toRadixString(2).padLeft(5, '0');
  }
  final secretBytes = <int>[];
  for (var offset = 0; offset + 8 <= bits.length; offset += 8) {
    secretBytes.add(int.parse(bits.substring(offset, offset + 8), radix: 2));
  }
  final counter = DateTime.now().millisecondsSinceEpoch ~/ 30000;
  final counterBytes = ByteData(8)..setUint64(0, counter);
  final digest = Hmac(
    sha1,
    secretBytes,
  ).convert(counterBytes.buffer.asUint8List()).bytes;
  final offset = digest.last & 0x0f;
  final binary =
      ((digest[offset] & 0x7f) << 24) |
      ((digest[offset + 1] & 0xff) << 16) |
      ((digest[offset + 2] & 0xff) << 8) |
      (digest[offset + 3] & 0xff);
  return (binary % 1000000).toString().padLeft(6, '0');
}

Map<String, String> _headers(_LiveSession session, {String? prefer}) {
  final headers = {
    'apikey': _supabaseKey,
    'Authorization': 'Bearer ${session.accessToken}',
    'Content-Type': 'application/json',
  };
  if (prefer case final value?) {
    headers['Prefer'] = value;
  }
  return headers;
}

Uri _restUri(String path) =>
    Uri.parse('${_supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/rest/v1/$path');

Map<String, dynamic> _eventRow(String id, String kind) {
  final startedAt = DateTime.now().toUtc();
  return {
    'id': id,
    'device_id': 'live-rls-test',
    'kind': kind,
    'started_at': startedAt.toIso8601String(),
    'ended_at': startedAt.add(const Duration(seconds: 1)).toIso8601String(),
    'confidence': 1.0,
    'details': {'fixture': 'live-two-user-rls'},
  };
}

Future<void> _insertAcousticEvent(
  _LiveSession session,
  String id,
  String kind,
) async {
  final response = await http.post(
    _restUri('acoustic_events'),
    headers: _headers(session, prefer: 'return=representation'),
    body: jsonEncode(_eventRow(id, kind)),
  );
  expect(response.statusCode, 201, reason: 'live RLS fixture insert failed');
}

Future<List<Map<String, dynamic>>> _visibleEvents(
  _LiveSession session, {
  String? id,
}) async {
  final query = id == null
      ? 'acoustic_events?select=id,kind'
      : 'acoustic_events?id=eq.$id&select=id,kind';
  final response = await http.get(_restUri(query), headers: _headers(session));
  expect(response.statusCode, 200, reason: 'live RLS fixture query failed');
  return (jsonDecode(response.body) as List<dynamic>)
      .cast<Map<String, dynamic>>();
}

Future<Set<String>> _visibleEventIds(_LiveSession session) async =>
    (await _visibleEvents(session)).map((row) => row['id'] as String).toSet();

Future<http.Response> _deleteAcousticEvent(_LiveSession session, String id) =>
    http.delete(
      _restUri('acoustic_events?id=eq.$id'),
      headers: _headers(session),
    );

Future<void> _pumpUntilEnabled(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty &&
        tester.widget<FilledButton>(finder).onPressed != null) {
      return;
    }
  }
  fail('Timed out waiting for the live-auth form to become enabled.');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    final startupError = find.byType(ErrorPage);
    if (startupError.evaluate().isNotEmpty) {
      final page = tester.widget<ErrorPage>(startupError.first);
      fail('Sonus Auris startup failed during auth E2E: ${page.error}');
    }
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  final visibleText = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data)
      .whereType<String>()
      .where((text) => text.trim().isNotEmpty)
      .join(' | ');
  fail(
    'Timed out waiting for the expected live-auth widget. '
    'Visible text: $visibleText',
  );
}
