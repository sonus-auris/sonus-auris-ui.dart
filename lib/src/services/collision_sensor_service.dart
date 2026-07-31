// Detects likely collision-sized accelerometer impulses while capture is live.
import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

class MotionSample {
  const MotionSample({
    required this.x,
    required this.y,
    required this.z,
    required this.sampledAtUtc,
  });

  final double x;
  final double y;
  final double z;
  final DateTime sampledAtUtc;

  double get magnitude => math.sqrt(x * x + y * y + z * z);
}

class CollisionEvent {
  const CollisionEvent({
    required this.occurredAtUtc,
    required this.accelerationMetersPerSecondSquared,
  });

  final DateTime occurredAtUtc;
  final double accelerationMetersPerSecondSquared;
}

/// Pure threshold/cooldown logic, separated from the plugin stream for tests.
class CollisionDetector {
  CollisionDetector({
    this.impactThreshold = 25,
    this.jerkThreshold = 12,
    this.cooldown = const Duration(seconds: 30),
  });

  final double impactThreshold;
  final double jerkThreshold;
  final Duration cooldown;

  double _previousMagnitude = 0;
  DateTime? _lastCollisionAtUtc;

  CollisionEvent? add(MotionSample sample) {
    final magnitude = sample.magnitude;
    final jerk = (magnitude - _previousMagnitude).abs();
    _previousMagnitude = magnitude;

    final last = _lastCollisionAtUtc;
    if (last != null && sample.sampledAtUtc.difference(last) < cooldown) {
      return null;
    }
    // A large, abrupt gravity-filtered acceleration is a useful collision
    // hint. This is deliberately conservative: it is a reminder, not a crash
    // claim or an emergency-service trigger.
    if (magnitude < impactThreshold ||
        (jerk < jerkThreshold && magnitude < impactThreshold * 1.6)) {
      return null;
    }
    _lastCollisionAtUtc = sample.sampledAtUtc;
    return CollisionEvent(
      occurredAtUtc: sample.sampledAtUtc,
      accelerationMetersPerSecondSquared: magnitude,
    );
  }

  void reset() {
    _previousMagnitude = 0;
    _lastCollisionAtUtc = null;
  }
}

typedef MotionSampleStreamFactory = Stream<MotionSample> Function();

class CollisionSensorService {
  CollisionSensorService({
    MotionSampleStreamFactory? samples,
    CollisionDetector? detector,
  }) : _samples = samples ?? _deviceSamples,
       _detector = detector ?? CollisionDetector();

  final MotionSampleStreamFactory _samples;
  final CollisionDetector _detector;
  final StreamController<CollisionEvent> _events =
      StreamController<CollisionEvent>.broadcast();
  StreamSubscription<MotionSample>? _subscription;

  Stream<CollisionEvent> get events => _events.stream;

  Future<void> start() async {
    if (_subscription != null) {
      return;
    }
    _detector.reset();
    try {
      _subscription = _samples().listen(
        (sample) {
          final event = _detector.add(sample);
          if (event != null && !_events.isClosed) {
            _events.add(event);
          }
        },
        onError: (_) {
          // Missing/blocked sensors must never interfere with audio capture.
        },
        cancelOnError: true,
      );
    } catch (_) {
      // Unsupported desktop platforms and denied motion access degrade quietly.
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _detector.reset();
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  static Stream<MotionSample> _deviceSamples() {
    return userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).map(
      (event) => MotionSample(
        x: event.x,
        y: event.y,
        z: event.z,
        sampledAtUtc: DateTime.now().toUtc(),
      ),
    );
  }
}
