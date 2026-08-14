import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android routes only the exact Supabase callback to the main app', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final filter = RegExp(
      r'<intent-filter android:label="supabase_magic_link">([\s\S]*?)'
      r'</intent-filter>',
    ).firstMatch(manifest)?.group(1);

    expect(filter, isNotNull);
    expect(filter, contains('android:scheme="sonusauris"'));
    expect(filter, contains('android:host="auth"'));
    expect(filter, contains('android:path="/callback"'));
    expect(filter, isNot(contains('oauth')));
    expect(filter, isNot(contains('pathPrefix')));
  });

  test('Apple builds register the passwordless callback scheme', () {
    for (final path in ['ios/Runner/Info.plist', 'macos/Runner/Info.plist']) {
      final plist = File(path).readAsStringSync();
      expect(plist, contains('<key>CFBundleURLSchemes</key>'), reason: path);
      expect(plist, contains('<string>sonusauris</string>'), reason: path);
    }
  });

  test('Windows forwards magic links to the running desktop process', () {
    final runner = File('windows/runner/main.cpp').readAsStringSync();
    expect(runner, contains('#include "app_links/app_links_plugin_c_api.h"'));
    expect(
      runner,
      contains('RegisterUrlProtocol(L"sonusauris"'),
      reason: 'unpackaged Windows installs must claim the callback scheme',
    );
    expect(runner, contains('HKEY_CURRENT_USER'));
    expect(runner, contains('SendAppLinkToInstance()'));
  });

  test('Linux is single-instance and packages the callback MIME handler', () {
    final runner = File('linux/runner/my_application.cc').readAsStringSync();
    expect(runner, contains('G_APPLICATION_HANDLES_COMMAND_LINE'));
    expect(runner, contains('G_APPLICATION_HANDLES_OPEN'));
    expect(runner, contains('gtk_window_present'));

    final desktop = File(
      'linux/packaging/app.sonusauris.audio_dashcam.desktop',
    ).readAsStringSync();
    expect(desktop, contains('MimeType=x-scheme-handler/sonusauris;'));
    expect(desktop, contains('Exec=sonus_auris %U'));
  });

  test(
    'released clients share one exact callback and never accept URL tokens',
    () {
      final controller = File(
        'lib/src/app/app_controller.dart',
      ).readAsStringSync();
      final authClient = File(
        'lib/src/services/supabase_auth_client.dart',
      ).readAsStringSync();
      final web = File('lib/main_web.dart').readAsStringSync();

      expect(
        controller,
        contains("defaultValue: 'sonusauris://auth/callback'"),
      );
      expect(authClient, contains("containsKey('access_token')"));
      expect(authClient, contains("containsKey('refresh_token')"));
      expect(authClient, contains("'grant_type': 'pkce'"));
      expect(authClient, isNot(contains('sessionFromMagicLink')));
      expect(
        RegExp(r'await _requireExpectedIdentity\(').allMatches(web),
        hasLength(2),
        reason: 'web OTP and magic-link sessions must both bind the identity',
      );
    },
  );

  test('account authentication UI contains no password control', () {
    final form = File(
      'lib/src/widgets/supabase_auth_form.dart',
    ).readAsStringSync();
    final panel = File(
      'lib/src/widgets/supabase_auth_panel.dart',
    ).readAsStringSync();

    for (final source in [form, panel]) {
      expect(source, isNot(contains('visiblePassword')));
      expect(source, isNot(contains('signInWithPassword')));
      expect(source, isNot(contains("labelText: 'Password'")));
      expect(source, isNot(contains('passwordController')));
    }
  });

  test('account authentication UI advertises the code, not a magic link', () {
    // Both surfaces are 6-digit OTP flows: the request button reveals a code
    // field, and the emulator permission gate greps for the code wording. A
    // button offering a "sign-in link" therefore contradicts the screen it
    // opens, so neither widget may carry the retired magic-link copy.
    final form = File(
      'lib/src/widgets/supabase_auth_form.dart',
    ).readAsStringSync();
    final panel = File(
      'lib/src/widgets/supabase_auth_panel.dart',
    ).readAsStringSync();

    for (final source in [form, panel]) {
      expect(source, contains("'Email me a 6-digit code'"));
      expect(source, isNot(contains('Email me a sign-in link')));
      expect(source.toLowerCase(), isNot(contains('magic-link fallback')));
      expect(source.toLowerCase(), isNot(contains('email link is a fallback')));
    }
    final mfa = File(
      'lib/src/widgets/supabase_mfa_gate.dart',
    ).readAsStringSync();
    expect(mfa, contains('Email codes replace passwords'));
    expect(mfa, isNot(contains('Magic links replace passwords')));

    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('fixed top-level variable'));
    expect(readme, isNot(contains('must remain `{{ .x.y.Token }}`')));
  });

  test('onboarding has one forward action throughout account sign-in', () {
    final mobile = File('lib/main.dart').readAsStringSync();
    final controller = File(
      'lib/src/app/app_controller.dart',
    ).readAsStringSync();
    final mfa = File(
      'lib/src/widgets/supabase_mfa_gate.dart',
    ).readAsStringSync();

    expect(
      mobile,
      contains('if (!onAccountStep || (vm?.isSignedIn ?? false))'),
      reason:
          'the onboarding Continue button must stay hidden while the auth or '
          'MFA form owns the forward action',
    );
    expect(
      mobile,
      contains('onAuthorized: _advancePastAccountStep'),
      reason:
          'successful mandatory MFA verification must advance onboarding '
          'without asking the user to press Continue again',
    );
    expect(mobile, contains('Use a different account — sign out'));
    expect(controller, contains('String? get latestMessage'));
    expect(mfa, contains('_controllerErrorOr'));
    expect(mfa, contains("_newFactorName('authenticator')"));
    expect(mfa, contains("_newFactorName('phone')"));
    expect(mfa, isNot(contains("friendlyName: 'Authenticator'")));
    expect(mfa, isNot(contains("friendlyName: 'Phone'")));
    expect(mfa, contains('SnackBarBehavior.floating'));
    expect(mfa, contains('Scrollable.ensureVisible'));
    expect(mfa, contains('liveRegion: true'));
    expect(
      mfa,
      isNot(contains("throw StateError('Could not start phone enrollment.')")),
      reason: 'the MFA gate must display the decoded Supabase server error',
    );
  });

  test('offline escape hatch is structurally release-gated', () {
    final source = File(
      'lib/src/platform/offline_development_mode.dart',
    ).readAsStringSync();

    expect(source, contains("bool.fromEnvironment("));
    expect(source, contains("'SONUS_ENABLE_OFFLINE_MODE'"));
    expect(source, contains('!releaseMode && requested'));
  });
}
