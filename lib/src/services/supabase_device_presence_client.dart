// Supabase-first live device presence over the documented Realtime protocol.
//
// Presence is ephemeral and answers "online now". The durable devices table
// remains authoritative for registration, revocation, and last_seen_at.
import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/app_config.dart';
import 'device_registry.dart';
import 'supabase_telemetry_realtime_client.dart'
    show SupabaseTelemetryRealtimeClient;

typedef DevicePresenceWebSocketFactory = WebSocketChannel Function(Uri uri);

class DevicePresenceSnapshot {
  const DevicePresenceSnapshot({
    this.connected = false,
    this.onlineDeviceIds = const <String>{},
    this.syncedAtUtc,
  });

  final bool connected;
  final Set<String> onlineDeviceIds;
  final DateTime? syncedAtUtc;

  bool isOnline(String deviceId) => onlineDeviceIds.contains(deviceId);
}

/// Decodes the server's `presence_state` payload into device -> phx_ref sets.
Map<String, Set<String>> presenceRefsFromState(Object? payload) {
  if (payload is! Map) return <String, Set<String>>{};
  final result = <String, Set<String>>{};
  for (final entry in payload.entries) {
    final deviceId = entry.key.toString().trim();
    if (deviceId.isEmpty || entry.value is! Map) continue;
    final metas = (entry.value as Map)['metas'];
    if (metas is! List) continue;
    final refs = <String>{};
    for (final meta in metas) {
      if (meta is! Map) continue;
      final ref = meta['phx_ref']?.toString().trim() ?? '';
      if (ref.isNotEmpty) refs.add(ref);
    }
    if (refs.isNotEmpty) result[deviceId] = refs;
  }
  return result;
}

/// Applies one `presence_diff`, retaining a device until its final connection
/// leaves (important when the same device has multiple windows/tabs).
void applyPresenceDiff(Map<String, Set<String>> state, Object? payload) {
  if (payload is! Map) return;
  final joins = presenceRefsFromState(payload['joins']);
  for (final entry in joins.entries) {
    state.putIfAbsent(entry.key, () => <String>{}).addAll(entry.value);
  }
  final leaves = presenceRefsFromState(payload['leaves']);
  for (final entry in leaves.entries) {
    final current = state[entry.key];
    if (current == null) continue;
    current.removeAll(entry.value);
    if (current.isEmpty) state.remove(entry.key);
  }
}

class SupabaseDevicePresenceClient {
  SupabaseDevicePresenceClient({DevicePresenceWebSocketFactory? channelFactory})
    : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  static const _socketHeartbeatInterval = Duration(seconds: 25);
  static const _maxReconnectDelay = Duration(minutes: 1);

  final DevicePresenceWebSocketFactory _channelFactory;
  final StreamController<DevicePresenceSnapshot> _snapshots =
      StreamController<DevicePresenceSnapshot>.broadcast();
  final Map<String, Set<String>> _presenceRefs = {};

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  AppConfig? _config;
  String _accessToken = '';
  String _userId = '';
  String _deviceId = '';
  String _platform = '';
  String _topic = '';
  String? _joinReference;
  int _nextReference = 1;
  int _reconnectAttempt = 0;
  bool _joined = false;
  bool _closed = false;

  Stream<DevicePresenceSnapshot> get snapshots => _snapshots.stream;
  bool get isConnected => _joined;

  void connect({
    required AppConfig config,
    required String accessToken,
    required String userId,
    required String deviceId,
    required String platform,
  }) {
    final token = accessToken.trim();
    final subject = userId.trim();
    final install = deviceId.trim();
    if (token.isEmpty || subject.isEmpty || install.isEmpty) {
      close();
      return;
    }
    final changed =
        _config?.supabaseUrl != config.supabaseUrl ||
        _config?.supabaseAnonKey != config.supabaseAnonKey ||
        _accessToken != token ||
        _userId != subject ||
        _deviceId != install;
    _config = config;
    _accessToken = token;
    _userId = subject;
    _deviceId = install;
    _platform = platform.trim().toLowerCase();
    _topic = 'realtime:device_presence:$subject';
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
    if (_closed ||
        config == null ||
        _accessToken.isEmpty ||
        _userId.isEmpty ||
        _deviceId.isEmpty) {
      return;
    }
    _reconnectTimer?.cancel();
    try {
      final channel = _channelFactory(
        SupabaseTelemetryRealtimeClient.realtimeUri(config),
      );
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (_, _) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );
      final joinRef = '${_nextReference++}';
      _joinReference = joinRef;
      _send(
        event: 'phx_join',
        reference: joinRef,
        joinReference: joinRef,
        payload: {
          'config': {
            'broadcast': {'ack': false, 'self': false},
            'presence': {'enabled': true, 'key': _deviceId},
            'postgres_changes': const [],
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
    if (raw is! String) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final event = decoded['event']?.toString();
      final payload = decoded['payload'];
      if (event == 'phx_reply' &&
          !_joined &&
          payload is Map &&
          payload['status'] == 'ok') {
        _joined = true;
        _reconnectAttempt = 0;
        _startHeartbeat();
        _track();
        _emit();
        return;
      }
      if (event == 'presence_state') {
        _presenceRefs
          ..clear()
          ..addAll(presenceRefsFromState(payload));
        _emit();
      } else if (event == 'presence_diff') {
        applyPresenceDiff(_presenceRefs, payload);
        _emit();
      } else if (event == 'phx_error' || event == 'phx_close') {
        _handleDisconnect();
      }
    } catch (_) {
      // Presence must never interfere with recording.
    }
  }

  void _track() {
    _send(
      event: 'presence',
      joinReference: _joinReference,
      payload: {
        'type': 'presence',
        'event': 'track',
        'payload': {
          'device_id': _deviceId,
          'platform': _platform,
          if (kSonusAppVersion.trim().isNotEmpty)
            'app_version': kSonusAppVersion.trim(),
          'online_at': DateTime.now().toUtc().toIso8601String(),
        },
      },
    );
  }

  void _send({
    required String event,
    required Map<String, Object?> payload,
    String? reference,
    String? joinReference,
    String? topic,
  }) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(
        jsonEncode({
          'topic': topic ?? _topic,
          'event': event,
          'payload': payload,
          'ref': reference ?? '${_nextReference++}',
          'join_ref': ?joinReference,
        }),
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_socketHeartbeatInterval, (_) {
      _send(event: 'heartbeat', payload: const {}, topic: 'phoenix');
    });
  }

  void _emit() {
    if (_snapshots.isClosed) return;
    _snapshots.add(
      DevicePresenceSnapshot(
        connected: _joined,
        onlineDeviceIds: Set<String>.unmodifiable(_presenceRefs.keys),
        syncedAtUtc: DateTime.now().toUtc(),
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
    _joined = false;
    _joinReference = null;
    _presenceRefs.clear();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _emit();
  }
}
