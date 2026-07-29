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

void main() {
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
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _controller = ConsoleController(
      config: const ConsoleConfig.fromEnvironment(),
    );
    _appLinks = AppLinks();
    unawaited(_bootstrapAuth());
    _linkSubscription = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_controller.consumeMagicLink(uri)),
    );
  }

  Future<void> _bootstrapAuth() async {
    await _controller.bootstrap();
    final initialLink = await _appLinks.getInitialLink();
    if (initialLink != null) {
      await _controller.consumeMagicLink(initialLink);
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
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
