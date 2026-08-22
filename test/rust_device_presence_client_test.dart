import 'dart:async';
import 'dart:convert';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/services/rust_device_presence_client.dart';
import 'package:audio_dashcam/src/services/rust_presence_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakePresenceChannel implements RustPresenceChannel {
  final Completer<void> readyCompleter = Completer<void>();
  final StreamController<dynamic> inbound = StreamController<dynamic>.broadcast(
    sync: true,
  );
  final List<Object> sent = <Object>[];
  bool closed = false;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  Stream<dynamic> get stream => inbound.stream;

  @override
  void add(Object data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
  }
}

Future<void> _flushAsyncCallbacks() => Future<void>.delayed(Duration.zero);

void main() {
  test('builds a secure Rust device presence websocket URL', () {
    final uri = RustDevicePresenceClient.presenceUri(
      const AppConfig(
        deviceId: 'device-a',
        backendBaseUrl: 'https://api.sonusauris.app/base',
      ),
    );

    expect(uri.scheme, 'wss');
    expect(uri.host, 'api.sonusauris.app');
    expect(uri.path, '/base/api/mobile/v1/devices/presence');
    expect(uri.query, isEmpty);
  });

  test('rejects insecure non-loopback Rust presence endpoints', () {
    expect(
      () => RustDevicePresenceClient.presenceUri(
        const AppConfig(
          deviceId: 'device-a',
          backendBaseUrl: 'http://api.example.test',
        ),
      ),
      throwsFormatException,
    );
    for (final url in [
      'https://user:secret@api.example.test',
      'https://api.example.test?redirect=wss://attacker.invalid',
      'https://api.example.test/#fragment',
      'https://api.example.test/base/../other',
    ]) {
      expect(
        () => RustDevicePresenceClient.presenceUri(
          AppConfig(deviceId: 'device-a', backendBaseUrl: url),
        ),
        throwsFormatException,
        reason: url,
      );
    }
  });

  test('parses bounded online device IDs from Rust presence frames', () {
    expect(
      rustOnlineDeviceIds({
        'type': 'presence',
        'onlineDeviceIds': ['a', 'b', '', 7, 'a'],
      }),
      {'a', 'b'},
    );
    expect(rustOnlineDeviceIds({'type': 'ready'}), isEmpty);

    final many = List<String>.generate(300, (index) => 'device-$index');
    final bounded = rustOnlineDeviceIds({'onlineDeviceIds': many});
    expect(bounded, hasLength(256));
    expect(bounded, isNot(contains('device-256')));
    expect(
      rustOnlineDeviceIds({
        'onlineDeviceIds': ['x' * 129, 'bounded-device'],
      }),
      {'bounded-device'},
    );
  });

  test('replacement connection ignores stale readiness failure', () async {
    final channels = <_FakePresenceChannel>[];
    final client = RustDevicePresenceClient(
      channelFactory: (_) {
        final channel = _FakePresenceChannel();
        channels.add(channel);
        return channel;
      },
    );

    client.connect(
      config: const AppConfig(
        deviceId: 'device-a',
        backendBaseUrl: 'https://api-a.example.test',
      ),
      secrets: const CloudSecrets(backendDeviceToken: 'token-a'),
    );
    final first = channels.single;
    final firstGeneration = client.lifecycle.generation;

    client.connect(
      config: const AppConfig(
        deviceId: 'device-a',
        backendBaseUrl: 'https://api-b.example.test',
      ),
      secrets: const CloudSecrets(backendDeviceToken: 'token-b'),
    );
    final second = channels.last;
    expect(first.closed, isTrue);
    expect(client.lifecycle.generation, greaterThan(firstGeneration));
    expect(client.lifecycle.phase, RustPresencePhase.connecting);

    first.readyCompleter.completeError(StateError('late failure'));
    await _flushAsyncCallbacks();
    expect(client.lifecycle.phase, RustPresencePhase.connecting);
    expect(second.closed, isFalse);
    expect(second.sent, isEmpty);

    second.readyCompleter.complete();
    await _flushAsyncCallbacks();
    expect(client.lifecycle.phase, RustPresencePhase.authenticating);
    expect(second.sent, hasLength(1));
    expect(jsonDecode(second.sent.single as String), {
      'type': 'authenticate',
      'deviceToken': 'token-b',
    });

    second.inbound.add(jsonEncode(const {'type': 'presence'}));
    expect(client.lifecycle.phase, RustPresencePhase.authenticating);
    second.inbound.add(jsonEncode(const {'type': 'ready'}));
    expect(client.lifecycle.phase, RustPresencePhase.connected);

    client.close();
    expect(client.lifecycle.phase, RustPresencePhase.closed);
    expect(second.closed, isTrue);
    await client.dispose();
  });
}
