// Top-level router: shows the passwordless sign-in flow until the user is fully
// signed in (aal2 when MFA is enrolled), then the console home.
import 'package:flutter/material.dart';

import '../services/console_controller.dart';
import 'console_home.dart';
import 'sign_in_screen.dart';

class ConsoleScaffold extends StatelessWidget {
  const ConsoleScaffold({super.key, required this.controller});

  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        switch (controller.phase) {
          case AuthPhase.loading:
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          case AuthPhase.signedOut:
          case AuthPhase.codeSent:
          case AuthPhase.mfaEnrollmentRequired:
          case AuthPhase.mfaRequired:
            return SignInScreen(controller: controller);
          case AuthPhase.signedIn:
            return ConsoleHome(controller: controller);
        }
      },
    );
  }
}
