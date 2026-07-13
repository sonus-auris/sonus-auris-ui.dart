import 'dart:async';

import 'package:audio_dashcam/src/theme/sonus_theme.dart';
import 'package:audio_dashcam/src/widgets/supabase_auth_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auth validators reject malformed credentials and insecure URLs', () {
    expect(validateAccountEmail(''), isNotNull);
    expect(validateAccountEmail('not-an-email'), isNotNull);
    expect(validateAccountEmail('person@example.com'), isNull);
    expect(validateAccountPassword('', creatingAccount: false), isNotNull);
    expect(validateAccountPassword('short', creatingAccount: true), isNotNull);
    expect(validateAccountPassword('six-ok', creatingAccount: true), isNull);
    expect(validateSupabaseProjectUrl('http://project.supabase.co'), isNotNull);
    expect(validateSupabaseProjectUrl('https://project.supabase.co'), isNull);
    expect(validateSupabaseProjectUrl('http://localhost:54321'), isNull);
    expect(validateSupabaseAnonKey('sb_secret_never-ship'), isNotNull);
  });

  testWidgets('blocks invalid sign-in before invoking Supabase', (
    tester,
  ) async {
    final harness = _AuthHarness(showProjectConfiguration: true);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    await tester.tap(find.byKey(const ValueKey('supabase-sign-in-button')));
    await tester.pump();

    expect(find.text('Enter the Supabase project URL.'), findsOneWidget);
    expect(find.text('Enter the publishable or anon key.'), findsOneWidget);
    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(harness.signInCalls, 0);
  });

  testWidgets(
    'create account validates length and reports per-action progress',
    (tester) async {
      final completer = Completer<void>();
      final harness = _AuthHarness(onSignUp: () => completer.future);
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build());
      await tester.enterText(
        find.byKey(const ValueKey('supabase-email-field')),
        'person@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('supabase-password-field')),
        'short',
      );

      await tester.tap(find.byKey(const ValueKey('supabase-sign-up-button')));
      await tester.pump();
      expect(find.text('Use at least 6 characters.'), findsOneWidget);
      expect(harness.signUpCalls, 0);

      await tester.enterText(
        find.byKey(const ValueKey('supabase-password-field')),
        'six-ok',
      );
      await tester.tap(find.byKey(const ValueKey('supabase-sign-up-button')));
      await tester.pump();
      expect(harness.signUpCalls, 1);
      expect(find.text('Creating…'), findsOneWidget);
      final signIn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('supabase-sign-in-button')),
      );
      expect(signIn.onPressed, isNull);

      completer.complete();
      await tester.pumpAndSettle();
      expect(find.text('Create account'), findsOneWidget);
    },
  );

  testWidgets('password reset needs email but not a password', (tester) async {
    final harness = _AuthHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());
    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      'person@example.com',
    );

    await tester.tap(
      find.byKey(const ValueKey('supabase-reset-password-button')),
    );
    await tester.pumpAndSettle();

    expect(harness.resetCalls, 1);
    expect(find.text('Enter your password.'), findsNothing);
  });

  testWidgets('uses a stacked layout on a narrow large-text screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = _AuthHarness(textScale: 1.8);
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    final signIn = tester.getCenter(
      find.byKey(const ValueKey('supabase-sign-in-button')),
    );
    final signUp = tester.getCenter(
      find.byKey(const ValueKey('supabase-sign-up-button')),
    );
    expect(signUp.dy, greaterThan(signIn.dy));
    expect(tester.takeException(), isNull);
  });
}

class _AuthHarness {
  _AuthHarness({
    this.showProjectConfiguration = false,
    this.onSignUp,
    this.textScale = 1,
  });

  final bool showProjectConfiguration;
  final Future<void> Function()? onSignUp;
  final double textScale;
  final email = TextEditingController();
  final password = TextEditingController();
  final url = TextEditingController();
  final anonKey = TextEditingController();
  int signInCalls = 0;
  int signUpCalls = 0;
  int resetCalls = 0;

  Widget build() {
    return MaterialApp(
      theme: buildSonusTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SupabaseAuthForm(
            emailController: email,
            passwordController: password,
            supabaseUrlController: url,
            supabaseAnonKeyController: anonKey,
            showProjectConfiguration: showProjectConfiguration,
            onSignIn: (email, password) async => signInCalls += 1,
            onSignUp: (email, password) async {
              signUpCalls += 1;
              await onSignUp?.call();
            },
            onPasswordReset: (email) async => resetCalls += 1,
          ),
        ),
      ),
    );
  }

  void dispose() {
    email.dispose();
    password.dispose();
    url.dispose();
    anonKey.dispose();
  }
}
