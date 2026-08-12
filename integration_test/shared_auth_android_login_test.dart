import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_dashcam/main.dart';
import 'package:audio_dashcam/src/app/app_controller.dart';
import 'package:audio_dashcam/src/services/settings_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/shared_auth_test_client.dart';

const _bridgeUrl = String.fromEnvironment(
  'SONUS_TEST_SHARED_AUTH_BRIDGE_URL',
  defaultValue: 'http://127.0.0.1:41842/session',
);
const _email = String.fromEnvironment('SONUS_TEST_EMAIL');
const _supabaseUrl = String.fromEnvironment('SONUS_SUPABASE_URL');
const _supabaseKey = String.fromEnvironment('SONUS_SUPABASE_ANON_KEY');
const _testCode = '424242';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android signs in through Shared Auth and completes mandatory AAL2',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final secrets = _MemorySecretValueStore();
      await tester.pumpWidget(
        AudioDashcamRoot(
          controllerFactory: () => AppController(
            settingsStore: SettingsStore(secretValueStore: secrets),
            authClient: SharedAuthTestClient(bridgeUrl: _bridgeUrl),
          ),
        ),
      );

      await _pumpUntil(
        tester,
        find.text('Welcome to Sonus Auris'),
        timeout: const Duration(seconds: 90),
      );
      await tester.tap(find.text('Continue'));

      final requestButton = find.byKey(
        const ValueKey('supabase-request-button'),
      );
      await _pumpUntilEnabled(tester, requestButton);
      await tester.enterText(
        find.byKey(const ValueKey('supabase-email-field')),
        _email,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.ensureVisible(requestButton);
      await tester.tap(requestButton);

      final codeField = find.byKey(const ValueKey('supabase-code-field'));
      await _pumpUntil(tester, codeField);
      await tester.enterText(codeField, _testCode);
      final verifyButton = find.byKey(const ValueKey('supabase-verify-button'));
      await tester.ensureVisible(verifyButton);
      await tester.tap(verifyButton);

      // The deterministic first factor must stop at AAL1. A fresh synthetic
      // identity therefore reaches the normal TOTP enrollment gate rather than
      // opening account data directly.
      final enrollTotp = find.byKey(
        const ValueKey('mandatory-mfa-totp-button'),
      );
      await _pumpUntil(
        tester,
        enrollTotp,
        timeout: const Duration(seconds: 60),
      );
      expect(
        find.byKey(const ValueKey('onboarding-signed-in-state')),
        findsNothing,
      );
      await tester.tap(enrollTotp);

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
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(mfaVerify);
      await tester.tap(mfaVerify);

      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('onboarding-signed-in-state')),
        timeout: const Duration(seconds: 60),
      );
      expect(find.text('Signed in'), findsOneWidget);
      expect(find.textContaining(_email), findsOneWidget);
    },
    skip:
        _email.isEmpty ||
        _supabaseUrl.isEmpty ||
        _supabaseKey.isEmpty ||
        _bridgeUrl.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
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

Future<void> _pumpUntilEnabled(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) {
      final button = tester.widget<ButtonStyleButton>(finder);
      if (button.onPressed != null) return;
    }
  }
  throw StateError('Timed out waiting for an enabled control: $finder');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw StateError('Timed out waiting for $finder');
}
