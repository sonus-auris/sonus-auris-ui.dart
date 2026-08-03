import 'dart:convert';
import 'dart:io';

import 'package:audio_dashcam/src/pagelets/pagelet_model.dart';
import 'package:audio_dashcam/src/pagelets/pagelet_policy.dart';
import 'package:audio_dashcam/src/pagelets/pagelet_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _read(String name) {
  final raw = File('test/fixtures/pagelets/$name').readAsStringSync();
  return (jsonDecode(raw) as Map).cast<String, Object?>();
}

Map<String, Object?> _document() => _read('device-summary.json');
Map<String, Object?> _renameDocument() =>
    _read('device-summary-rename.json');
Map<String, Object?> _envelope() => _read('device-summary-envelope.json');

List<Object?> _children(Map<String, Object?> document) {
  final components = document['components']! as List<Object?>;
  final section = (components.single! as Map).cast<String, Object?>();
  return section['children']! as List<Object?>;
}

Map<String, Object?> _lastAction(Map<String, Object?> document) {
  final button = (_children(document).last! as Map).cast<String, Object?>();
  return (button['action']! as Map).cast<String, Object?>();
}

Map<String, Object?> _deepCopy(Map<String, Object?> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();

void main() {
  final validNow = DateTime.utc(2030, 1, 1, 0, 1);

  test('rejects an unknown pagelet schema version', () {
    final json = _document()..['schemaVersion'] = '2.0.0';
    expect(
      () => PageletDocument.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects an unknown component type', () {
    final first = (_children(_document()).first! as Map).cast<String, Object?>();
    first['type'] = 'webview';
    final json = _document();
    final target = (_children(json).first! as Map).cast<String, Object?>();
    target['type'] = 'webview';
    expect(
      () => PageletDocument.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a mutation that omits native confirmation', () {
    final json = _renameDocument();
    _lastAction(json)['requiresConfirmation'] = false;
    final document = PageletDocument.fromJson(json);
    expect(PageletPolicy.violation(document), contains('requires native confirmation'));
  });

  test('rejects duplicate component IDs', () {
    final json = _document();
    final children = _children(json);
    children.add(jsonDecode(jsonEncode(children.first)));
    expect(
      () => PageletDocument.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects duplicate action IDs', () {
    final json = _document();
    final children = _children(json);
    final duplicate = _deepCopy(
      (children.last! as Map).cast<String, Object?>(),
    )..['id'] = 'manage-devices-copy';
    children.add(duplicate);
    expect(
      () => PageletDocument.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects nested action parameters', () {
    final json = _document();
    _lastAction(json)['params'] = <String, Object?>{
      'route': <String, Object?>{'nested': true},
    };
    expect(
      () => PageletDocument.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects excessive component depth', () {
    Map<String, Object?> node = <String, Object?>{
      'id': 'deep-text',
      'type': 'text',
      'text': 'too deep',
    };
    for (var depth = 9; depth >= 0; depth -= 1) {
      node = <String, Object?>{
        'id': 'section-$depth',
        'type': 'section',
        'children': <Object?>[node],
      };
    }
    final json = _document()
      ..['components'] = <Object?>[node];
    expect(
      () => PageletDocument.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects excessive root component count', () {
    final json = _document()
      ..['components'] = <Object?>[
        for (var index = 0; index < 65; index += 1)
          <String, Object?>{
            'id': 'item-$index',
            'type': 'text',
            'text': 'item $index',
          },
      ];
    expect(
      () => PageletDocument.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects an invalid request ID', () {
    final json = _envelope()..['requestId'] = 'request-1';
    expect(
      () => PageletEnvelope.fromJson(json, now: validNow),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects an invalid session nonce', () {
    final json = _envelope()..['sessionNonce'] = 'short';
    expect(
      () => PageletEnvelope.fromJson(json, now: validNow),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects malformed envelope JSON', () {
    expect(
      () => PageletEnvelope.decode('{', now: validNow),
      throwsA(anything),
    );
  });
}
