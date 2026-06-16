import 'dart:async';

import 'package:audio_dashcam/src/models/context_trigger.dart';
import 'package:audio_dashcam/src/services/context_trigger_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSource implements ContextTriggerSource {
  _FakeSource(this.kind);

  @override
  final ContextTriggerKind kind;

  final StreamController<ContextTriggerEvent> _controller =
      StreamController<ContextTriggerEvent>.broadcast();
  int startCount = 0;
  int stopCount = 0;

  bool get isStarted => startCount > stopCount;

  @override
  Stream<ContextTriggerEvent> get events => _controller.stream;

  @override
  Future<void> start() async => startCount++;

  @override
  Future<void> stop() async => stopCount++;

  void fire([String description = 'event']) {
    _controller.add(
      ContextTriggerEvent(kind: kind, description: description),
    );
  }
}

void main() {
  test('runs only the requested sources when enabled and active', () async {
    final net = _FakeSource(ContextTriggerKind.networkChange);
    final bt = _FakeSource(ContextTriggerKind.bluetoothConnect);
    final service = ContextTriggerService(sources: [net, bt]);

    await service.update(
      enabled: true,
      kinds: {ContextTriggerKind.networkChange},
      active: true,
    );
    expect(net.isStarted, isTrue);
    expect(bt.isStarted, isFalse);

    // Leaving the window stops everything.
    await service.update(
      enabled: true,
      kinds: {ContextTriggerKind.networkChange},
      active: false,
    );
    expect(net.isStarted, isFalse);

    await service.dispose();
  });

  test('does not start sources when disabled', () async {
    final net = _FakeSource(ContextTriggerKind.networkChange);
    final service = ContextTriggerService(sources: [net]);
    await service.update(
      enabled: false,
      kinds: {ContextTriggerKind.networkChange},
      active: true,
    );
    expect(net.isStarted, isFalse);
    await service.dispose();
  });

  test('forwards events and debounces a burst of the same kind', () async {
    final net = _FakeSource(ContextTriggerKind.networkChange);
    final service = ContextTriggerService(
      sources: [net],
      debounce: const Duration(milliseconds: 200),
    );
    final received = <ContextTriggerEvent>[];
    service.onTrigger = received.add;
    await service.update(
      enabled: true,
      kinds: {ContextTriggerKind.networkChange},
      active: true,
    );

    net.fire('first');
    net.fire('second'); // within debounce window -> collapsed
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received.length, 1);
    expect(received.single.description, 'first');

    await Future<void>.delayed(const Duration(milliseconds: 250));
    net.fire('third'); // after debounce -> delivered
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received.length, 2);

    await service.dispose();
  });

  test('concurrent update() calls converge to the latest desired state',
      () async {
    final net = _FakeSource(ContextTriggerKind.networkChange);
    final service = ContextTriggerService(sources: [net]);
    // Fire several overlapping updates without awaiting; the serialized drain
    // must not double-start and must settle on the final state (active:false).
    final futures = [
      service.update(
        enabled: true,
        kinds: {ContextTriggerKind.networkChange},
        active: true,
      ),
      service.update(
        enabled: true,
        kinds: {ContextTriggerKind.networkChange},
        active: true,
      ),
      service.update(
        enabled: true,
        kinds: {ContextTriggerKind.networkChange},
        active: false,
      ),
    ];
    await Future.wait(futures);
    expect(net.isStarted, isFalse);
    expect(net.startCount, lessThanOrEqualTo(1));
    await service.dispose();
  });

  test('drops events that arrive after the window closes', () async {
    final net = _FakeSource(ContextTriggerKind.networkChange);
    final service = ContextTriggerService(sources: [net]);
    final received = <ContextTriggerEvent>[];
    service.onTrigger = received.add;
    await service.update(
      enabled: true,
      kinds: {ContextTriggerKind.networkChange},
      active: true,
    );
    await service.update(
      enabled: true,
      kinds: {ContextTriggerKind.networkChange},
      active: false,
    );
    net.fire();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received, isEmpty);
    await service.dispose();
  });
}
