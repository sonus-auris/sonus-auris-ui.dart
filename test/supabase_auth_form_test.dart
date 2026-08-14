import 'dart:async';

import 'package:audio_dashcam/src/theme/sonus_theme.dart';
import 'package:audio_dashcam/src/widgets/supabase_auth_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auth validators reject malformed input and insecure URLs', () {
    expect(validateAccountEmail(''), isNotNull);
    expect(validateAccountEmail('not-an-email'), isNotNull);
    expect(validateAccountEmail('person@example.com'), isNull);
    expect(validateEmailOtpCode(''), isNotNull);
    expect(validateEmailOtpCode('123'), isNotNull);
    expect(validateEmailOtpCode('12ab56'), isNotNull);
    expect(validateEmailOtpCode('12345a'), isNotNull);
    expect(validateEmailOtpCode('123456'), isNull);
    expect(validateSupabaseProjectUrl('http://project.supabase.co'), isNotNull);
    expect(validateSupabaseProjectUrl('https://project.supabase.co'), isNull);
    expect(validateSupabaseProjectUrl('http://localhost:54321'), isNull);
    expect(validateSupabaseAnonKey('sb_secret_never-ship'), isNotNull);
  });

  testWidgets('blocks a code request until email and project fields are valid', (
    tester,
  ) async {
    final harness = _AuthHarness(showProjectConfiguration: true);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
    await tester.pump();

    expect(find.text('Enter the Supabase project URL.'), findsOneWidget);
    expect(find.text('Enter the publishable or anon key.'), findsOneWidget);
    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(harness.requestCalls, 0);
    // There is no password field, and the code field only appears after a code
    // has actually been requested.
    expect(find.textContaining('Password'), findsNothing);
    expect(find.byKey(const ValueKey('supabase-code-field')), findsNothing);
  });

  testWidgets('requests a code, reveals the code field, and verifies it', (
    tester,
  ) async {
    final harness = _AuthHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      '  person@example.com  ',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
    await tester.pumpAndSettle();

    expect(harness.requestCalls, 1);
    expect(harness.lastRequestedEmail, 'person@example.com');
    // The single flow reveals the code field and hides the email-step button.
    expect(find.byKey(const ValueKey('supabase-code-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('supabase-request-button')), findsNothing);
    expect(
      find.text(
        'We emailed a 6-digit sign-in code to person@example.com. Enter it to '
        'continue.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('fallback'), findsNothing);
    expect(find.textContaining('sign-in link'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('supabase-code-field')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-verify-button')));
    await tester.pumpAndSettle();

    expect(harness.submitCalls, 1);
    expect(harness.lastSubmittedEmail, 'person@example.com');
    expect(harness.lastSubmittedCode, '123456');
  });

  testWidgets('stays on the email step when the code was not sent', (
    tester,
  ) async {
    final harness = _AuthHarness(requestReturns: false);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      'person@example.com',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
    await tester.pumpAndSettle();

    expect(harness.requestCalls, 1);
    expect(find.byKey(const ValueKey('supabase-code-field')), findsNothing);
    expect(
      find.byKey(const ValueKey('supabase-request-button')),
      findsOneWidget,
    );
  });

  testWidgets('blocks verification until the code is six digits', (
    tester,
  ) async {
    final harness = _AuthHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      'person@example.com',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('supabase-code-field')),
      '123',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-verify-button')));
    await tester.pump();

    expect(find.text('Enter the 6-digit code from the email.'), findsOneWidget);
    expect(harness.submitCalls, 0);
  });

  testWidgets(
    'keeps local validation inline and in a floating toast in landscape',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harness = _AuthHarness(showProjectConfiguration: true);
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build());

      await tester.enterText(
        find.byKey(const ValueKey('supabase-url-field')),
        'https://test-project.supabase.co',
      );
      await tester.enterText(
        find.byKey(const ValueKey('supabase-anon-key-field')),
        'sb_publishable_test_public_value',
      );
      await tester.enterText(
        find.byKey(const ValueKey('supabase-email-field')),
        'definitely-not-an-email',
      );
      await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(
        find.text('Fix before continuing: Enter a valid email address.'),
        findsOneWidget,
      );
      final toast = find.byKey(const ValueKey('auth-validation-toast'));
      expect(toast, findsOneWidget);
      final bounds = tester.getRect(toast);
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(844));
      expect(bounds.bottom, lessThanOrEqualTo(390));
      expect(harness.requestCalls, 0);

      // A second attempt must queue another visible error instead of replacing
      // or silently dropping the first one. Advance past the first toast's
      // eight-second lifetime and confirm the queued toast is now rendered.
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('supabase-request-button')),
          )
          .onPressed!();
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(toast, findsOneWidget);
      expect(
        find.text('Fix before continuing: Enter a valid email address.'),
        findsOneWidget,
      );
      expect(harness.requestCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reports per-step progress and busy states', (tester) async {
    final requestCompleter = Completer<void>();
    final submitCompleter = Completer<void>();
    final harness = _AuthHarness(
      onRequest: () => requestCompleter.future,
      onSubmit: () => submitCompleter.future,
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      'person@example.com',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
    await tester.pump();
    expect(find.text('Sending…'), findsOneWidget);

    requestCompleter.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('supabase-code-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('supabase-code-field')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-verify-button')));
    await tester.pump();
    expect(find.text('Signing in…'), findsOneWidget);

    submitCompleter.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('can resend a code and return to the email step', (tester) async {
    final harness = _AuthHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      'person@example.com',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
    await tester.pumpAndSettle();
    expect(harness.requestCalls, 1);

    // Resend re-requests a code without leaving the code step.
    await tester.tap(find.byKey(const ValueKey('supabase-resend-button')));
    await tester.pumpAndSettle();
    expect(harness.requestCalls, 2);
    expect(find.byKey(const ValueKey('supabase-code-field')), findsOneWidget);

    // "Use a different email" returns to the email step.
    await tester.tap(
      find.byKey(const ValueKey('supabase-change-email-button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('supabase-request-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('supabase-code-field')), findsNothing);
  });

  testWidgets('surfaces an inline error when verification fails', (
    tester,
  ) async {
    final harness = _AuthHarness(
      onSubmit: () async => throw StateError('That code was not accepted.'),
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    await tester.enterText(
      find.byKey(const ValueKey('supabase-email-field')),
      'person@example.com',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('supabase-code-field')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey('supabase-verify-button')));
    await tester.pumpAndSettle();

    expect(find.text('That code was not accepted.'), findsOneWidget);
  });

  testWidgets('lays out without overflow on a narrow large-text screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = _AuthHarness(textScale: 1.8);
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    expect(
      find.byKey(const ValueKey('supabase-request-button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

class _AuthHarness {
  _AuthHarness({
    this.showProjectConfiguration = false,
    this.requestReturns = true,
    this.onRequest,
    this.onSubmit,
    this.textScale = 1,
  });

  final bool showProjectConfiguration;
  final bool requestReturns;
  final Future<void> Function()? onRequest;
  final Future<void> Function()? onSubmit;
  final double textScale;
  final email = TextEditingController();
  final code = TextEditingController();
  final url = TextEditingController();
  final anonKey = TextEditingController();
  int requestCalls = 0;
  int submitCalls = 0;
  String? lastRequestedEmail;
  String? lastSubmittedEmail;
  String? lastSubmittedCode;

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
            codeController: code,
            supabaseUrlController: url,
            supabaseAnonKeyController: anonKey,
            showProjectConfiguration: showProjectConfiguration,
            onRequestCode: (value) async {
              requestCalls += 1;
              lastRequestedEmail = value;
              await onRequest?.call();
              return requestReturns;
            },
            onSubmitCode: (value, codeValue) async {
              submitCalls += 1;
              lastSubmittedEmail = value;
              lastSubmittedCode = codeValue;
              await onSubmit?.call();
            },
          ),
        ),
      ),
    );
  }

  void dispose() {
    email.dispose();
    code.dispose();
    url.dispose();
    anonKey.dispose();
  }
}
