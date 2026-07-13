import 'package:audio_dashcam/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _email = String.fromEnvironment('SONUS_TEST_EMAIL');
const _password = String.fromEnvironment('SONUS_TEST_PASSWORD');

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
