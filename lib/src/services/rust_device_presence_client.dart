// Secondary live presence channel backed by the Rust API server.
//
// Supabase Presence is primary. This channel provides an independent fallback
// and refreshes the Rust server's durable device last_seen_at lease.
import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/app_config.dart';
import '../models/cloud_secrets.dart';

typedef RustPresenceWebSocketFactory = WebSocketChannel Function(Uri uri);

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
  return {
    for (final id in payload['onlineDeviceIds'] as List)
      if (id is String && id.trim().isNotEmpty) id.trim(),
  };
}

class RustDevicePresenceClient {
  RustDevicePresenceClient({RustPresenceWebSocketFactory? channelFactory})
    : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  static const _heartbeatInterval = Duration(seconds: 25);
  static const _maxReconnectDelay = Duration(minutes: 1);

  final RustPresenceWebSocketFactory _channelFactory;
  final StreamController<RustPresenceSnapshot> _snapshots =
      StreamController<RustPresenceSnapshot>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  AppConfig? _config;
  String _deviceToken = '';
  int _reconnectAttempt = 0;
  bool _connected = false;
  bool _closed = false;

  Stream<RustPresenceSnapshot> get snapshots => _snapshots.stream;

  static Uri presenceUri(AppConfig config) {
    final base = Uri.parse(config.backendBaseUrl.trim());
    final loopback = base.host == 'localhost' || base.host == '127.0.0.1';
    if (base.host.isEmpty ||
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
    _closed = false;
    if (changed) _closeChannel();
    if (_channel == null) _open();
  }

  void close() {
    _closed = true;
    _closeChannel();
  }

  Future<void> dispose() async {
    close();
    await _snapshots.close();
  }

  void _open() {
    final config = _config;
    if (_closed || config == null || _deviceToken.isEmpty) return;
    _reconnectTimer?.cancel();
    try {
      final channel = _channelFactory(presenceUri(config));
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (_, _) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );
      unawaited(
        channel.ready.then<void>((_) {
          if (_channel != channel || _closed) return;
          channel.sink.add(
            jsonEncode({'type': 'authenticate', 'deviceToken': _deviceToken}),
          );
        }, onError: (_, _) => _handleDisconnect()),
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final type = decoded['type']?.toString();
      if (type == 'ready') {
        _connected = true;
        _reconnectAttempt = 0;
        _startHeartbeat();
        _emit(const <String>{});
      } else if (type == 'presence') {
        _connected = true;
        _emit(rustOnlineDeviceIds(decoded));
      }
    } catch (_) {
      // The fallback channel must never affect recording.
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      try {
        _channel?.sink.add(jsonEncode(const {'type': 'heartbeat'}));
      } catch (_) {
        _handleDisconnect();
      }
    });
  }

  void _emit(Set<String> onlineDeviceIds) {
    if (_snapshots.isClosed) return;
    _snapshots.add(
      RustPresenceSnapshot(
        connected: _connected,
        onlineDeviceIds: Set<String>.unmodifiable(onlineDeviceIds),
      ),
    );
  }

  void _handleDisconnect() {
    _closeChannel();
    if (_closed || _config == null) return;
    final exponent = _reconnectAttempt.clamp(0, 6).toInt();
    final seconds = 1 << exponent;
    _reconnectAttempt += 1;
    final delay = seconds >= _maxReconnectDelay.inSeconds
        ? _maxReconnectDelay
        : Duration(seconds: seconds);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _open);
  }

  void _closeChannel() {
    _connected = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _emit(const <String>{});
  }
}
