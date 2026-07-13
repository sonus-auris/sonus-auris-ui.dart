import 'package:audio_dashcam/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paints loading UI before constructing plugin-backed services', (
    tester,
  ) async {
    var factoryCalls = 0;

    await tester.pumpWidget(
      AudioDashcamRoot(
        controllerBootstrapDelay: const Duration(hours: 1),
        controllerFactory: () {
          factoryCalls += 1;
          throw StateError('controller construction should still be deferred');
        },
      ),
    );

    expect(find.byType(LoadingPage), findsOneWidget);
    expect(factoryCalls, 0);

    // Unmounting cancels the deferred bootstrap; no test-time plugin work leaks
    // beyond this first-frame regression.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(factoryCalls, 0);
  });
}
