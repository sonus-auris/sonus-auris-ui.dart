import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonus_auris_console/src/config/console_config.dart';
import 'package:sonus_auris_console/src/services/auth_client.dart';

void main() {
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
