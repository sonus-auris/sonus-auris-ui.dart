import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:light/light.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../models/sleep_sensor_sample.dart';
import 'sleep_sensor_source.dart';

/// Real [SleepSensorSource]: taps the platform accelerometer (via `sensors_plus`)
/// and the ambient-light sensor (via `light`, Android only). Both are started
/// **only** for sensors the user has expressly consented to.
///
/// This is the single file that depends on the sensor plugins; everything else
/// (the fusion model, the orchestrator, tests) talks to [SleepSensorSource], so
/// it can be faked freely.
class SystemSleepSensorSource implements SleepSensorSource {
  SystemSleepSensorSource({this.sampleInterval = const Duration(seconds: 1)});

  /// Minimum spacing between emitted samples (the accelerometer fires far faster
  /// than sleep analysis needs; we throttle to save battery).
  final Duration sampleInterval;

  final StreamController<SleepSensorSample> _controller =
      StreamController<SleepSensorSample>.broadcast();

  StreamSubscription<dynamic>? _accelSub;
  StreamSubscription<int>? _lightSub;
  Timer? _lightTicker;

  double? _latestLux;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Stream<SleepSensorSample> get samples => _controller.stream;

  @override
  Future<void> start(SleepSensorConsent consent) async {
    await stop();
    if (consent.light && Platform.isAndroid) {
      try {
        _lightSub = Light().lightSensorStream.listen(
          (lux) => _latestLux = lux.toDouble(),
          onError: (_) {},
        );
        // Light events can be sparse; emit a periodic light-only sample so long
        // dark/bright stretches still register even without motion.
        if (!consent.motion) {
          _lightTicker = Timer.periodic(sampleInterval, (_) => _emitLightOnly());
        }
      } catch (_) {
        // Sensor unavailable on this device; degrade to audio-only.
      }
    }
    if (consent.motion) {
      // userAccelerometerEventStream removes gravity, so magnitude ~0 when still.
      _accelSub = userAccelerometerEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen(_onAccel, onError: (_) {});
    }
  }

  void _onAccel(UserAccelerometerEvent e) {
    final now = DateTime.now().toUtc();
    if (now.difference(_lastEmit) < sampleInterval) {
      return;
    }
    _lastEmit = now;
    final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    _add(SleepSensorSample(atUtc: now, accelMagnitude: mag, lux: _latestLux));
  }

  void _emitLightOnly() {
    final now = DateTime.now().toUtc();
    _lastEmit = now;
    _add(SleepSensorSample(atUtc: now, lux: _latestLux));
  }

  void _add(SleepSensorSample sample) {
    if (!_controller.isClosed) {
      _controller.add(sample);
    }
  }

  @override
  Future<void> stop() async {
    await _accelSub?.cancel();
    _accelSub = null;
    await _lightSub?.cancel();
    _lightSub = null;
    _lightTicker?.cancel();
    _lightTicker = null;
    _latestLux = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
