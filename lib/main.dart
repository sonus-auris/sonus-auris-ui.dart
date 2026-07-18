// Sonus Auris console — desktop (macOS/Windows/Linux) + web + mobile web from
// one codebase. The phone app records; this app views and controls every
// device on the account, manages the plan, and handles account security.
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

  @override
  void initState() {
    super.initState();
    _controller = ConsoleController(config: const ConsoleConfig.fromEnvironment());
    _controller.bootstrap();
  }

  @override
  void dispose() {
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
