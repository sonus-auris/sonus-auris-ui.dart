import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_dashcam/src/pagelets/pagelet_action_dispatcher.dart';
import 'package:audio_dashcam/src/pagelets/pagelet_model.dart';
import 'package:audio_dashcam/src/pagelets/pagelet_protocol.dart';
import 'package:audio_dashcam/src/pagelets/pagelet_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PageletDocument _renameDocument() {
  final raw = File(
    'test/fixtures/pagelets/device-summary-rename.json',
  ).readAsStringSync();
  return PageletDocument.fromJson(
    (jsonDecode(raw) as Map).cast<String, Object?>(),
  );
}

PageletAction _renameAction() =>
    _renameDocument().components.single.children.last.action!;

void main() {
  test('AAL2 plus native confirmation executes the typed rename mutation', () async {
    var confirmations = 0;
    var mutations = 0;
    var reads = 0;
    final dispatcher = PageletActionDispatcher(
      platform: PageletHostPlatform.macos,
      authorization: PageletAuthorizationState.aal2,
      confirm: (action) async {
        confirmations += 1;
        expect(action.params['deviceId'], 'device-demo-01');
        return true;
      },
      executeRead: (_) async => reads += 1,
      executeMutation: (action) async {
        mutations += 1;
        expect(action.params['proposedName'], 'Studio Recorder');
      },
    );

    final outcome = await dispatcher.dispatch(_renameAction());

    expect(outcome, PageletActionOutcome.completed);
    expect(confirmations, 1);
    expect(mutations, 1);
    expect(reads, 0);
  });

  test('denied confirmation never reaches the mutation callback', () async {
    var mutations = 0;
    final dispatcher = PageletActionDispatcher(
      platform: PageletHostPlatform.android,
      authorization: PageletAuthorizationState.aal2,
      confirm: (_) async => false,
      executeRead: (_) async {},
      executeMutation: (_) async => mutations += 1,
    );

    final outcome = await dispatcher.dispatch(_renameAction());

    expect(outcome, PageletActionOutcome.cancelled);
    expect(mutations, 0);
  });

  test('signed-in but non-AAL2 hosts cannot execute a rename', () async {
    final dispatcher = PageletActionDispatcher(
      platform: PageletHostPlatform.ios,
      authorization: PageletAuthorizationState.signedIn,
      confirm: (_) async => true,
      executeRead: (_) async {},
      executeMutation: (_) async {},
    );

    await expectLater(
      dispatcher.dispatch(_renameAction()),
      throwsA(isA<StateError>()),
    );
  });

  test('compiled parameter shape rejects extra or malformed values', () async {
    final source = _renameAction();
    final invalid = PageletAction(
      id: source.id,
      kind: source.kind,
      params: const {
        'deviceId': 'device-demo-01',
        'proposedName': '',
        'unexpected': 'value',
      },
      requiresConfirmation: true,
    );
    final dispatcher = PageletActionDispatcher(
      platform: PageletHostPlatform.linux,
      authorization: PageletAuthorizationState.aal2,
      confirm: (_) async => true,
      executeRead: (_) async {},
      executeMutation: (_) async {},
    );

    await expectLater(
      dispatcher.dispatch(invalid),
      throwsA(isA<StateError>()),
    );
  });

  testWidgets('native-rendered rename button uses confirmation dispatcher', (
    tester,
  ) async {
    var mutations = 0;
    final completed = Completer<void>();
    final dispatcher = PageletActionDispatcher(
      platform: PageletHostPlatform.macos,
      authorization: PageletAuthorizationState.aal2,
      confirm: (_) async => true,
      executeRead: (_) async {},
      executeMutation: (_) async => mutations += 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageletRenderer(
            document: _renameDocument(),
            onAction: (action) {
              unawaited(
                dispatcher.dispatch(action).then((_) {
                  if (!completed.isCompleted) completed.complete();
                }),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Rename this device'));
    await completed.future;
    await tester.pump();

    expect(mutations, 1);
  });
}
