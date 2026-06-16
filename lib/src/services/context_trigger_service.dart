// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../models/context_trigger.dart';
import 'diagnostic_log.dart';

/// A source of context-trigger events (connectivity, Wi-Fi, Bluetooth, …).
/// Sources are started/stopped on demand so nothing runs (and no battery is
/// spent on BLE scanning) outside an armed schedule window.
abstract class ContextTriggerSource {
  ContextTriggerKind get kind;

  /// Broadcast stream of events this source produces.
  Stream<ContextTriggerEvent> get events;

  /// Begin observing. Idempotent.
  Future<void> start();

  /// Stop observing and release resources. Idempotent.
  Future<void> stop();
}

/// Fans a configurable subset of [ContextTriggerSource]s into a single
/// [onTrigger] callback, debounced per kind so an event storm doesn't nag.
///
/// The owner (controller) decides *whether to act* on a trigger — this service
/// only governs which sensors are running and collapses noisy bursts.
class ContextTriggerService {
  ContextTriggerService({
    required List<ContextTriggerSource> sources,
    DiagnosticLog? diagnostics,
    Duration debounce = const Duration(seconds: 8),
  })  : _sources = {for (final s in sources) s.kind: s},
        _diagnostics = diagnostics,
        _debounce = debounce;

  final Map<ContextTriggerKind, ContextTriggerSource> _sources;
  final DiagnosticLog? _diagnostics;
  final Duration _debounce;

  final Map<ContextTriggerKind, StreamSubscription<ContextTriggerEvent>>
      _subscriptions = {};
  final Map<ContextTriggerKind, DateTime> _lastEmitted = {};

  void Function(ContextTriggerEvent event)? onTrigger;

  bool _enabled = false;
  bool _active = false;

  // Serialize reconciliation so concurrent update() calls (init / save / window
  // transition / record start-stop can overlap) can't double-start a source.
  // Each call records the latest desired state and chains a drain; the drain
  // applies whatever the newest desired state is.
  Future<void> _queue = Future<void>.value();
  ({bool enabled, Set<ContextTriggerKind> kinds, bool active})? _desired;

  /// True while any source is running.
  bool get isRunning => _subscriptions.isNotEmpty;

  /// Reconcile the running sources against the desired configuration.
  ///  - [enabled]: master switch.
  ///  - [kinds]: which sources the user armed.
  ///  - [active]: whether we're currently inside an armed schedule window.
  /// Sources run only when enabled && active && the kind is both requested and
  /// available.
  Future<void> update({
    required bool enabled,
    required Set<ContextTriggerKind> kinds,
    required bool active,
  }) {
    _desired = (enabled: enabled, kinds: Set.of(kinds), active: active);
    final next = _queue.then((_) => _drain());
    // Keep the chain alive even if a drain throws.
    _queue = next.catchError((_) {});
    return next;
  }

  Future<void> _drain() async {
    final desired = _desired;
    if (desired == null) {
      return; // a later update() already applied the newest state
    }
    _desired = null;
    _enabled = desired.enabled;
    _active = desired.active;
    final shouldRun = desired.enabled && desired.active;
    final wanted = shouldRun
        ? desired.kinds.where(_sources.containsKey).toSet()
        : <ContextTriggerKind>{};

    // Stop sources no longer wanted.
    for (final kind in _subscriptions.keys.toList()) {
      if (!wanted.contains(kind)) {
        await _stopKind(kind);
      }
    }
    // Start newly-wanted sources.
    for (final kind in wanted) {
      if (!_subscriptions.containsKey(kind)) {
        await _startKind(kind);
      }
    }
    if (wanted.isNotEmpty) {
      _diagnostics?.add(
        'Context triggers active: ${wanted.map((k) => k.wireName).join(', ')}.',
      );
    }
  }

  Future<void> _startKind(ContextTriggerKind kind) async {
    final source = _sources[kind];
    if (source == null) {
      return;
    }
    try {
      await source.start();
      _subscriptions[kind] = source.events.listen(
        _handleEvent,
        onError: (Object error) =>
            _diagnostics?.add('Context source ${kind.wireName} error: $error'),
      );
    } catch (error) {
      _diagnostics?.add('Context source ${kind.wireName} start failed: $error');
    }
  }

  Future<void> _stopKind(ContextTriggerKind kind) async {
    await _subscriptions.remove(kind)?.cancel();
    try {
      await _sources[kind]?.stop();
    } catch (_) {
      // best-effort
    }
  }

  void _handleEvent(ContextTriggerEvent event) {
    if (!_enabled || !_active) {
      return;
    }
    final last = _lastEmitted[event.kind];
    if (last != null && event.at.difference(last) < _debounce) {
      return; // collapse a burst of the same kind
    }
    _lastEmitted[event.kind] = event.at;
    _diagnostics?.add('Context trigger fired: $event');
    onTrigger?.call(event);
  }

  Future<void> dispose() async {
    for (final kind in _subscriptions.keys.toList()) {
      await _stopKind(kind);
    }
  }
}
