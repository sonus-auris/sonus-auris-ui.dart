import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_dashcam/main.dart';

void main() {
  testWidgets('Sonus Auris paints a responsive loading frame before plugin bootstrap', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const AudioDashcamRoot(controllerBootstrapDelay: Duration(days: 1)),
    );
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'Sonus Auris');
    expect(find.byType(Scaffold), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('controller construction failures become an explicit error page', (tester) async {
    await tester.pumpWidget(
      AudioDashcamRoot(
        controllerFactory: () => throw StateError('synthetic bootstrap failure'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('synthetic bootstrap failure'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
