// Watches battery and network conditions and gates cloud uploads accordingly; capture is never affected.
import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:rxdart/rxdart.dart';

import '../models/app_config.dart';
import '../models/transfer_gate_status.dart';
import 'transfer_gate_evaluator.dart';

/// Decides whether the device may stream segments to the cloud right now based
/// on battery level/charging state and the configured network policy.
///
/// Capture of the rolling local window is never affected by this gate — it only
/// governs uploads, so deferred segments stay on device and catch up when
/// conditions recover. [changes] fires whenever the underlying conditions move
/// (battery state, connectivity) plus a slow poll so a battery rising back above
/// the threshold is noticed even when the OS does not push a state event.
class PowerNetworkGate {
  PowerNetworkGate({
    Battery? battery,
    Connectivity? connectivity,
    Duration? pollInterval,
  }) : _battery = battery ?? Battery(),
       _connectivity = connectivity ?? Connectivity(),
       _pollInterval = pollInterval ?? const Duration(seconds: 90);

  final Battery _battery;
  final Connectivity _connectivity;
  final Duration _pollInterval;

  /// Emits a tick (the payload is irrelevant) whenever conditions may have
  /// changed. Consumers should re-run [evaluate] and act on the result.
  Stream<void> get changes => Rx.merge<void>([
    _connectivity.onConnectivityChanged.map((_) {}),
    _battery.onBatteryStateChanged.map((_) {}),
    Stream<void>.periodic(_pollInterval, (_) {}),
  ]);

  /// Reads the current battery/connectivity conditions and evaluates them
  /// against [config]. Never throws: on platform errors it fails open (allows
  /// the upload) so a flaky sensor does not silently strand recordings.
  Future<TransferGateStatus> evaluate(AppConfig config) async {
    int batteryLevel = -1;
    bool isCharging = false;
    try {
      batteryLevel = await _battery.batteryLevel;
    } catch (_) {
      batteryLevel = -1;
    }
    try {
      final state = await _battery.batteryState;
      isCharging = state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {
      isCharging = false;
    }

    var results = <ConnectivityResult>[];
    try {
      results = await _connectivity.checkConnectivity();
    } catch (_) {
      results = const [];
    }
    final onWifi =
        results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    final onCellular = results.contains(ConnectivityResult.mobile);
    // When connectivity is unknown (empty), treat as online and fail open so a
    // plugin gap never blocks every upload.
    final isOnline =
        results.isEmpty || !results.every((r) => r == ConnectivityResult.none);

    return evaluateTransferGate(
      config: config,
      batteryLevel: batteryLevel,
      isCharging: isCharging,
      onWifi: onWifi,
      onCellular: onCellular,
      isOnline: isOnline,
    );
  }
}
