import 'dart:async';

import 'package:audio_dashcam/src/theme/sonus_theme.dart';
import 'package:audio_dashcam/src/widgets/supabase_auth_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auth validators reject malformed email and insecure URLs', () {
    expect(validateAccountEmail(''), isNotNull);
    expect(validateAccountEmail('not-an-email'), isNotNull);
    expect(validateAccountEmail('person@@example.com'), isNotNull);
    expect(validateAccountEmail('person@example.com\nattacker'), isNotNull);
    expect(validateAccountEmail('person@example.com'), isNull);
    expect(validateEmailCode(''), isNotNull);
    expect(validateEmailCode('12345a'), isNotNull);
    expect(validateEmailCode('123456'), isNull);
    expect(validateSupabaseProjectUrl('http://project.supabase.co'), isNotNull);
    expect(validateSupabaseProjectUrl('https://project.supabase.co'), isNull);
    expect(validateSupabaseProjectUrl('http://localhost:54321'), isNull);
    expect(validateSupabaseAnonKey('sb_secret_never-ship'), isNotNull);
  });

  testWidgets('contains no password field and validates before sending', (
    tester,
  ) async {
    final harness = _AuthHarness(showProjectConfiguration: true);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    expect(find.textContaining('Password'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('supabase-send-link-button')));
    await tester.pump();

    expect(find.text('Enter the Supabase project URL.'), findsOneWidget);
    expect(find.text('Enter the publishable or anon key.'), findsOneWidget);
    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(harness.sendCalls, 0);
  });

  testWidgets('sends a normalized email code and reveals code entry', (
    tester,
  ) async {
    final completer = Completer<bool>();
    final harness = _AuthHarness(onSend: () => completer.future);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());
    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      ' listener@example.com ',
    );

    await tester.tap(find.byKey(const ValueKey('supabase-send-link-button')));
    await tester.pump();
    expect(harness.sendCalls, 1);
    expect(harness.lastEmail, 'listener@example.com');
    expect(find.text('Sending…'), findsOneWidget);

    completer.complete(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('supabase-code-field')), findsOneWidget);
    expect(find.text('Send a fresh code'), findsOneWidget);
  });

  testWidgets('verifies the emailed sign-in code', (tester) async {
    final harness = _AuthHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());
    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      'person@example.com',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-send-link-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('supabase-code-field')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-verify-code-button')));
    await tester.pumpAndSettle();

    expect(harness.verifyCalls, 1);
    expect(harness.lastCode, '123456');
  });
}

class _AuthHarness {
  _AuthHarness({this.showProjectConfiguration = false, this.onSend});

  final bool showProjectConfiguration;
  final Future<bool> Function()? onSend;
  final email = TextEditingController();
  final url = TextEditingController();
  final anonKey = TextEditingController();
  int sendCalls = 0;
  int verifyCalls = 0;
  String? lastEmail;
  String? lastCode;

  Widget build() {
    return MaterialApp(
      theme: buildSonusTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SupabaseAuthForm(
            emailController: email,
            supabaseUrlController: url,
            supabaseAnonKeyController: anonKey,
            showProjectConfiguration: showProjectConfiguration,
            onSendMagicLink: (email) async {
              sendCalls += 1;
              lastEmail = email;
              return await onSend?.call() ?? true;
            },
            onVerifyCode: (email, code) async {
              verifyCalls += 1;
              lastEmail = email;
              lastCode = code;
              return true;
            },
          ),
        ),
      ),
    );
  }

  void dispose() {
    email.dispose();
    url.dispose();
    anonKey.dispose();
  }
}
