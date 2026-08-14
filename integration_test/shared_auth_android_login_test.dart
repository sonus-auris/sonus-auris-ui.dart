import 'package:audio_dashcam/main.dart';
import 'package:audio_dashcam/src/app/app_controller.dart';
import 'package:audio_dashcam/src/services/settings_store.dart';
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
const _mfaMethod = String.fromEnvironment(
  'SONUS_TEST_MFA_METHOD',
  defaultValue: 'totp',
);
const _phone = String.fromEnvironment('SONUS_TEST_PHONE');
const _viewport = String.fromEnvironment(
  'SONUS_TEST_VIEWPORT',
  defaultValue: 'portrait',
);
const _testCode = '424242';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'full Flutter app signs in through Shared Auth and completes mandatory AAL2',
    (tester) async {
      var stage = 'boot';
      final previousFlutterError = FlutterError.onError;
      FlutterError.onError = (details) {
        stage = 'flutter-error: ${details.exceptionAsString()}';
        previousFlutterError?.call(details);
      };
      addTearDown(() => FlutterError.onError = previousFlutterError);
      addTearDown(() {
        binding.reportData = {'last_stage': stage};
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = _viewport == 'landscape'
          ? const Size(844, 390)
          : const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
      // The app replaces its branded loading route with onboarding once the
      // controller is ready. Android can expose the incoming route before that
      // replacement animation has fully retired the old route, so wait for the
      // navigator to settle before interacting with stateful form controls.
      await tester.pumpAndSettle();
      stage = 'welcome-visible';
      await tester.tap(find.text('Continue'));

      final requestButton = find.byKey(
        const ValueKey('supabase-request-button'),
      );
      await _pumpUntilEnabled(tester, requestButton);
      stage = 'sign-in-form-visible';
      final emailField = find.byKey(const ValueKey('supabase-email-field'));
      await _enterText(tester, emailField, _email);

      final codeField = find.byKey(const ValueKey('supabase-code-field'));
      // Android's test IME may deliver the field's `done` action after text
      // entry. That legitimately submits the form and briefly replaces the
      // current step. Wait for either the next step or an enabled action rather
      // than assuming one of them exists in the very next frame.
      await _submitStepIfNeeded(
        tester,
        action: requestButton,
        nextStep: codeField,
      );
      stage = 'email-code-form-visible';
      final enrollmentButton = find.byKey(
        ValueKey(
          _mfaMethod == 'phone'
              ? 'mandatory-mfa-phone-button'
              : 'mandatory-mfa-totp-button',
        ),
      );
      await _enterText(tester, codeField, _testCode);
      final verifyButton = find.byKey(const ValueKey('supabase-verify-button'));
      await _submitStepIfNeeded(
        tester,
        action: verifyButton,
        nextStep: enrollmentButton,
      );

      // The deterministic first factor must stop at AAL1. The test then drives
      // the ordinary MFA enrollment UI; only submitting 424242 is intercepted
      // by the integration-only client and exchanged for a genuine AAL2 token.
      stage = 'mandatory-mfa-visible';
      expect(
        find.byKey(const ValueKey('onboarding-signed-in-state')),
        findsNothing,
      );
      if (_mfaMethod == 'phone') {
        await _enterText(
          tester,
          find.byKey(const ValueKey('mandatory-mfa-phone-field')),
          _phone,
        );
      }
      await _pressEnabledButton(tester, enrollmentButton);

      final mfaCodeField = find.byKey(
        const ValueKey('mandatory-mfa-code-field'),
      );
      await _pumpUntil(tester, mfaCodeField);
      stage = 'mfa-code-form-visible';
      await _enterText(tester, mfaCodeField, _testCode);
      stage = 'mfa-code-entered';
      final mfaVerify = find.byKey(
        const ValueKey('mandatory-mfa-enrollment-verify-button'),
      );
      final consentStep = find.text('What you consent to');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      stage = 'mfa-verify-ready';
      await _submitStepIfNeeded(
        tester,
        action: mfaVerify,
        nextStep: consentStep,
      );
      stage = 'mfa-verify-submitted';

      try {
        await _pumpUntil(
          tester,
          consentStep,
          timeout: const Duration(seconds: 60),
        );
      } catch (error) {
        stage = 'signed-in-wait-failed: $error';
        rethrow;
      }
      stage = 'signed-in';
      // Successful mandatory AAL2 calls `onAuthorized`, which advances the
      // onboarding wizard immediately past the account step.
      expect(find.text('What you consent to'), findsOneWidget);
    },
    skip:
        _email.isEmpty ||
        _supabaseUrl.isEmpty ||
        _supabaseKey.isEmpty ||
        _bridgeUrl.isEmpty ||
        !const {'portrait', 'landscape'}.contains(_viewport) ||
        !const {'totp', 'phone'}.contains(_mfaMethod) ||
        (_mfaMethod == 'phone' && _phone.isEmpty),
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

Future<void> _enterText(
  WidgetTester tester,
  Finder finder,
  String value,
) async {
  await tester.ensureVisible(finder);
  final editableFinder = find.descendant(
    of: finder,
    matching: find.byType(EditableText),
  );
  final editable = tester.widget<EditableText>(editableFinder);
  final controller = editable.controller;
  // Drive the same controller that backs the platform text field. Invoking the
  // Android test IME here can deliver a delayed `done` action while the app's
  // home route is rebuilding from a new view model, making an otherwise valid
  // field become inactive between hit testing and entry.
  controller.value = TextEditingValue(
    text: value,
    selection: TextSelection.collapsed(offset: value.length),
  );
  await tester.pump();
  expect(controller.text, value);
}

Future<void> _pressEnabledButton(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  final button = tester.widget<ButtonStyleButton>(finder);
  final onPressed = button.onPressed;
  if (onPressed == null) {
    throw StateError('Expected an enabled control: $finder');
  }
  onPressed();
  await tester.pump();
}

Future<void> _submitStepIfNeeded(
  WidgetTester tester, {
  required Finder action,
  required Finder nextStep,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  var submitted = false;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (nextStep.evaluate().isNotEmpty) return;
    if (!submitted && action.evaluate().isNotEmpty) {
      final button = tester.widget<ButtonStyleButton>(action);
      if (button.onPressed != null) {
        await _pressEnabledButton(tester, action);
        submitted = true;
      }
    }
  }
  throw StateError(
    'Timed out waiting for the next step after ${submitted ? 'submitting' : 'waiting for'} the current action: '
    '$action -> $nextStep. Visible non-sensitive text: '
    '${_visibleDiagnosticText(tester)}',
  );
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
  throw StateError(
    'Timed out waiting for $finder. Visible non-sensitive text: '
    '${_visibleDiagnosticText(tester)}',
  );
}

List<String> _visibleDiagnosticText(WidgetTester tester) {
  final values = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final text = element.widget as Text;
    final value = (text.data ?? text.textSpan?.toPlainText() ?? '').trim();
    if (value.isEmpty ||
        value.length > 160 ||
        value.contains('@') ||
        value.contains('otpauth') ||
        RegExp(r'\b[0-9]{6}\b').hasMatch(value)) {
      continue;
    }
    if (!values.contains(value)) values.add(value);
    if (values.length == 20) break;
  }
  return values;
}
