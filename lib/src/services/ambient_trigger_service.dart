// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

import 'diagnostic_log.dart';

class AmbientRecordingTrigger {
  AmbientRecordingTrigger({
    required this.kind,
    required this.label,
    this.detail = '',
    DateTime? occurredAt,
  }) : occurredAt = occurredAt ?? DateTime.now();

  final String kind;
  final String label;
  final String detail;
  final DateTime occurredAt;

  factory AmbientRecordingTrigger.fromJson(Object? value) {
    if (value is! Map) {
      return AmbientRecordingTrigger(kind: 'unknown', label: 'Device event');
    }
    final rawAt = value['occurredAt']?.toString();
    final epochMillis = value['occurredAtMillis'];
    return AmbientRecordingTrigger(
      kind: value['kind']?.toString() ?? 'unknown',
      label: value['label']?.toString() ?? 'Device event',
      detail: value['detail']?.toString() ?? '',
      occurredAt: epochMillis is num
          ? DateTime.fromMillisecondsSinceEpoch(epochMillis.round())
          : rawAt == null
          ? DateTime.now()
          : DateTime.tryParse(rawAt),
    );
  }
}

class AmbientTriggerService {
  AmbientTriggerService({
    MethodChannel? channel,
    Connectivity? connectivity,
    DiagnosticLog? diagnostics,
  }) : _channel =
           channel ?? const MethodChannel('audio_dashcam/ambient_triggers'),
       _connectivity = connectivity ?? Connectivity(),
       _diagnostics = diagnostics {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;
  final Connectivity _connectivity;
  final DiagnosticLog? _diagnostics;
  final StreamController<AmbientRecordingTrigger> _events =
      StreamController<AmbientRecordingTrigger>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  String? _lastConnectivitySignature;

  Stream<AmbientRecordingTrigger> get events => _events.stream;

  Future<void> start() async {
    try {
      _lastConnectivitySignature = _signature(
        await _connectivity.checkConnectivity(),
      );
    } catch (_) {
      _lastConnectivitySignature = null;
    }
    _connectivitySubscription ??= _connectivity.onConnectivityChanged.listen(
      _onConnectivityChanged,
      onError: (Object error) {
        _diagnostics?.add('Ambient connectivity watch failed: $error');
      },
    );
    try {
      await _channel.invokeMethod<void>('startMonitoring');
    } on MissingPluginException {
      _diagnostics?.add('Native ambient trigger bridge is unavailable.');
    } on PlatformException catch (error) {
      _diagnostics?.add('Native ambient trigger start failed: $error');
    }
  }

  Future<void> dispose() async {
    await _connectivitySubscription?.cancel();
    _channel.setMethodCallHandler(null);
    await _events.close();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'trigger':
        _emit(AmbientRecordingTrigger.fromJson(call.arguments));
        return true;
      default:
        throw PlatformException(
          code: 'not_implemented',
          message: 'Unknown ambient trigger call ${call.method}.',
        );
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final signature = _signature(results);
    if (signature == _lastConnectivitySignature) {
      return;
    }
    _lastConnectivitySignature = signature;
    _emit(
      AmbientRecordingTrigger(
        kind: 'connectivity',
        label: _connectivityLabel(results),
        detail: signature,
      ),
    );
  }

  void _emit(AmbientRecordingTrigger event) {
    if (!_events.isClosed) {
      _diagnostics?.add(
        'Ambient recording trigger: ${event.label}'
        '${event.detail.isEmpty ? '' : ' (${event.detail})'}.',
      );
      _events.add(event);
    }
  }

  String _signature(List<ConnectivityResult> results) {
    final names = results.map((result) => result.name).toList()..sort();
    return names.isEmpty ? 'none' : names.join('+');
  }

  String _connectivityLabel(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) {
      return 'Wi-Fi changed';
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return 'Cellular connection changed';
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return 'Network connection changed';
    }
    return 'Connectivity changed';
  }
}
