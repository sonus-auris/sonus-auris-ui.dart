import 'dart:async';
import 'dart:convert';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/services/rust_device_presence_client.dart';
import 'package:audio_dashcam/src/services/rust_presence_lifecycle.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakePresenceChannel implements RustPresenceChannel {
  final Completer<void> readyCompleter = Completer<void>();
  final StreamController<dynamic> inbound = StreamController<dynamic>.broadcast(
    sync: true,
  );
  final List<Object> sent = <Object>[];
  int closeCalls = 0;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  Stream<dynamic> get stream => inbound.stream;

  @override
  void add(Object data) => sent.add(data);

  @override
  Future<void> close() async {
    closeCalls += 1;
  }
}

const _configA = AppConfig(
  deviceId: 'device-a',
  backendBaseUrl: 'https://api-a.example.test',
);
const _configB = AppConfig(
  deviceId: 'device-a',
  backendBaseUrl: 'https://api-b.example.test',
);
const _secretsA = CloudSecrets(backendDeviceToken: 'token-a');
const _secretsB = CloudSecrets(backendDeviceToken: 'token-b');

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

  test('rejects ambiguous or insecure non-loopback endpoints', () {
    for (final url in [
      'http://api.example.test',
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

  test('replacement ignores a stale readiness failure', () async {
    final channels = <_FakePresenceChannel>[];
    final client = RustDevicePresenceClient(
      channelFactory: (_) {
        final channel = _FakePresenceChannel();
        channels.add(channel);
        return channel;
      },
    );

    client.connect(config: _configA, secrets: _secretsA);
    final first = channels.single;
    final firstGeneration = client.lifecycle.generation;

    client.connect(config: _configB, secrets: _secretsB);
    final second = channels.last;
    expect(first.closeCalls, 1);
    expect(client.lifecycle.generation, greaterThan(firstGeneration));
    expect(client.lifecycle.phase, RustPresencePhase.connecting);

    first.readyCompleter.completeError(StateError('late failure'));
    await _flushAsyncCallbacks();
    expect(client.lifecycle.phase, RustPresencePhase.connecting);
    expect(second.closeCalls, 0);
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

    await client.dispose();
    expect(client.lifecycle.phase, RustPresencePhase.closed);
    expect(second.closeCalls, 1);
  });

  test('RxDart snapshot stream replays one bounded current state', () async {
    final channel = _FakePresenceChannel();
    final client = RustDevicePresenceClient(channelFactory: (_) => channel);

    client.connect(config: _configA, secrets: _secretsA);
    channel.readyCompleter.complete();
    await _flushAsyncCallbacks();
    channel.inbound.add(jsonEncode(const {'type': 'ready'}));
    channel.inbound.add(
      jsonEncode(const {
        'type': 'presence',
        'onlineDeviceIds': ['one', 'two'],
      }),
    );

    final lateSnapshot = await client.snapshots.first;
    expect(lateSnapshot.connected, isTrue);
    expect(lateSnapshot.onlineDeviceIds, {'one', 'two'});

    await client.dispose();
  });

  test('fake time proves finite retry exhaustion and zero residual timers', () {
    fakeAsync((async) {
      final channels = <_FakePresenceChannel>[];
      final client = RustDevicePresenceClient(
        channelFactory: (_) {
          final channel = _FakePresenceChannel();
          channels.add(channel);
          return channel;
        },
      );

      client.connect(config: _configA, secrets: _secretsA);
      for (
        var attempt = 1;
        attempt <= RustPresenceLifecycle.maxRetryAttempts;
        attempt += 1
      ) {
        channels.last.readyCompleter.completeError(StateError('unavailable'));
        async.flushMicrotasks();
        expect(client.lifecycle.phase, RustPresencePhase.waitingToRetry);
        expect(client.lifecycle.retryAttempt, attempt);
        expect(async.nonPeriodicTimerCount, 1);

        final expectedSeconds = [1, 2, 4, 8, 16, 32, 60][attempt - 1];
        async.elapse(Duration(seconds: expectedSeconds));
        expect(client.lifecycle.phase, RustPresencePhase.connecting);
        expect(channels, hasLength(attempt + 1));
      }

      channels.last.readyCompleter.completeError(StateError('unavailable'));
      async.flushMicrotasks();
      expect(client.lifecycle.phase, RustPresencePhase.retryExhausted);
      expect(channels, hasLength(8));
      expect(async.pendingTimers, isEmpty);

      unawaited(client.dispose());
      async.flushMicrotasks();
      expect(client.lifecycle.phase, RustPresencePhase.closed);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('close cancels heartbeat and observer failures cannot affect state', () {
    fakeAsync((async) {
      final channel = _FakePresenceChannel();
      final transitions = <RustPresenceInput>[];
      final client = RustDevicePresenceClient(
        channelFactory: (_) => channel,
        transitionObserver: (previous, input, transition) {
          transitions.add(input);
          throw StateError('metrics unavailable');
        },
      );

      client.connect(config: _configA, secrets: _secretsA);
      channel.readyCompleter.complete();
      async.flushMicrotasks();
      channel.inbound.add(jsonEncode(const {'type': 'ready'}));
      expect(client.lifecycle.phase, RustPresencePhase.connected);
      expect(async.periodicTimerCount, 1);

      final sentBeforeClose = channel.sent.length;
      client.close();
      expect(client.lifecycle.phase, RustPresencePhase.closed);
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(minutes: 2));
      expect(channel.sent, hasLength(sentBeforeClose));
      expect(transitions, [
        RustPresenceInput.configure,
        RustPresenceInput.transportReady,
        RustPresenceInput.authenticated,
        RustPresenceInput.close,
      ]);

      unawaited(client.dispose());
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });
}
