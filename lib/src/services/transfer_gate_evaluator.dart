// Pure decision function for whether uploads are allowed given power/network conditions and the configured policy.
import '../models/app_config.dart';
import '../models/transfer_gate_status.dart';
import '../models/upload_network_policy.dart';

/// Pure decision for whether the device may stream segments to the cloud right
/// now, given the configured policy and the current power/network conditions.
///
/// Kept free of plugin types so it is unit-testable without a device. Capture of
/// the rolling local window is never affected — this only governs uploads.
TransferGateStatus evaluateTransferGate({
  required AppConfig config,
  required int batteryLevel,
  required bool isCharging,
  required bool onWifi,
  required bool onCellular,
  required bool isOnline,
}) {
  TransferGateStatus blocked(TransferBlockReason reason, String detail) =>
      TransferGateStatus(
        allowed: false,
        reason: reason,
        batteryLevel: batteryLevel,
        isCharging: isCharging,
        onWifi: onWifi,
        onCellular: onCellular,
        isOnline: isOnline,
        detail: detail,
      );

  if (!isOnline) {
    return blocked(TransferBlockReason.offline, 'Waiting for a connection.');
  }

  // Battery gate. Charging exempts the device: if it is plugged in, draining the
  // battery is not a concern, so let uploads catch up.
  if (config.pauseUploadsOnLowBattery &&
      !isCharging &&
      batteryLevel >= 0 &&
      batteryLevel < config.lowBatteryThresholdPercent) {
    return blocked(
      TransferBlockReason.lowBattery,
      'Battery $batteryLevel% (below ${config.lowBatteryThresholdPercent}%). '
      'Recording continues; uploads resume when charged.',
    );
  }

  // Network policy gate. Only meaningful when we actually know the transport; if
  // the connectivity type is unknown we fail open.
  switch (config.uploadNetworkPolicy) {
    case UploadNetworkPolicy.wifiOnly:
      if (!onWifi && onCellular) {
        return blocked(
          TransferBlockReason.networkPolicy,
          'Wi-Fi only: waiting for Wi-Fi (on cellular).',
        );
      }
      break;
    case UploadNetworkPolicy.cellularOnly:
      if (!onCellular && onWifi) {
        return blocked(
          TransferBlockReason.networkPolicy,
          'Cellular only: waiting for cellular (on Wi-Fi).',
        );
      }
      break;
    case UploadNetworkPolicy.any:
      break;
  }

  return TransferGateStatus(
    allowed: true,
    reason: TransferBlockReason.none,
    batteryLevel: batteryLevel,
    isCharging: isCharging,
    onWifi: onWifi,
    onCellular: onCellular,
    isOnline: isOnline,
  );
}
