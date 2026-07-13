// Concrete ContextTriggerSource implementations for connectivity, Wi-Fi, and Bluetooth events.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../models/context_trigger.dart';
import 'context_trigger_service.dart';

/// Base class that owns a broadcast controller so subclasses just push events.
abstract class _BaseTriggerSource implements ContextTriggerSource {
  final StreamController<ContextTriggerEvent> _controller =
      StreamController<ContextTriggerEvent>.broadcast();

  bool _started = false;

  @override
  Stream<ContextTriggerEvent> get events => _controller.stream;

  void _emit(String description) {
    if (!_controller.isClosed) {
      _controller.add(
        ContextTriggerEvent(kind: kind, description: description),
      );
    }
  }
}

/// Any connectivity transition (Wi-Fi/cell connect or disconnect, transport
/// switch). Uses connectivity_plus — no extra permissions.
class ConnectivityTriggerSource extends _BaseTriggerSource {
  ConnectivityTriggerSource({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Set<ConnectivityResult> _last = const {};

  @override
  ContextTriggerKind get kind => ContextTriggerKind.networkChange;

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    _last = (await _connectivity.checkConnectivity()).toSet();
    _sub = _connectivity.onConnectivityChanged.listen((results) {
      final next = results.toSet();
      if (next.difference(_last).isNotEmpty ||
          _last.difference(next).isNotEmpty) {
        _last = next;
        _emit('Network changed: ${_describe(next)}');
      }
    });
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _started = false;
  }

  String _describe(Set<ConnectivityResult> results) {
    if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
      return 'offline';
    }
    return results
        .where((r) => r != ConnectivityResult.none)
        .map((r) => r.name)
        .join('+');
  }
}

/// The joined Wi-Fi network itself changed (home ↔ away ↔ other). Reads the
/// SSID via network_info_plus, re-checked whenever connectivity changes.
class WifiSsidTriggerSource extends _BaseTriggerSource {
  WifiSsidTriggerSource({Connectivity? connectivity, NetworkInfo? networkInfo})
    : _connectivity = connectivity ?? Connectivity(),
      _networkInfo = networkInfo ?? NetworkInfo();

  final Connectivity _connectivity;
  final NetworkInfo _networkInfo;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  String? _lastSsid;

  @override
  ContextTriggerKind get kind => ContextTriggerKind.wifiChange;

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    _lastSsid = await _readSsid();
    _sub = _connectivity.onConnectivityChanged.listen((_) async {
      final ssid = await _readSsid();
      if (ssid != _lastSsid) {
        final previous = _lastSsid;
        _lastSsid = ssid;
        if (ssid != null) {
          _emit('Joined Wi-Fi: $ssid');
        } else if (previous != null) {
          _emit('Left Wi-Fi: $previous');
        }
      }
    });
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _started = false;
  }

  Future<String?> _readSsid() async {
    try {
      final raw = await _networkInfo.getWifiName();
      if (raw == null || raw.isEmpty) {
        return null;
      }
      // Some platforms wrap the SSID in quotes.
      return raw.replaceAll('"', '');
    } catch (_) {
      return null;
    }
  }
}

/// A Bluetooth device connected to the system. Polls the OS-connected-device set
/// (the cross-platform signal flutter_blue_plus exposes) and uses adapter state
/// changes to refresh that set.
class BluetoothTriggerSource extends _BaseTriggerSource {
  BluetoothTriggerSource({Duration pollInterval = const Duration(seconds: 15)})
    : _pollInterval = pollInterval;

  final Duration _pollInterval;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _poll;
  Set<String> _connected = const {};

  @override
  ContextTriggerKind get kind => ContextTriggerKind.bluetoothConnect;

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    try {
      _adapterSub = FlutterBluePlus.adapterState.listen((state) {
        if (state == BluetoothAdapterState.on) {
          unawaited(_tick());
        }
      });
    } catch (_) {
      // Adapter stream unavailable (e.g. desktop) — polling still attempted.
    }
    _connected = await _readConnected();
    _poll = Timer.periodic(_pollInterval, (_) => _tick());
  }

  Future<void> _tick() async {
    final now = await _readConnected();
    final added = now.difference(_connected);
    _connected = now;
    if (added.isNotEmpty) {
      _emit('Bluetooth device connected');
    }
  }

  Future<Set<String>> _readConnected() async {
    try {
      final devices = await FlutterBluePlus.systemDevices(const []);
      return devices.map((d) => d.remoteId.str).toSet();
    } catch (_) {
      return _connected;
    }
  }

  @override
  Future<void> stop() async {
    await _adapterSub?.cancel();
    _adapterSub = null;
    _poll?.cancel();
    _poll = null;
    _started = false;
  }
}

/// Another device was seen nearby via periodic short BLE scans. The most
/// battery-intensive source, so scans are short and spaced out, and only run
/// while this source is started (i.e. inside an armed schedule window).
class NearbyDeviceTriggerSource extends _BaseTriggerSource {
  NearbyDeviceTriggerSource({
    Duration scanEvery = const Duration(seconds: 90),
    Duration scanFor = const Duration(seconds: 6),
  }) : _scanEvery = scanEvery,
       _scanFor = scanFor;

  final Duration _scanEvery;
  final Duration _scanFor;
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _cycle;
  final Set<String> _seen = <String>{};

  @override
  ContextTriggerKind get kind => ContextTriggerKind.nearbyDevice;

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    try {
      _scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final id = r.device.remoteId.str;
          if (_seen.add(id)) {
            final name = r.device.platformName.isNotEmpty
                ? r.device.platformName
                : 'a device';
            _emit('Saw $name nearby');
          }
        }
      });
    } catch (_) {
      // Scan results stream unavailable.
    }
    await _runScan();
    _cycle = Timer.periodic(_scanEvery, (_) => _runScan());
  }

  Future<void> _runScan() async {
    try {
      // Forget previously-seen devices each cycle so a device that leaves and
      // returns re-triggers, while a stationary device doesn't spam every scan.
      _seen.clear();
      // lowPower scan mode — these are periodic background-style sweeps that may
      // run through a long window, so favor battery over latency.
      await FlutterBluePlus.startScan(
        timeout: _scanFor,
        androidScanMode: AndroidScanMode.lowPower,
      );
    } catch (_) {
      // Permission denied / adapter off / a scan already running — skip.
    }
  }

  @override
  Future<void> stop() async {
    await _scanSub?.cancel();
    _scanSub = null;
    _cycle?.cancel();
    _cycle = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _seen.clear();
    _started = false;
  }
}

/// All the production sources, ready to hand to a [ContextTriggerService].
List<ContextTriggerSource> defaultContextTriggerSources() => [
  ConnectivityTriggerSource(),
  WifiSsidTriggerSource(),
  BluetoothTriggerSource(),
  NearbyDeviceTriggerSource(),
];
