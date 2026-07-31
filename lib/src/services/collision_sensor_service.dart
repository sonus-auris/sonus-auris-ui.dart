// Detects likely collision-sized accelerometer impulses while capture is live.
// ignore_for_file: prefer_initializing_formals
//
// Two detection surfaces are exposed:
//  * [CollisionSensorService.start]/[CollisionSensorService.events] — a
//    lifecycle-managed broadcast stream fed by the gravity-filtered user
//    accelerometer and the jerk-aware [CollisionDetector] below.
//  * [CollisionSensorService.collisions] — a pull-style stream (subscribe to
//    start, cancel to stop) fed by the raw, gravity-included accelerometer and
//    the deviation-from-1g detector in `collision_detector.dart`, with a
//    user-tunable sensitivity in g.
//
// NATIVE CONTRACT (optional): a platform side may register an accelerometer
// listener and stream events over the EventChannel
// `audio_dashcam/motion_stream`, each a map
// `{ "x": double, "y": double, "z": double }` in m/s^2 (gravity included,
// i.e. a raw accelerometer, not user-acceleration). It should start listening
// on `onListen` and stop on `onCancel` to spare the battery, and only while the
// app has motion-sensor consent. When no such channel is provided, the
// sensors_plus accelerometer stream is used instead, so no native code is
// required. Detection itself lives here in Dart so it is unit-tested and
// identical across platforms.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'collision_detector.dart' as impact;

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
    double? peakG,
  }) : _peakG = peakG;

  static const double _gravity = 9.80665;

  final DateTime occurredAtUtc;

  /// Acceleration magnitude at the moment of impact, in m/s^2.
  final double accelerationMetersPerSecondSquared;

  final double? _peakG;

  /// Impact strength in g beyond normal gravity. When the event came from the
  /// deviation-from-1g detector this is its exact peak deviation; otherwise it
  /// is derived from the gravity-filtered magnitude.
  double get peakG => _peakG ?? accelerationMetersPerSecondSquared / _gravity;

  /// Alias for [occurredAtUtc].
  DateTime get at => occurredAtUtc;
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
    MotionSampleStreamFactory? rawSamples,
    CollisionDetector? detector,
    EventChannel? channel,
  }) : _samples = samples ?? _deviceUserSamples,
       _rawSamples = rawSamples,
       _detector = detector ?? CollisionDetector(),
       _channel = channel;

  /// Gravity-filtered (user acceleration) samples for [events].
  final MotionSampleStreamFactory _samples;

  /// Gravity-included (raw accelerometer) samples for [collisions]. When null,
  /// the optional native [_channel] is used if provided, else sensors_plus.
  final MotionSampleStreamFactory? _rawSamples;

  final CollisionDetector _detector;

  /// Optional native accelerometer EventChannel (`audio_dashcam/motion_stream`,
  /// see the contract at the top of this file).
  final EventChannel? _channel;

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

  /// Emits one [CollisionEvent] per detected impact, using the raw
  /// (gravity-included) accelerometer and the deviation-from-1g detector.
  /// Subscribing starts the sensor stream; cancelling stops it. [sensitivityG]
  /// is the deviation from 1g that counts as an impact (lower = more
  /// sensitive). Malformed native events and missing sensors are ignored
  /// rather than breaking the stream.
  Stream<CollisionEvent> collisions({double? sensitivityG}) async* {
    final detector = impact.CollisionDetector(thresholdG: sensitivityG ?? 2.5);
    detector.reset();
    Stream<MotionSample> source;
    try {
      source = _rawSampleStream();
    } catch (_) {
      // Unsupported platforms and denied motion access degrade quietly.
      return;
    }
    await for (final sample in source) {
      final hit = detector.addSample(
        sample.sampledAtUtc,
        x: sample.x,
        y: sample.y,
        z: sample.z,
      );
      if (hit != null) {
        yield CollisionEvent(
          occurredAtUtc: hit.at,
          accelerationMetersPerSecondSquared: sample.magnitude,
          peakG: hit.peakG,
        );
      }
    }
  }

  Stream<MotionSample> _rawSampleStream() {
    final rawSamples = _rawSamples;
    if (rawSamples != null) {
      return rawSamples();
    }
    final channel = _channel;
    if (channel != null) {
      return channel
          .receiveBroadcastStream()
          .map(_readChannelSample)
          .where((sample) => sample != null)
          .cast<MotionSample>();
    }
    return _deviceRawSamples();
  }

  static MotionSample? _readChannelSample(Object? event) {
    if (event is! Map) {
      return null;
    }
    final x = _asDouble(event['x']);
    final y = _asDouble(event['y']);
    final z = _asDouble(event['z']);
    if (x == null || y == null || z == null) {
      return null;
    }
    return MotionSample(x: x, y: y, z: z, sampledAtUtc: DateTime.now().toUtc());
  }

  static double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  static Stream<MotionSample> _deviceUserSamples() {
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

  static Stream<MotionSample> _deviceRawSamples() {
    return accelerometerEventStream(
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
