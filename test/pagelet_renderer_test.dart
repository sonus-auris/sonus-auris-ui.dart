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

Map<Object?, Object?> _fixtureAction(
  Map<String, Object?> json,
  String actionId,
) {
  final components = json['components']! as List;
  final section = components.single as Map;
  final children = section['children']! as List;
  final button = children.cast<Map>().singleWhere((component) {
    final action = component['action'];
    return action is Map && action['id'] == actionId;
  });
  return button['action']! as Map;
}

void main() {
  test('parses the complete canonical device-summary fixture', () {
    final pagelet = PageletDocument.fromJson(_fixture());
    final children = pagelet.components.single.children;

    expect(pagelet.surface, PageletSurface.deviceSummary);
    expect(children.length, 6);
    expect(
      children.singleWhere((component) => component.id == 'open-devices').action?.kind,
      PageletActionKind.navigate,
    );
    expect(
      children.singleWhere((component) => component.id == 'refresh-summary').action?.kind,
      PageletActionKind.refresh,
    );
  });

  test('rejects a remotely invented native operation', () {
    final json = _fixture();
    _fixtureAction(json, 'open-devices-screen')['kind'] =
        'native.execute-shell';

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

  testWidgets('renders every canonical status and dispatches both typed actions', (
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
    expect(find.text('Cloud backup connected'), findsOneWidget);

    await tester.tap(find.text('Manage devices'));
    expect(dispatched?.kind, PageletActionKind.navigate);
    expect(dispatched?.params['route'], 'devices');

    await tester.tap(find.text('Refresh status'));
    expect(dispatched?.kind, PageletActionKind.refresh);
    expect(dispatched?.params, isEmpty);
  });

  testWidgets('blocks a compiled action that is not allowed on the surface', (
    tester,
  ) async {
    final json = _fixture();
    _fixtureAction(json, 'open-devices-screen')['kind'] =
        'native.open-allowlisted-url';
    final pagelet = PageletDocument.fromJson(json);
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

    expect(find.text('Shared content unavailable.'), findsOneWidget);
    expect(find.text('Manage devices'), findsNothing);
    expect(find.text('Refresh status'), findsNothing);
    expect(dispatched, isNull);
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
