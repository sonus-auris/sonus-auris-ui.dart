// Authenticated Supabase Realtime transport for sanitized client telemetry.
//
// Realtime Broadcast is intentionally *not* treated as durable storage: every
// row is also persisted by SupabaseRestClient through the idempotent outbox.
// The socket gives an operations console immediate visibility while the table
// and its RLS/publication provide the forensic source of truth.
import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/app_config.dart';

typedef TelemetryWebSocketFactory = WebSocketChannel Function(Uri uri);

class SupabaseTelemetryRealtimeClient {
  SupabaseTelemetryRealtimeClient({TelemetryWebSocketFactory? channelFactory})
    : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  static const _maxQueuedEvents = 200;
  static const _heartbeatInterval = Duration(seconds: 25);
  static const _maxReconnectDelay = Duration(minutes: 1);

  final TelemetryWebSocketFactory _channelFactory;
  final List<Map<String, Object?>> _pending = [];

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  AppConfig? _config;
  String _accessToken = '';
  String _userId = '';
  String _topic = '';
  int _nextReference = 1;
  int _reconnectAttempt = 0;
  bool _joined = false;
  bool _closed = false;

  bool get isConnected => _joined;

  /// Starts (or refreshes) the authenticated channel for one account. The
  /// topic is deliberately derived from the immutable Supabase UUID, never an
  /// email address or a device id.
  void connect({
    required AppConfig config,
    required String accessToken,
    required String userId,
  }) {
    final normalizedToken = accessToken.trim();
    final normalizedUserId = userId.trim();
    if (normalizedToken.isEmpty || normalizedUserId.isEmpty) {
      close();
      return;
    }
    final changed =
        _config?.supabaseUrl != config.supabaseUrl ||
        _config?.supabaseAnonKey != config.supabaseAnonKey ||
        _accessToken != normalizedToken ||
        _userId != normalizedUserId;
    _config = config;
    _accessToken = normalizedToken;
    _userId = normalizedUserId;
    _topic = 'client_telemetry:$normalizedUserId';
    _closed = false;
    if (changed) {
      _closeChannel();
    }
    if (_channel == null) {
      _open();
    }
  }

  /// Broadcasts a caller-sanitized organization telemetry entry. If the socket
  /// is unavailable, retain a bounded replay buffer; the durable RPC outbox is
  /// still responsible for retaining the event across process restarts.
  void publish(Map<String, Object?> sanitizedTelemetryRow) {
    final payload = Map<String, Object?>.from(sanitizedTelemetryRow);
    if (!_joined) {
      _enqueue(payload);
      if (_channel == null && !_closed) {
        _open();
      }
      return;
    }
    _sendBroadcast(payload);
  }

  void close() {
    _closed = true;
    _pending.clear();
    _closeChannel();
  }

  static Uri realtimeUri(AppConfig config) {
    final base = Uri.parse(config.supabaseUrl.trim());
    final baseSegments = base.pathSegments.where((part) => part.isNotEmpty);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      pathSegments: [...baseSegments, 'realtime', 'v1', 'websocket'],
      queryParameters: {
        'apikey': config.supabaseAnonKey.trim(),
        'vsn': '1.0.0',
      },
      fragment: '',
    );
  }

  void _open() {
    final config = _config;
    if (_closed || config == null || _accessToken.isEmpty || _userId.isEmpty) {
      return;
    }
    _reconnectTimer?.cancel();
    try {
      final channel = _channelFactory(realtimeUri(config));
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (error, stackTrace) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );
      _send(
        event: 'phx_join',
        payload: {
          'config': {
            'broadcast': {'ack': false, 'self': false},
            // This must stay private: the migration scopes the topic to the
            // JWT subject through realtime.messages RLS policies.
            'private': true,
          },
          'access_token': _accessToken,
        },
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final event = decoded['event']?.toString();
      final payload = decoded['payload'];
      if (event == 'phx_reply' && payload is Map && payload['status'] == 'ok') {
        _joined = true;
        _reconnectAttempt = 0;
        _startHeartbeat();
        _drainPending();
      }
    } catch (_) {
      // A malformed server frame must never affect recording or telemetry.
    }
  }

  void _sendBroadcast(Map<String, Object?> row) {
    _send(
      event: 'broadcast',
      payload: {
        'event': 'telemetry',
        'payload': {'schema': 'sonus_client_log_entries.v1', 'entry': row},
      },
    );
  }

  void _send({required String event, required Map<String, Object?> payload}) {
    final channel = _channel;
    if (channel == null || _topic.isEmpty) {
      return;
    }
    try {
      channel.sink.add(
        jsonEncode({
          'topic': _topic,
          'event': event,
          'payload': payload,
          'ref': '${_nextReference++}',
        }),
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _drainPending() {
    if (!_joined) {
      return;
    }
    final pending = List<Map<String, Object?>>.from(_pending);
    _pending.clear();
    for (final row in pending) {
      _sendBroadcast(row);
    }
  }

  void _enqueue(Map<String, Object?> row) {
    _pending.add(row);
    if (_pending.length > _maxQueuedEvents) {
      _pending.removeRange(0, _pending.length - _maxQueuedEvents);
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _send(event: 'heartbeat', payload: const {});
    });
  }

  void _handleDisconnect() {
    _joined = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    if (_closed || _config == null) {
      return;
    }
    final exponent = _reconnectAttempt.clamp(0, 6).toInt();
    final seconds = 1 << exponent;
    _reconnectAttempt += 1;
    _reconnectTimer?.cancel();
    final delay = seconds >= _maxReconnectDelay.inSeconds
        ? _maxReconnectDelay
        : Duration(seconds: seconds);
    _reconnectTimer = Timer(delay, _open);
  }

  void _closeChannel() {
    _joined = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }
}
