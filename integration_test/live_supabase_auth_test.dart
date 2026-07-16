import 'dart:convert';

import 'package:audio_dashcam/main.dart';
import 'package:audio_dashcam/src/services/supabase_key_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';

const _email = String.fromEnvironment('SONUS_TEST_EMAIL');
const _password = String.fromEnvironment('SONUS_TEST_PASSWORD');
const _otherEmail = String.fromEnvironment('SONUS_TEST_EMAIL_B');
const _otherPassword = String.fromEnvironment('SONUS_TEST_PASSWORD_B');
const _supabaseUrl = String.fromEnvironment('SONUS_SUPABASE_URL');
const _supabaseKey = String.fromEnvironment('SONUS_SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'live Supabase password sign-in reaches the authenticated account state',
    (tester) async {
      await tester.pumpWidget(const AudioDashcamRoot());

      await _pumpUntil(
        tester,
        find.text('Welcome to Sonus Auris'),
        timeout: const Duration(seconds: 90),
      );
      await tester.tap(find.text('Continue'));

      final emailField = find.byKey(const ValueKey('supabase-email-field'));
      final passwordField = find.byKey(
        const ValueKey('supabase-password-field'),
      );
      final signInButton = find.byKey(
        const ValueKey('supabase-sign-in-button'),
      );
      await _pumpUntilEnabled(tester, signInButton);

      await tester.enterText(emailField, _email);
      await tester.enterText(passwordField, _password);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.ensureVisible(signInButton);
      await tester.pump();
      await tester.tap(signInButton);

      await _pumpUntil(
        tester,
        find.text('Signed in'),
        timeout: const Duration(seconds: 45),
      );
      expect(find.textContaining(_email), findsOneWidget);
    },
    // This test is opt-in because it targets a real Supabase project. Supply
    // both credentials as dart-defines; no live credential belongs in source.
    skip: _email.isEmpty || _password.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'live Supabase keeps two authenticated users isolated by RLS',
    () async {
      requireSafeSupabaseClientKey(_supabaseKey);
      final first = await _signIn(_email, _password);
      final second = await _signIn(_otherEmail, _otherPassword);
      expect(first.userId, isNot(second.userId));

      final firstEvent = const Uuid().v4();
      final secondEvent = const Uuid().v4();
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
      } finally {
        await _deleteAcousticEvent(first, firstEvent);
        await _deleteAcousticEvent(second, secondEvent);
      }
    },
    skip:
        _email.isEmpty ||
        _password.isEmpty ||
        _otherEmail.isEmpty ||
        _otherPassword.isEmpty ||
        _supabaseUrl.isEmpty ||
        _supabaseKey.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _LiveSession {
  const _LiveSession({required this.userId, required this.accessToken});

  final String userId;
  final String accessToken;
}

Future<_LiveSession> _signIn(String email, String password) async {
  final response = await http.post(
    Uri.parse(
      '${_supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/auth/v1/token?grant_type=password',
    ),
    headers: {'apikey': _supabaseKey, 'Content-Type': 'application/json'},
    body: jsonEncode({'email': email, 'password': password}),
  );
  expect(response.statusCode, 200, reason: 'live Supabase sign-in failed');
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final user = body['user'] as Map<String, dynamic>;
  return _LiveSession(
    userId: user['id'] as String,
    accessToken: body['access_token'] as String,
  );
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

Future<void> _deleteAcousticEvent(_LiveSession session, String id) async {
  final response = await http.delete(
    _restUri('acoustic_events?id=eq.$id'),
    headers: _headers(session),
  );
  expect(response.statusCode, 204, reason: 'live RLS fixture cleanup failed');
}

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
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for the expected live-auth widget.');
}
