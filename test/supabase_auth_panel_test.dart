import 'package:audio_dashcam/src/theme/sonus_theme.dart';
import 'package:audio_dashcam/src/widgets/supabase_auth_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget harness({
    required Future<bool> Function(String) onSendMagicLink,
    required Future<bool> Function(String, String) onVerifyCode,
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
              onSendMagicLink: onSendMagicLink,
              onVerifyCode: onVerifyCode,
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('uses a passwordless magic-link surface', (tester) async {
    String? submittedEmail;
    await tester.pumpWidget(
      harness(
        onSendMagicLink: (email) async {
          submittedEmail = email;
          return true;
        },
        onVerifyCode: (_, _) async => true,
      ),
    );

    expect(find.textContaining('password', findRichText: true), findsWidgets);
    expect(find.byType(TextFormField), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      ' listener@example.com ',
    );
    await tester.tap(find.text('Email me a 6-digit code'));
    await tester.pumpAndSettle();

    expect(submittedEmail, 'listener@example.com');
    expect(find.byKey(const ValueKey('supabase-code-field')), findsOneWidget);
  });

  testWidgets('explains when account access is not configured', (tester) async {
    await tester.pumpWidget(
      harness(
        enabled: false,
        onSendMagicLink: (_) async => true,
        onVerifyCode: (_, _) async => true,
      ),
    );

    expect(find.textContaining('Account access is not configured'), findsOne);
    expect(find.byKey(const ValueKey('supabase-email-field')), findsNothing);
  });
}
