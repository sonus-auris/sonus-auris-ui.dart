import 'dart:convert';
import 'dart:io';

import 'package:audio_dashcam/src/pagelets/pagelet_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

String _fixture() => File(
      'test/fixtures/pagelets/device-summary-envelope.json',
    ).readAsStringSync();

Map<String, Object?> _fixtureJson() =>
    (jsonDecode(_fixture()) as Map).cast<String, Object?>();

void main() {
  final validNow = DateTime.utc(2030, 1, 1, 0, 1);

  test('accepts a bounded fresh compatible pagelet envelope', () {
    final envelope = PageletEnvelope.decode(_fixture(), now: validNow);

    expect(envelope.requestId, 'req_demo_request_0001');
    expect(envelope.host.platform, PageletHostPlatform.macos);
    expect(envelope.document.pageletId, 'device-summary');
  });

  test('rejects oversized envelopes before JSON parsing', () {
    expect(
      () => PageletEnvelope.decode(_fixture(), now: validNow, maxBytes: 32),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects unknown protocol versions and future or expired envelopes', () {
    final unknown = _fixtureJson()..['protocolVersion'] = '2.0.0';
    expect(
      () => PageletEnvelope.fromJson(unknown, now: validNow),
      throwsA(isA<FormatException>()),
    );

    final expired = _fixtureJson()
      ..['expiresAt'] = '2030-01-01T00:00:30Z';
    expect(
      () => PageletEnvelope.fromJson(expired, now: validNow),
      throwsA(isA<FormatException>()),
    );

    final future = _fixtureJson()
      ..['issuedAt'] = '2030-01-01T00:07:00Z'
      ..['expiresAt'] = '2030-01-01T00:08:00Z';
    expect(
      () => PageletEnvelope.fromJson(future, now: validNow),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects replayed request IDs and session nonces independently', () {
    final guard = PageletReplayGuard(capacity: 4);
    final first = PageletEnvelope.decode(_fixture(), now: validNow);
    guard.accept(first);

    final sameRequest = _fixtureJson()
      ..['sessionNonce'] = 'nonce_demo_session_0000000000000002';
    expect(
      () => guard.accept(PageletEnvelope.fromJson(sameRequest, now: validNow)),
      throwsA(isA<StateError>()),
    );

    final sameNonce = _fixtureJson()
      ..['requestId'] = 'req_demo_request_0002';
    expect(
      () => guard.accept(PageletEnvelope.fromJson(sameNonce, now: validNow)),
      throwsA(isA<StateError>()),
    );
  });

  test('replay guard remains bounded and evicts the oldest pair', () {
    final guard = PageletReplayGuard(capacity: 2);
    for (var index = 1; index <= 3; index += 1) {
      final json = _fixtureJson()
        ..['requestId'] = 'req_demo_request_000$index'
        ..['sessionNonce'] = 'nonce_demo_session_000000000000000$index';
      guard.accept(PageletEnvelope.fromJson(json, now: validNow));
    }

    final oldest = PageletEnvelope.decode(_fixture(), now: validNow);
    expect(() => guard.accept(oldest), returnsNormally);
  });

  test('Flutter consumes the canonical cross-client scenario inventory', () {
    final decoded = jsonDecode(
      File(
        'test/fixtures/pagelets/conformance-scenarios.json',
      ).readAsStringSync(),
    ) as Map<String, Object?>;
    final scenarios = decoded['scenarios']! as List<Object?>;
    final ids = scenarios
        .map((scenario) => (scenario! as Map<String, Object?>)['id']! as String)
        .toList(growable: false);

    expect(scenarios.length, greaterThanOrEqualTo(20));
    expect(ids.toSet().length, ids.length);
    expect(ids, contains('valid-confirmed-device-rename'));
    expect(ids, contains('replayed-session-nonce'));
    expect(ids, contains('offline-fallback'));
  });
}
