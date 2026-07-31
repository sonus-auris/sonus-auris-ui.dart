import 'package:audio_dashcam/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'explicit debug override reaches local-only onboarding without an account',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const AudioDashcamRoot());

      await _pumpUntil(tester, find.text('Welcome to Sonus Auris'));
      await tester.tap(find.text('Continue'));
      await _pumpUntil(tester, find.text('Temporary offline development mode'));

      expect(find.byType(TextField), findsAtLeastNWidgets(1));
      expect(find.textContaining('Password'), findsNothing);
      expect(find.text('Continue offline (development)'), findsOneWidget);

      await tester.tap(find.text('Continue offline (development)'));
      await _pumpUntil(tester, find.text('What you consent to'));
      expect(find.textContaining('Microphone & audio recording'), findsWidgets);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    final startupError = find.byType(ErrorPage);
    if (startupError.evaluate().isNotEmpty) {
      final page = tester.widget<ErrorPage>(startupError.first);
      fail('Sonus Auris startup failed during offline E2E: ${page.error}');
    }
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for ${finder.describeMatch(Plurality.many)}.');
}
