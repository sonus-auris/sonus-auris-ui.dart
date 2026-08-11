import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonus_auris_console/src/config/console_config.dart';
import 'package:sonus_auris_console/src/services/auth_client.dart';

void main() {
  test('current console email UX is strictly six-digit OTP-only', () {
    final signIn = File(
      'lib/src/ui/sign_in_screen.dart',
    ).readAsStringSync();
    final account = File(
      'lib/src/ui/account_screen.dart',
    ).readAsStringSync();
    final controller = File(
      'lib/src/services/console_controller.dart',
    ).readAsStringSync();
    final authClient = File(
      'lib/src/services/auth_client.dart',
    ).readAsStringSync();

    expect(signIn, contains('6-digit one-time code'));
    expect(signIn, contains('maxLength: 6'));
    expect(signIn, contains('length == 6'));
    expect(signIn, isNot(contains('email link')));
    expect(signIn, isNot(contains('magic link')));
    expect(signIn, isNot(contains('fallback')));
    expect(account, contains('Email codes replace passwords'));
    expect(account, isNot(contains('Magic links replace passwords')));
    expect(controller, contains('Request a fresh email code.'));
    expect(authClient, contains('Hosted templates render the numeric token'));

    // Keep the bounded validation path while already-issued links drain; it is
    // not advertised as part of the current email delivery contract.
    expect(controller, contains('acceptMagicLink'));
    expect(authClient, contains('exchangePkceCode'));
  });

  test('native console uses a dedicated exact magic-link callback', () {
    final client = AuthClient(
      config: const ConsoleConfig(
        supabaseUrl: 'https://project.supabase.co',
        supabaseAnonKey: 'sb_publishable_test',
      ),
    );
    expect(client.magicLinkRedirectUri, Uri.parse(kNativeConsoleAuthRedirect));
    expect(
      client.isExpectedMagicLinkCallback(
        Uri.parse('$kNativeConsoleAuthRedirect?code=one'),
      ),
      isTrue,
    );
    expect(
      client.isExpectedMagicLinkCallback(
        Uri.parse('sonusauris://auth/callback?code=one'),
      ),
      isFalse,
    );
  });

  test('every desktop target delivers the dedicated URL scheme', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('<string>sonusauris-console</string>'));

    final windows = File('windows/runner/main.cpp').readAsStringSync();
    expect(windows, contains('SendAppLinkToInstance()'));
    expect(windows, contains('#include "app_links/app_links_plugin_c_api.h"'));
    expect(
      windows,
      contains('RegisterUrlProtocol(L"sonusauris-console"'),
      reason: 'unpackaged Windows installs must claim the callback scheme',
    );
    expect(windows, contains('HKEY_CURRENT_USER'));

    final linux = File('linux/runner/my_application.cc').readAsStringSync();
    expect(linux, contains('G_APPLICATION_HANDLES_COMMAND_LINE'));
    expect(linux, contains('G_APPLICATION_HANDLES_OPEN'));
    expect(linux, contains('gtk_window_present'));

    final desktop = File(
      'linux/packaging/app.sonusauris.sonus_auris_console.desktop',
    ).readAsStringSync();
    expect(desktop, contains('MimeType=x-scheme-handler/sonusauris-console;'));
  });

  test('native callback listener is wired before controller bootstrap', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('AppLinks()'));
    expect(main, contains('uriLinkStream.listen'));
    expect(main, contains('getInitialLink()'));
    expect(main, isNot(contains('acceptMagicLink(Uri.base)')));
  });
}
