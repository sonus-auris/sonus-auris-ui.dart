// Real-browser smoke tests for the Flutter **web** account surface.
//
// These run under `flutter drive -d web-server --browser-name=chrome
// --headless` against a live chromedriver, so every assertion here is made
// against the CanvasKit/DOM output of an actual Chrome process — not the
// headless VM widget harness used by `flutter test`.
//
// What they pin down (all invariants of the consolidated passwordless auth):
//   * `SonusWebApp` boots with no browser `console.error` and no uncaught
//     Flutter/Dart error.
//   * The auth surface is CODE-FIRST: it opens on an email step and advances
//     to a 6-digit code step, with a working way back.
//   * `validateAccountEmail` and `validateEmailOtpCode` reject bad input
//     *through the real form* — the request/submit callbacks must not fire.
//   * `validateEmailOtpCode` is digits-only, so a value a naive
//     `int.tryParse` would happily accept (`+12345`) is still refused.
//   * No password control exists on any step of the flow.
//
// CI: .github/workflows/ci.yml, job `web-browser-test`.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:audio_dashcam/main_web.dart';
import 'package:audio_dashcam/src/widgets/supabase_auth_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Installs a `window.console.error` / `console.warn` interceptor and returns
/// the live list it appends to. The original function is still called, so the
/// driver log keeps showing anything that goes wrong.
List<String> _captureConsoleErrors() {
  final captured = <String>[];
  final console = globalContext.getProperty<JSObject>('console'.toJS);
  for (final level in const ['error', 'warn']) {
    final original = console.getProperty<JSFunction?>(level.toJS);
    if (original == null) {
      continue;
    }
    void record(JSAny? first) {
      captured.add('$level: ${first?.dartify() ?? 'null'}');
    }

    console.setProperty(
      level.toJS,
      ((JSAny? first) {
        record(first);
        original.callAsFunction(console, first);
      }).toJS,
    );
  }
  return captured;
}

/// Pumps in small slices until [ready] holds, instead of `pumpAndSettle` —
/// the web shell keeps a session-refresh timer alive, which never settles.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 30),
  String reason = 'condition never became true',
  String Function()? diagnose,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) {
      return;
    }
  }
  final extra = diagnose == null ? '' : ' [${diagnose()}]';
  fail('Timed out after $timeout: $reason$extra');
}

/// Types [value] into the field with [key] and does not return until the
/// field's own controller actually holds it. On web the text-input channel is
/// asynchronous, so tapping straight after `enterText` can act on stale text.
Future<void> _enterText(WidgetTester tester, Key key, String value) async {
  final field = find.byKey(key);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
  await _pumpUntil(
    tester,
    () => _textOf(tester, key) == value,
    timeout: const Duration(seconds: 10),
    reason: 'the field never took the typed value',
    diagnose: () => 'field now holds "${_textOf(tester, key)}"',
  );
}

String _textOf(WidgetTester tester, Key key) {
  final editable = find.descendant(
    of: find.byKey(key),
    matching: find.byType(EditableText),
  );
  if (editable.evaluate().isEmpty) {
    return '<absent>';
  }
  return tester.widget<EditableText>(editable.first).controller.text;
}

/// Taps a button after scrolling it into view, so a grown form (an extra
/// validation line, say) can never turn a real regression into a missed tap.
Future<void> _tapButton(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pump();
  await tester.tap(find.byKey(key));
  await tester.pump();
}

/// Every rendered text-editing widget, so password checks can inspect the real
/// widget tree rather than trusting the source file.
Iterable<EditableText> _editableTexts(WidgetTester tester) =>
    tester.widgetList<EditableText>(find.byType(EditableText));

void _expectNoPasswordControl(WidgetTester tester, String step) {
  for (final editable in _editableTexts(tester)) {
    expect(
      editable.keyboardType,
      isNot(TextInputType.visiblePassword),
      reason: '$step: a visible-password keyboard appeared',
    );
    final hints = editable.autofillHints ?? const <String>[];
    for (final hint in hints) {
      expect(
        hint,
        isNot(anyOf(AutofillHints.password, AutofillHints.newPassword)),
        reason: '$step: a field advertised a password autofill hint',
      );
    }
  }
  // The Supabase anon-key field is legitimately obscured, so obscureText alone
  // is not the signal. User-visible password *copy* is.
  expect(
    find.textContaining('Password', findRichText: true),
    findsNothing,
    reason: '$step: password copy is rendered in a passwordless flow',
  );
  expect(
    find.textContaining('password', findRichText: true),
    findsNothing,
    reason: '$step: password copy is rendered in a passwordless flow',
  );
}

/// Minimal host for [SupabaseAuthForm] with recording stubs, so the two-step
/// wizard and both validators can be driven hermetically in the browser
/// without a live Supabase project.
class _AuthFormHarness extends StatefulWidget {
  const _AuthFormHarness({
    required this.requestedEmails,
    required this.submitted,
  });

  final List<String> requestedEmails;
  final List<String> submitted;

  @override
  State<_AuthFormHarness> createState() => _AuthFormHarnessState();
}

class _AuthFormHarnessState extends State<_AuthFormHarness> {
  final email = TextEditingController();
  final code = TextEditingController();

  @override
  void dispose() {
    email.dispose();
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: SupabaseAuthForm(
            emailController: email,
            codeController: code,
            onRequestCode: (value) async {
              widget.requestedEmails.add(value);
              return true;
            },
            onSubmitCode: (value, otp) async {
              widget.submitted.add('$value|$otp');
            },
          ),
        ),
      ),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const emailField = ValueKey('supabase-email-field');
  const codeField = ValueKey('supabase-code-field');
  const requestButton = ValueKey('supabase-request-button');
  const verifyButton = ValueKey('supabase-verify-button');
  const changeEmailButton = ValueKey('supabase-change-email-button');

  testWidgets(
    'web shell boots clean and opens on the passwordless email step',
    (tester) async {
      final consoleErrors = _captureConsoleErrors();
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(const SonusWebApp());
      await _pumpUntil(
        tester,
        () => find.byKey(emailField).evaluate().isNotEmpty,
        reason: 'the web shell never rendered the email field',
      );

      // The account surface is the passwordless code flow, not a password box.
      expect(find.byKey(emailField), findsOneWidget);
      expect(find.text('Email me a 6-digit code'), findsOneWidget);
      expect(
        find.byKey(codeField),
        findsNothing,
        reason: 'the code step must not be reachable before a code is sent',
      );
      _expectNoPasswordControl(tester, 'web shell boot');

      expect(
        tester.takeException(),
        isNull,
        reason: 'the web shell threw while booting',
      );
      expect(
        consoleErrors,
        isEmpty,
        reason: 'browser console reported errors during boot',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'email step advances to the 6-digit code step and back',
    (tester) async {
      final requested = <String>[];
      final submitted = <String>[];
      await tester.pumpWidget(
        _AuthFormHarness(requestedEmails: requested, submitted: submitted),
      );
      await tester.pump();

      expect(find.byKey(codeField), findsNothing);

      await _enterText(tester, emailField, 'person@example.com');
      await _tapButton(tester, requestButton);
      await _pumpUntil(
        tester,
        () => find.byKey(codeField).evaluate().isNotEmpty,
        reason: 'requesting a code never revealed the code step',
        diagnose: () => 'requested=$requested',
      );

      expect(requested, ['person@example.com']);
      expect(find.byKey(emailField), findsNothing);
      expect(find.text('Enter your sign-in code'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      _expectNoPasswordControl(tester, 'code step');

      // The way back must restore the email step so a typo is recoverable.
      await _tapButton(tester, changeEmailButton);
      await _pumpUntil(
        tester,
        () => find.byKey(emailField).evaluate().isNotEmpty,
        reason: '"Use a different email" never returned to the email step',
      );
      expect(find.byKey(codeField), findsNothing);
      expect(submitted, isEmpty);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'the email validator blocks malformed addresses through the real form',
    (tester) async {
      final requested = <String>[];
      await tester.pumpWidget(
        _AuthFormHarness(requestedEmails: requested, submitted: <String>[]),
      );
      await tester.pump();

      // 320 is the cap; a 321-character address and an address carrying a
      // control character must both be refused before any network call.
      final overlong = '${'a' * 310}@example.com'; // 322 characters
      expect(overlong.length, greaterThan(320));
      final rejected = <String>[
        'not-an-email',
        'no-domain@',
        'two@at@example.com',
        'has space@example.com',
        'tab\there@example.com',
        overlong,
      ];

      for (final candidate in rejected) {
        await _enterText(tester, emailField, candidate);
        await _tapButton(tester, requestButton);
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.byKey(codeField),
          findsNothing,
          reason: '"$candidate" advanced past the email step',
        );
        expect(
          requested,
          isEmpty,
          reason: '"$candidate" reached onRequestCode',
        );
        expect(
          find.text('Enter a valid email address.'),
          findsOneWidget,
          reason: '"$candidate" produced no visible validation error',
        );
      }

      // The same form still accepts a legitimate address, so the guard is a
      // filter rather than a wall.
      await _enterText(tester, emailField, 'person@example.com');
      await _tapButton(tester, requestButton);
      await _pumpUntil(
        tester,
        () => find.byKey(codeField).evaluate().isNotEmpty,
        reason: 'a valid address was rejected too',
        diagnose: () =>
            'email field="${_textOf(tester, emailField)}" requested=$requested '
            'validationErrorShown='
            '${find.text('Enter a valid email address.').evaluate().isNotEmpty}',
      );
      expect(requested, ['person@example.com']);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'the OTP validator is digits-only, not int.tryParse',
    (tester) async {
      final submitted = <String>[];
      final harness = _AuthFormHarness(
        requestedEmails: <String>[],
        submitted: submitted,
      );
      await tester.pumpWidget(harness);
      await tester.pump();

      await tester.enterText(find.byKey(emailField), 'person@example.com');
      await tester.tap(find.byKey(requestButton));
      await _pumpUntil(
        tester,
        () => find.byKey(codeField).evaluate().isNotEmpty,
        reason: 'could not reach the code step',
      );

      final codeController = tester
          .state<_AuthFormHarnessState>(find.byType(_AuthFormHarness))
          .code;

      // `+12345` and `-12345` are exactly the trap: both are six characters
      // and `int.tryParse` returns a number for each, so a naive check would
      // let them through. They are set on the controller directly because the
      // field's digitsOnly input formatter strips the sign when typed — the
      // controller path is what autofill and state restoration use.
      const parseableButNotDigits = ['+12345', '-12345'];
      for (final candidate in parseableButNotDigits) {
        expect(
          int.tryParse(candidate),
          isNotNull,
          reason: '"$candidate" must be int-parseable for this test to matter',
        );
        expect(candidate.length, 6);

        codeController.text = candidate;
        await tester.pump();
        await tester.tap(find.byKey(verifyButton));
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          submitted,
          isEmpty,
          reason: '"$candidate" was submitted as a one-time code',
        );
        expect(
          find.text('Enter the 6-digit code from the email.'),
          findsOneWidget,
          reason: '"$candidate" produced no visible validation error',
        );
      }

      // Short, empty, and non-digit values are refused too.
      for (final candidate in ['', '123', '12ab56']) {
        codeController.text = candidate;
        await tester.pump();
        await tester.tap(find.byKey(verifyButton));
        await tester.pump(const Duration(milliseconds: 300));
        expect(submitted, isEmpty, reason: '"$candidate" was submitted');
      }

      // Six real digits go through, proving the assertions above are not
      // passing because the button is simply inert.
      codeController.text = '123456';
      await tester.pump();
      await tester.tap(find.byKey(verifyButton));
      await _pumpUntil(
        tester,
        () => submitted.isNotEmpty,
        reason: 'a valid 6-digit code was never submitted',
      );
      expect(submitted, ['person@example.com|123456']);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
