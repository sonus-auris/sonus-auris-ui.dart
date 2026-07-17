/// A category of "meaningful event" that can wake Sonus Auris and prompt for
/// consent to record (only when not already recording and inside a scheduled
/// window — see [RecordingSchedule]). The set is open-ended by design: adding a
/// new sensor means adding a value here and a matching `ContextTriggerSource`.
enum ContextTriggerKind {
  /// Any connectivity transition: Wi-Fi/cell connect or disconnect, or a switch
  /// between transports. Backed by connectivity_plus (no extra permissions).
  networkChange('network_change', 'Network change (Wi-Fi / cell data)'),

  /// The joined Wi-Fi network itself changed (e.g. arriving at or leaving home).
  /// Reads the SSID, so it needs location permission on Android.
  wifiChange('wifi_change', 'Wi-Fi network change'),

  /// A Bluetooth device connected / came into range.
  bluetoothConnect('bluetooth_connect', 'Bluetooth device connects'),

  /// Another device was seen nearby (BLE scan). Most battery-intensive.
  nearbyDevice('nearby_device', 'A device is seen nearby');

  const ContextTriggerKind(this.wireName, this.label);

  /// Stable identifier persisted in config and used over method channels.
  final String wireName;

  /// Human-readable label for the settings UI.
  final String label;

  static ContextTriggerKind? fromWire(String? wire) {
    for (final kind in values) {
      if (kind.wireName == wire) {
        return kind;
      }
    }
    return null;
  }

  static Set<ContextTriggerKind> setFromWire(Iterable<String> wires) =>
      wires.map(fromWire).whereType<ContextTriggerKind>().toSet();
}

/// A concrete event emitted by a context-trigger source.
class ContextTriggerEvent {
  ContextTriggerEvent({
    required this.kind,
    required this.description,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final ContextTriggerKind kind;

  /// Short human description for the consent prompt, e.g. "Connected to Wi-Fi
  /// (HomeNet)" or "AirPods connected".
  final String description;

  final DateTime at;

  @override
  String toString() => 'ContextTriggerEvent(${kind.wireName}: $description)';
}

/// A pending request for the user's consent to start recording, raised when a
/// context trigger fires inside an active schedule window while idle.
class ConsentRequest {
  ConsentRequest({required this.event, DateTime? requestedAt})
    : requestedAt = requestedAt ?? DateTime.now();

  final ContextTriggerEvent event;
  final DateTime requestedAt;

  @override
  bool operator ==(Object other) =>
      other is ConsentRequest &&
      other.event.kind == event.kind &&
      other.event.description == event.description &&
      other.requestedAt == requestedAt;

  @override
  int get hashCode => Object.hash(event.kind, event.description, requestedAt);
}
