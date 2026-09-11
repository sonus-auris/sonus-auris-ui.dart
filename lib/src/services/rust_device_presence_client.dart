// Secondary live presence channel backed by the Rust API server.
//
// Supabase Presence is primary. This channel provides an independent fallback
// and refreshes the Rust server's durable device last_seen_at lease.
import 'dart:async';
import 'dart:convert';

import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import 'rust_presence_lifecycle.dart';

typedef RustPresenceWebSocketFactory = RustPresenceChannel Function(Uri uri);

abstract interface class RustPresenceChannel {
  Future<void> get ready;
  Stream<dynamic> get stream;
  void add(Object data);
  Future<void> close();
}

final class _WebSocketPresenceChannel implements RustPresenceChannel {
  _WebSocketPresenceChannel(this._delegate);

  final WebSocketChannel _delegate;

  @override
  Future<void> get ready => _delegate.ready;

  @override
  Stream<dynamic> get stream => _delegate.stream;

  @override
  void add(Object data) => _delegate.sink.add(data);

  @override
  Future<void> close() async {
    await _delegate.sink.close();
  }
}

class RustPresenceSnapshot {
  const RustPresenceSnapshot({
    this.connected = false,
    this.onlineDeviceIds = const <String>{},
  });

  final bool connected;
  final Set<String> onlineDeviceIds;
}

Set<String> rustOnlineDeviceIds(Object? payload) {
  if (payload is! Map || payload['onlineDeviceIds'] is! List) {
    return const <String>{};
  }
  final result = <String>{};
  for (final value in (payload['onlineDeviceIds'] as List).take(256)) {
    if (value is! String) continue;
    final id = value.trim();
    if (id.isEmpty || id.length > 128) continue;
    result.add(id);
  }
  return result;
}

class RustDevicePresenceClient {
  RustDevicePresenceClient({
    RustPresenceWebSocketFactory? channelFactory,
    this.transitionObserver,
  }) : _channelFactory =
           channelFactory ??
           ((uri) => _WebSocketPresenceChannel(WebSocketChannel.connect(uri)));

  static const _heartbeatInterval = Duration(seconds: 25);
  static const _maxFrameCharacters = 64 * 1024;

  final RustPresenceWebSocketFactory _channelFactory;
  final RustPresenceTransitionObserver? transitionObserver;
  final BehaviorSubject<RustPresenceSnapshot> _snapshots =
      BehaviorSubject<RustPresenceSnapshot>.seeded(
        const RustPresenceSnapshot(),
      );

  RustPresenceChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  AppConfig? _config;
  String _deviceToken = '';
  RustPresenceLifecycle _lifecycle = const RustPresenceLifecycle();

  ValueStream<RustPresenceSnapshot> get snapshots => _snapshots.stream;
  RustPresenceLifecycle get lifecycle => _lifecycle;

  static Uri presenceUri(AppConfig config) {
    final rawBase = config.backendBaseUrl.trim();
    final base = Uri.parse(rawBase);
    final hasDotSegment = RegExp(
      r'/(?:\.|%2e)(?:\.|%2e)?(?:/|$)',
      caseSensitive: false,
    ).hasMatch(rawBase);
    final loopback =
        base.host == 'localhost' ||
        base.host == '127.0.0.1' ||
        base.host == '::1';
    if (base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        hasDotSegment ||
        (base.scheme != 'https' && !(loopback && base.scheme == 'http'))) {
      throw const FormatException(
        'Backend presence requires HTTPS except loopback development.',
      );
    }
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      pathSegments: [
        ...base.pathSegments.where((part) => part.isNotEmpty),
        'api',
        'mobile',
        'v1',
        'devices',
        'presence',
      ],
      query: '',
      fragment: '',
    );
  }

  void connect({required AppConfig config, required CloudSecrets secrets}) {
    final token = secrets.backendDeviceToken.trim();
    if (config.backendBaseUrl.trim().isEmpty || token.isEmpty) {
      close();
      return;
    }
    final changed =
        _config?.backendBaseUrl != config.backendBaseUrl ||
        _deviceToken != token;
    _config = config;
    _deviceToken = token;
    if (changed ||
        _lifecycle.phase == RustPresencePhase.idle ||
        _lifecycle.phase == RustPresencePhase.closed ||
        _lifecycle.phase == RustPresencePhase.retryExhausted) {
      _dispatch(RustPresenceInput.configure);
    }
  }

  void close() {
    _dispatch(RustPresenceInput.close);
    _emit(const <String>{});
  }

  Future<void> dispose() async {
    close();
    await _snapshots.close();
  }

  void _dispatch(RustPresenceInput input, {int? eventGeneration}) {
    final previousState = _lifecycle;
    final transition = previousState.advance(
      input,
      eventGeneration: eventGeneration,
    );
    _lifecycle = transition.state;
    if (!transition.isStutter) {
      try {
        transitionObserver?.call(previousState, input, transition);
      } catch (_) {
        // Observability must never affect presence or audio recording.
      }
    }
    for (final effect in transition.effects) {
      _perform(effect);
    }
  }

  void _perform(RustPresenceEffect effect) {
    switch (effect) {
      case RustPresenceEffect.closeTransport:
        _closeTransport();
      case RustPresenceEffect.openTransport:
        _openTransport();
      case RustPresenceEffect.sendAuthentication:
        _sendAuthentication();
      case RustPresenceEffect.startHeartbeat:
        _startHeartbeat();
      case RustPresenceEffect.sendHeartbeat:
        _sendHeartbeat();
      case RustPresenceEffect.scheduleReconnect:
        _scheduleReconnect();
    }
  }

  void _openTransport() {
    final config = _config;
    if (_lifecycle.phase != RustPresencePhase.connecting ||
        config == null ||
        _deviceToken.isEmpty) {
      return;
    }
    final generation = _lifecycle.generation;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    try {
      final channel = _channelFactory(presenceUri(config));
      _channel = channel;
      _subscription = channel.stream.listen(
        (raw) => _handleMessage(generation, channel, raw),
        onError: (_, _) => _handleTransportFailure(generation, channel),
        onDone: () => _handleTransportFailure(generation, channel),
        cancelOnError: true,
      );
      unawaited(
        channel.ready.then<void>((_) {
          if (!_owns(generation, channel)) return;
          _dispatch(
            RustPresenceInput.transportReady,
            eventGeneration: generation,
          );
        }, onError: (_, _) => _handleTransportFailure(generation, channel)),
      );
    } catch (_) {
      _dispatch(RustPresenceInput.transportFailed, eventGeneration: generation);
    }
  }

  void _sendAuthentication() {
    final channel = _channel;
    final generation = _lifecycle.generation;
    if (channel == null ||
        _lifecycle.phase != RustPresencePhase.authenticating) {
      return;
    }
    try {
      channel.add(
        jsonEncode({'type': 'authenticate', 'deviceToken': _deviceToken}),
      );
    } catch (_) {
      _handleTransportFailure(generation, channel);
    }
  }

  void _handleMessage(
    int generation,
    RustPresenceChannel channel,
    dynamic raw,
  ) {
    if (!_owns(generation, channel) ||
        raw is! String ||
        raw.length > _maxFrameCharacters) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final type = decoded['type']?.toString();
      if (type == 'ready') {
        final wasAuthenticating =
            _lifecycle.phase == RustPresencePhase.authenticating;
        _dispatch(RustPresenceInput.authenticated, eventGeneration: generation);
        if (wasAuthenticating && _lifecycle.acceptsPresence) {
          _emit(const <String>{});
        }
      } else if (type == 'presence' && _lifecycle.acceptsPresence) {
        _dispatch(RustPresenceInput.presenceFrame, eventGeneration: generation);
        _emit(rustOnlineDeviceIds(decoded));
      } else if (type == 'error') {
        _handleTransportFailure(generation, channel);
      }
    } catch (_) {
      // The fallback channel must never affect recording.
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    final generation = _lifecycle.generation;
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _dispatch(RustPresenceInput.heartbeatTimer, eventGeneration: generation);
    });
  }

  void _sendHeartbeat() {
    final channel = _channel;
    final generation = _lifecycle.generation;
    if (channel == null || !_owns(generation, channel)) return;
    try {
      channel.add(jsonEncode(const {'type': 'heartbeat'}));
    } catch (_) {
      _handleTransportFailure(generation, channel);
    }
  }

  void _emit(Set<String> onlineDeviceIds) {
    if (_snapshots.isClosed) return;
    _snapshots.add(
      RustPresenceSnapshot(
        connected: _lifecycle.acceptsPresence,
        onlineDeviceIds: Set<String>.unmodifiable(onlineDeviceIds),
      ),
    );
  }

  bool _owns(int generation, RustPresenceChannel channel) =>
      generation == _lifecycle.generation && identical(_channel, channel);

  void _handleTransportFailure(int generation, RustPresenceChannel channel) {
    if (!_owns(generation, channel)) return;
    _dispatch(RustPresenceInput.transportFailed, eventGeneration: generation);
    _emit(const <String>{});
  }

  void _scheduleReconnect() {
    if (_lifecycle.phase != RustPresencePhase.waitingToRetry ||
        _config == null) {
      return;
    }
    final generation = _lifecycle.generation;
    final delay = _lifecycle.reconnectDelay;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _dispatch(RustPresenceInput.retryTimer, eventGeneration: generation);
    });
  }

  void _closeTransport() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    if (channel != null) {
      unawaited(channel.close().catchError((Object _) {}));
    }
  }
}
