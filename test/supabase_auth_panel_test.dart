import 'package:audio_dashcam/src/theme/sonus_theme.dart';
import 'package:audio_dashcam/src/widgets/supabase_auth_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget harness({
<<<<<<< HEAD
    required Future<bool> Function(String) onSendMagicLink,
    required Future<bool> Function(String, String) onVerifyCode,
=======
    required Future<bool> Function(String) onRequestCode,
    required Future<void> Function(String, String) onSubmitCode,
>>>>>>> origin/main
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
<<<<<<< HEAD
              onSendMagicLink: onSendMagicLink,
              onVerifyCode: onVerifyCode,
=======
              onRequestCode: onRequestCode,
              onSubmitCode: onSubmitCode,
>>>>>>> origin/main
            ),
          ],
        ),
      ),
    );
  }

<<<<<<< HEAD
  testWidgets('uses a passwordless magic-link surface', (tester) async {
    String? submittedEmail;
    await tester.pumpWidget(
      harness(
        onSendMagicLink: (email) async {
          submittedEmail = email;
          return true;
        },
        onVerifyCode: (_, _) async => true,
=======
  testWidgets('validates the email before requesting a code', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      harness(
        onRequestCode: (_) async {
          calls += 1;
          return true;
        },
        onSubmitCode: (_, _) async {},
      ),
    );

    await tester.tap(find.text('Email me a sign-in link'));
    await tester.pump();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('requests a code with a normalized email, then verifies it', (
    tester,
  ) async {
    String? requestedEmail;
    String? submittedEmail;
    String? submittedCode;
    await tester.pumpWidget(
      harness(
        onRequestCode: (email) async {
          requestedEmail = email;
          return true;
        },
        onSubmitCode: (email, code) async {
          submittedEmail = email;
          submittedCode = code;
        },
>>>>>>> origin/main
      ),
    );

    expect(find.textContaining('password', findRichText: true), findsWidgets);
    expect(find.byType(TextFormField), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      ' listener@example.com ',
    );
<<<<<<< HEAD
    await tester.tap(find.text('Email me a 6-digit code'));
    await tester.pumpAndSettle();

    expect(submittedEmail, 'listener@example.com');
    expect(find.byKey(const ValueKey('supabase-code-field')), findsOneWidget);
=======
    await tester.tap(find.text('Email me a sign-in link'));
    await tester.pumpAndSettle();

    // One flow covers sign-in and sign-up: the code field is now revealed.
    expect(requestedEmail, 'listener@example.com');
    expect(find.byKey(const ValueKey('supabase-code')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('supabase-code')),
      '654321',
    );
    await tester.tap(find.text('Sign in securely'));
    await tester.pumpAndSettle();

    expect(submittedEmail, 'listener@example.com');
    expect(submittedCode, '654321');
  });

  testWidgets('validates the code before verifying', (tester) async {
    var submits = 0;
    await tester.pumpWidget(
      harness(
        onRequestCode: (_) async => true,
        onSubmitCode: (_, _) async => submits += 1,
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email')),
      'listener@example.com',
    );
    await tester.tap(find.text('Email me a sign-in link'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('supabase-code')), '12');
    await tester.tap(find.text('Sign in securely'));
    await tester.pump();

    expect(find.text('Enter the 6-digit code from the email.'), findsOneWidget);
    expect(submits, 0);
  });

  testWidgets('can resend a code and return to the email step', (tester) async {
    var requests = 0;
    await tester.pumpWidget(
      harness(
        onRequestCode: (_) async {
          requests += 1;
          return true;
        },
        onSubmitCode: (_, _) async {},
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email')),
      'listener@example.com',
    );
    await tester.tap(find.text('Email me a sign-in link'));
    await tester.pumpAndSettle();
    expect(requests, 1);

    await tester.tap(find.text('Resend'));
    await tester.pumpAndSettle();
    expect(requests, 2);

    await tester.tap(find.text('Use a different email'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('supabase-code')), findsNothing);
    expect(find.text('Email me a sign-in link'), findsOneWidget);
>>>>>>> origin/main
  });

  testWidgets('explains when account access is not configured', (tester) async {
    await tester.pumpWidget(
      harness(
        enabled: false,
<<<<<<< HEAD
        onSendMagicLink: (_) async => true,
        onVerifyCode: (_, _) async => true,
=======
        onRequestCode: (_) async => true,
        onSubmitCode: (_, _) async {},
>>>>>>> origin/main
      ),
    );

    expect(find.textContaining('Account access is not configured'), findsOne);
    expect(find.byKey(const ValueKey('supabase-email-field')), findsNothing);
  });
}
