import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/supabase_session.dart';
import 'package:audio_dashcam/src/services/supabase_auth_client.dart';
import 'package:audio_dashcam/src/widgets/supabase_auth_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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
    'browser obtains real AAL1 through Shared Auth but keeps account data locked',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: _BrowserAuthHarness())),
      );

      await tester.enterText(
        find.byKey(const ValueKey('supabase-email-field')),
        _email,
      );
      await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('supabase-code-field')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('supabase-code-field')),
        _testCode,
      );
      await tester.tap(find.byKey(const ValueKey('supabase-verify-button')));

      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('browser-aal1-locked')),
        timeout: const Duration(seconds: 60),
      );
      expect(find.textContaining(_email), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-account-data')), findsNothing);
    },
    skip:
        _email.isEmpty ||
        _supabaseUrl.isEmpty ||
        _supabaseKey.isEmpty ||
        _bridgeUrl.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

final class _BrowserAuthHarness extends StatefulWidget {
  const _BrowserAuthHarness();

  @override
  State<_BrowserAuthHarness> createState() => _BrowserAuthHarnessState();
}

final class _BrowserAuthHarnessState extends State<_BrowserAuthHarness> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  late final SupabaseAuthClient _client;
  late final AppConfig _config;
  SupabaseSession? _session;
  String _status = 'Enter the isolated synthetic test identity.';

  @override
  void initState() {
    super.initState();
    _client = SharedAuthTestClient(bridgeUrl: _bridgeUrl);
    _config = const AppConfig(
      deviceId: 'shared-auth-browser-e2e',
      supabaseUrl: _supabaseUrl,
      supabaseAnonKey: _supabaseKey,
    );
  }

  @override
  void dispose() {
    _client.close();
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sonus Auris browser authentication test'),
            const SizedBox(height: 16),
            SupabaseAuthForm(
              emailController: _emailController,
              codeController: _codeController,
              onRequestCode: _requestCode,
              onSubmitCode: _submitCode,
            ),
            const SizedBox(height: 16),
            Text(_status, key: const ValueKey('browser-auth-status')),
            if (session != null && session.aal == 'aal1')
              Text(
                'AAL1 verified for ${session.email}; account data remains '
                'locked until AAL2 is completed in the mobile or desktop app.',
                key: const ValueKey('browser-aal1-locked'),
              ),
            if (session?.isPasswordlessAal2 ?? false)
              const Text('Account data', key: ValueKey('browser-account-data')),
          ],
        ),
      ),
    );
  }

  Future<bool> _requestCode(String email) async {
    await _client.sendEmailOtp(
      config: _config,
      email: email,
      codeVerifier: 'integration-test-bridge-does-not-use-pkce',
    );
    if (mounted) {
      setState(() => _status = 'The deterministic test code is ready.');
    }
    return true;
  }

  Future<void> _submitCode(String email, String code) async {
    final session = await _client.verifyEmailOtp(
      config: _config,
      email: email,
      code: code,
    );
    if (session.aal != 'aal1' || !session.hasPasswordlessFirstFactor) {
      throw StateError(
        'The browser test realm did not return passwordless AAL1.',
      );
    }
    if (mounted) {
      setState(() {
        _session = session;
        _status = 'First factor verified; mandatory MFA remains enforced.';
      });
    }
  }
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
