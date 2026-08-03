import 'dart:convert';
import 'dart:io';

import 'package:audio_dashcam/src/pagelets/pagelet_model.dart';
import 'package:audio_dashcam/src/pagelets/pagelet_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _fixture() {
  final raw = File(
    'test/fixtures/pagelets/device-summary.json',
  ).readAsStringSync();
  return (jsonDecode(raw) as Map).cast<String, Object?>();
}

void main() {
  test('parses the canonical device-summary fixture', () {
    final pagelet = PageletDocument.fromJson(_fixture());

    expect(pagelet.surface, PageletSurface.deviceSummary);
    expect(pagelet.components.single.children.length, 4);
    expect(
      pagelet.components.single.children.last.action?.kind,
      PageletActionKind.navigate,
    );
  });

  test('rejects a remotely invented native operation', () {
    final json = _fixture();
    final components = json['components']! as List;
    final section = components.single as Map;
    final children = section['children']! as List;
    final button = children.last as Map;
    final action = button['action']! as Map;
    action['kind'] = 'native.execute-shell';

    expect(
      () => PageletDocument.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects unknown fields instead of silently accepting drift', () {
    final json = _fixture()..['script'] = 'doSomethingDangerous()';

    expect(
      () => PageletDocument.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  testWidgets('renders bundled native widgets and dispatches typed actions', (
    tester,
  ) async {
    final pagelet = PageletDocument.fromJson(_fixture());
    PageletAction? dispatched;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageletRenderer(
            document: pagelet,
            onAction: (action) => dispatched = action,
          ),
        ),
      ),
    );

    expect(find.text('This device'), findsOneWidget);
    expect(find.text("Alex's MacBook"), findsOneWidget);
    expect(find.text('Recording protection is active'), findsOneWidget);
    expect(find.text('100 hours'), findsOneWidget);

    await tester.tap(find.text('Manage devices'));
    expect(dispatched?.kind, PageletActionKind.navigate);
    expect(dispatched?.params['route'], 'devices');
  });

  testWidgets('uses a bundled fallback when remote content is unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PageletSurfaceView(
            document: null,
            error: 'offline',
            onAction: null,
            fallback: Text('Bundled device status'),
          ),
        ),
      ),
    );

    expect(find.text('Bundled device status'), findsOneWidget);
    expect(find.byType(PageletRenderer), findsNothing);
  });
}
