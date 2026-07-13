import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_dashcam/src/theme/sonus_theme.dart';
import 'package:audio_dashcam/src/widgets/supabase_auth_panel.dart';

void main() {
  Widget harness({
    required Future<void> Function(String, String) onSignIn,
    required Future<void> Function(String, String) onSignUp,
    Future<void> Function(String)? onPasswordReset,
    bool enabled = true,
  }) {
    return MaterialApp(
      theme: buildSonusTheme(),
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            SupabaseAuthPanel(
              enabled: enabled,
              onSignIn: onSignIn,
              onSignUp: onSignUp,
              onPasswordReset: onPasswordReset,
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('validates credentials before sign in', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      harness(onSignIn: (_, _) async => calls += 1, onSignUp: (_, _) async {}),
    );

    await tester.tap(find.text('Sign in securely'));
    await tester.pump();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('signs in with normalized email and exact password', (
    tester,
  ) async {
    String? submittedEmail;
    String? submittedPassword;
    await tester.pumpWidget(
      harness(
        onSignIn: (email, password) async {
          submittedEmail = email;
          submittedPassword = password;
        },
        onSignUp: (_, _) async {},
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email')),
      '  listener@example.com  ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('supabase-password')),
      'correct horse battery staple',
    );
    await tester.tap(find.text('Sign in securely'));
    await tester.pumpAndSettle();

    expect(submittedEmail, 'listener@example.com');
    expect(submittedPassword, 'correct horse battery staple');
  });

  testWidgets('switches to account creation and submits', (tester) async {
    String? submittedEmail;
    await tester.pumpWidget(
      harness(
        onSignIn: (_, _) async {},
        onSignUp: (email, _) async => submittedEmail = email,
      ),
    );

    await tester.tap(find.text('Create account'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('supabase-email')),
      'new.listener@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('supabase-password')),
      'long-enough-password',
    );
    await tester.tap(find.text('Create my account'));
    await tester.pumpAndSettle();

    expect(submittedEmail, 'new.listener@example.com');
  });

  testWidgets('requests a password reset for the entered email', (
    tester,
  ) async {
    String? resetEmail;
    await tester.pumpWidget(
      harness(
        onSignIn: (_, _) async {},
        onSignUp: (_, _) async {},
        onPasswordReset: (email) async => resetEmail = email,
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email')),
      '  reset@example.com ',
    );
    await tester.tap(find.text('Reset password'));
    await tester.pumpAndSettle();

    expect(resetEmail, 'reset@example.com');
  });

  testWidgets('explains when account access is not configured', (tester) async {
    await tester.pumpWidget(
      harness(
        enabled: false,
        onSignIn: (_, _) async {},
        onSignUp: (_, _) async {},
      ),
    );

    expect(find.textContaining('Account access is not configured'), findsOne);
    expect(find.byKey(const ValueKey('supabase-email')), findsNothing);
  });
}
