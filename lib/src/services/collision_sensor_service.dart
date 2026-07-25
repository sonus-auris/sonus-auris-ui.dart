// Streams native accelerometer readings and surfaces detected impacts.
//
// NATIVE CONTRACT: the platform side registers an accelerometer listener and
// streams events over the EventChannel `audio_dashcam/motion_stream`, each a
// map `{ "x": double, "y": double, "z": double }` in m/s^2 (gravity included,
// i.e. a raw accelerometer, not user-acceleration). It should start listening
// on `onListen` and stop on `onCancel` to spare the battery, and only while the
// app has motion-sensor consent. Detection itself lives here in Dart so it is
// unit-tested and identical across platforms.
import 'dart:async';

import 'package:flutter/services.dart';

import 'collision_detector.dart';

class CollisionSensorService {
  CollisionSensorService({EventChannel? channel, CollisionDetector? detector})
    : _channel = channel ?? const EventChannel('audio_dashcam/motion_stream'),
      _detector = detector ?? CollisionDetector();

  final EventChannel _channel;
  CollisionDetector _detector;

  /// Emits one [CollisionEvent] per detected impact. Subscribing starts the
  /// native accelerometer stream; cancelling stops it. Malformed events are
  /// ignored rather than breaking the stream.
  Stream<CollisionEvent> collisions({double? sensitivityG}) {
    if (sensitivityG != null) {
      _detector = CollisionDetector(thresholdG: sensitivityG);
    }
    _detector.reset();
    return _channel.receiveBroadcastStream().transform(
      StreamTransformer<dynamic, CollisionEvent>.fromHandlers(
        handleData: (event, sink) {
          final sample = _readSample(event);
          if (sample == null) {
            return;
          }
          final collision = _detector.addSample(
            DateTime.now(),
            x: sample.$1,
            y: sample.$2,
            z: sample.$3,
          );
          if (collision != null) {
            sink.add(collision);
          }
        },
      ),
    );
  }

  static (double, double, double)? _readSample(Object? event) {
    if (event is! Map) {
      return null;
    }
    final x = _asDouble(event['x']);
    final y = _asDouble(event['y']);
    final z = _asDouble(event['z']);
    if (x == null || y == null || z == null) {
      return null;
    }
    return (x, y, z);
  }

  static double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }
}
