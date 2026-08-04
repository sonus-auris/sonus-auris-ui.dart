// Sonus Auris console — desktop (macOS/Windows/Linux) + web + mobile web from
// one codebase. The phone app records; this app views and controls every
// device on the account, manages the plan, and handles account security.
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'src/config/console_config.dart';
import 'src/services/console_controller.dart';
import 'src/theme/console_theme.dart';
import 'src/ui/console_scaffold.dart';
import 'src/util/browser_url.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SonusConsoleApp());
}

class SonusConsoleApp extends StatefulWidget {
  const SonusConsoleApp({super.key});

  @override
  State<SonusConsoleApp> createState() => _SonusConsoleAppState();
}

class _SonusConsoleAppState extends State<SonusConsoleApp> {
  late final ConsoleController _controller;
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _appLinkSubscription;
  final Set<String> _handledAuthLinks = <String>{};

  @override
  void initState() {
    super.initState();
    _controller = ConsoleController(
      config: const ConsoleConfig.fromEnvironment(),
    );
    // Instantiate before async bootstrap so cold-start links are retained.
    _appLinks = AppLinks();
    _appLinkSubscription = _appLinks.uriLinkStream.listen(
      _acceptAppLink,
      onError: (_) {},
    );
    _initialize();
  }

  Future<void> _initialize() async {
    await _controller.bootstrap();
    final initial = await _appLinks.getInitialLink();
    if (initial != null) {
      await _acceptAppLink(initial);
    }
  }

  /// How many delivered callback URIs the replay guard remembers. Deep links
  /// arrive over an OS channel any local application can write to, so the set
  /// is bounded rather than grown once per delivered URI.
  static const int _maxRememberedAuthLinks = 32;

  Future<void> _acceptAppLink(Uri link) async {
    if (!_handledAuthLinks.add(link.toString())) return;
    while (_handledAuthLinks.length > _maxRememberedAuthLinks) {
      _handledAuthLinks.remove(_handledAuthLinks.first); // oldest first
    }
    final accepted = await _controller.acceptMagicLink(link);
    if (accepted) clearBrowserAuthFragment();
  }

  @override
  void dispose() {
    _appLinkSubscription?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sonus Auris Console',
      debugShowCheckedModeBanner: false,
      theme: consoleTheme(Brightness.light),
      darkTheme: consoleTheme(Brightness.dark),
      home: ConsoleScaffold(controller: _controller),
    );
  }
}
