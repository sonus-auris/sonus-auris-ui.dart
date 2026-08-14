import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:sonus_auris_console/src/config/console_config.dart';
import 'package:sonus_auris_console/src/services/auth_client.dart';
import 'package:sonus_auris_console/src/services/console_controller.dart';
import 'package:sonus_auris_console/src/ui/console_scaffold.dart';

import 'console_controller_test.dart' show FakeTokenStore;

const _config = ConsoleConfig(
  supabaseUrl: 'https://project.supabase.co',
  supabaseAnonKey: 'sb_publishable_test',
  authRedirectUrl: 'https://console.example/auth/callback',
);

void main() {
  testWidgets(
    'sign-in shows an email field with no password, enabling on input',
    (tester) async {
      var otpCalls = 0;
      final controller = ConsoleController(
        config: _config,
        tokenStore: FakeTokenStore(),
        authClient: AuthClient(
          config: _config,
          httpClient: MockClient((req) async {
            if (req.url.path == '/auth/v1/otp') otpCalls++;
            return http.Response('{}', 200);
          }),
        ),
      );
      await controller.bootstrap();

      await tester.pumpWidget(
        MaterialApp(home: ConsoleScaffold(controller: controller)),
      );
      await tester.pumpAndSettle();

      // Passwordless: an email field, and no password field anywhere.
      expect(find.widgetWithText(TextField, ''), findsWidgets);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsNothing);

      final button = find.widgetWithText(FilledButton, 'Email me a code');
      expect(button, findsOneWidget);
      expect(
        tester.widget<FilledButton>(button).onPressed,
        isNull,
      ); // disabled until valid

      await tester.enterText(find.byType(TextField).first, 'user@example.test');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(button).onPressed,
        isNotNull,
      ); // now enabled

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(otpCalls, 1);
      // Advanced to the code-entry step.
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('magic link'), findsNothing);
      expect(find.textContaining('email link'), findsNothing);
      final codeField = tester.widget<TextField>(find.byType(TextField).first);
      expect(codeField.maxLength, 6);

      await tester.enterText(find.byType(TextField).first, '1234567');
      await tester.pump();
      expect(codeField.controller?.text, '123456');
    },
  );
}
