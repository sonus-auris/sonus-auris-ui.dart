// Best-effort, opt-in GPS tagging for segments; fails soft so a missing fix never breaks capture.
import 'package:geolocator/geolocator.dart';

import '../models/geo_tag.dart';

/// Best-effort GPS tagging for audio segments. Every method is defensive: if
/// location services are off, permission is denied, or a fix times out, it
/// returns null and capture continues unaffected — a missing location must
/// never break recording. Tagging is opt-in (gated by the caller's config flag).
class LocationService {
  LocationService({
    this._fixTimeout = const Duration(seconds: 8),
    this._accuracy = LocationAccuracy.best,
  });

  final Duration _fixTimeout;
  final LocationAccuracy _accuracy;

  /// Ensures permission, prompting once if it has not yet been decided. Returns
  /// true when foreground location is usable.
  Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return false;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  /// Returns the current fix as a [GeoTag], or null if unavailable. Never throws.
  Future<GeoTag?> currentTag() async {
    try {
      if (!await ensurePermission()) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: _accuracy,
          timeLimit: _fixTimeout,
        ),
      );
      return _toTag(position);
    } catch (_) {
      // Service off, timeout, or platform error — tag is simply absent.
      return null;
    }
  }

  GeoTag _toTag(Position p) {
    return GeoTag(
      latitude: p.latitude,
      longitude: p.longitude,
      accuracyMeters: p.accuracy,
      capturedAtUtc: p.timestamp.toUtc(),
      altitudeMeters: p.altitude,
      headingDegrees: p.heading,
      speedMetersPerSecond: p.speed,
      source: 'gps',
    );
  }
}
