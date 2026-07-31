import 'dart:math' as math;

/// A detected impact: when it happened and how hard, in g beyond normal gravity.
class CollisionEvent {
  const CollisionEvent({required this.at, required this.peakG});

  final DateTime at;

  /// Peak deviation from 1g at the moment of impact. A phone at rest reads ~1g;
  /// a hard knock or vehicle collision spikes well above that.
  final double peakG;
}

/// Pure impact detector fed a stream of accelerometer magnitudes.
///
/// A phone at rest measures ~1g (9.80665 m/s^2) of gravity. A collision — a
/// dropped phone, a knock, a vehicle impact — briefly drives the *total*
/// acceleration far from 1g (a spike, or free-fall toward 0g then a spike). We
/// fire when the deviation from 1g crosses [thresholdG], then stay quiet for
/// [refractory] so a single multi-sample impact raises exactly one event.
///
/// Clock-injected and side-effect-free so the threshold/debounce logic is
/// unit-testable without a device or a platform channel.
class CollisionDetector {
  CollisionDetector({
    this.thresholdG = 2.5,
    this.refractory = const Duration(seconds: 3),
  });

  /// Deviation from 1g, in g, that counts as an impact. ~2–3g is a firm knock;
  /// higher values require a harder hit. Surfaced as a user sensitivity.
  final double thresholdG;

  /// Quiet period after an impact so one event isn't reported many times as the
  /// spike rings out across successive samples.
  final Duration refractory;

  static const double _gravity = 9.80665;
  DateTime? _lastFired;

  /// Feed one 3-axis reading (m/s^2). Returns a [CollisionEvent] the first time
  /// an impact crosses the threshold, then null until [refractory] elapses.
  CollisionEvent? addSample(
    DateTime now, {
    required double x,
    required double y,
    required double z,
  }) {
    return addMagnitude(now, math.sqrt(x * x + y * y + z * z));
  }

  /// Feed a pre-computed total-acceleration magnitude (m/s^2).
  CollisionEvent? addMagnitude(DateTime now, double magnitudeMps2) {
    final deviationG = ((magnitudeMps2 / _gravity) - 1.0).abs();
    if (deviationG < thresholdG) {
      return null;
    }
    final last = _lastFired;
    if (last != null && now.difference(last) < refractory) {
      return null;
    }
    _lastFired = now;
    return CollisionEvent(at: now, peakG: deviationG);
  }

  /// Forget the last impact time (e.g. when monitoring restarts).
  void reset() {
    _lastFired = null;
  }
}
