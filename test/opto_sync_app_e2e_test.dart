import 'package:audio_dashcam/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('branded loading frame renders before native services start', (
    tester,
  ) async {
    await tester.pumpWidget(
      AudioDashcamRoot(
        controllerBootstrapDelay: const Duration(seconds: 1),
        controllerFactory: () => throw StateError('controller should be delayed'),
      ),
    );

    expect(find.byType(LoadingPage), findsOneWidget);
    expect(find.text('Sonus Auris'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 999));
    expect(find.byType(LoadingPage), findsOneWidget);
    expect(find.byType(ErrorPage), findsNothing);

    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(ErrorPage), findsOneWidget);
    expect(find.textContaining('controller should be delayed'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sync or service bootstrap failure is contained in the app shell', (
    tester,
  ) async {
    await tester.pumpWidget(
      AudioDashcamRoot(
        controllerFactory: () => throw StateError('sync bootstrap failed'),
      ),
    );

    // The first frame must remain branded and permission-free.
    expect(find.byType(LoadingPage), findsOneWidget);
    expect(find.byType(ErrorPage), findsNothing);

    await tester.pump();
    expect(find.byType(ErrorPage), findsOneWidget);
    expect(find.textContaining('sync bootstrap failed'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('error page preserves the Sonus identity and readable failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ErrorPage(error: 'authoritative checkpoint rejected'),
      ),
    );

    expect(find.text('Sonus Auris'), findsOneWidget);
    expect(find.text('authoritative checkpoint rejected'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });
}
