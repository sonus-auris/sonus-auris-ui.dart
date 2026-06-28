import 'dart:async';

import '../models/sleep_sensor_sample.dart';

/// Which optional sensors the user has given **express consent** to use during a
/// sleep session. All default to off; sensing only happens after explicit opt-in.
class SleepSensorConsent {
  const SleepSensorConsent({this.motion = false, this.light = false});

  /// Accelerometer: stillness vs. tossing/turning vs. getting up.
  final bool motion;

  /// Ambient-light sensor: darkness duration, lights off/on, dawn brightening.
  final bool light;

  bool get any => motion || light;
}

/// Abstract source of [SleepSensorSample]s. The real implementation taps the
/// platform accelerometer + ambient-light sensor; tests and the pure model use a
/// fake. Keeping this an interface means the orchestrator and its tests carry no
/// dependency on the sensor plugins.
abstract class SleepSensorSource {
  /// Begin emitting samples for the consented sensors. No-op for sensors without
  /// consent. Safe to call when [consent] has nothing enabled (emits nothing).
  Future<void> start(SleepSensorConsent consent);

  /// Stop all sensor subscriptions.
  Future<void> stop();

  /// Sampled sensor readings while started.
  Stream<SleepSensorSample> get samples;

  Future<void> dispose();
}

/// A no-op source used when no sensor plugins are wired in (or on platforms
/// where they're unavailable). Emits nothing; the engine falls back to
/// audio-only sleep analysis.
class NullSleepSensorSource implements SleepSensorSource {
  final StreamController<SleepSensorSample> _controller =
      StreamController<SleepSensorSample>.broadcast();

  @override
  Stream<SleepSensorSample> get samples => _controller.stream;

  @override
  Future<void> start(SleepSensorConsent consent) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}
