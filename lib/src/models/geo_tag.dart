/// A location fix captured alongside an audio segment, so a clip can prove not
/// just *when* but *where* it was recorded. Stored in the segment's evidence
/// metadata and bound into the tamper-evident record.
class GeoTag {
  const GeoTag({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.capturedAtUtc,
    this.altitudeMeters,
    this.headingDegrees,
    this.speedMetersPerSecond,
    this.source = 'gps',
  });

  /// WGS-84 degrees.
  final double latitude;
  final double longitude;

  /// Horizontal accuracy radius in metres (smaller is better). This is what lets
  /// a clip claim "within N metres" of the stated point.
  final double accuracyMeters;

  /// When the fix was taken (UTC), independent of the audio timestamp.
  final DateTime capturedAtUtc;

  final double? altitudeMeters;
  final double? headingDegrees;
  final double? speedMetersPerSecond;

  /// Provider that produced the fix: 'gps', 'fused', 'network', etc.
  final String source;

  /// A compact, human-readable accuracy band for UI ("±4 m").
  String get accuracyLabel => '±${accuracyMeters.round()} m';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'latitude': latitude,
    'longitude': longitude,
    'accuracyMeters': accuracyMeters,
    'capturedAt': capturedAtUtc.toUtc().toIso8601String(),
    if (altitudeMeters != null) 'altitudeMeters': altitudeMeters,
    if (headingDegrees != null) 'headingDegrees': headingDegrees,
    if (speedMetersPerSecond != null)
      'speedMetersPerSecond': speedMetersPerSecond,
    'source': source,
  };

  factory GeoTag.fromJson(Map<String, dynamic> json) {
    double asDouble(Object? v) =>
        v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;
    double? asNullableDouble(Object? v) =>
        v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
    return GeoTag(
      latitude: asDouble(json['latitude']),
      longitude: asDouble(json['longitude']),
      accuracyMeters: asDouble(json['accuracyMeters']),
      capturedAtUtc:
          DateTime.tryParse('${json['capturedAt']}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      altitudeMeters: asNullableDouble(json['altitudeMeters']),
      headingDegrees: asNullableDouble(json['headingDegrees']),
      speedMetersPerSecond: asNullableDouble(json['speedMetersPerSecond']),
      source: json['source'] as String? ?? 'gps',
    );
  }

  /// Canonical, stable string bound into the segment's tamper-evident signature.
  /// Fixed field order + rounded precision so a verifier reproduces it exactly.
  /// ~6 decimal places ≈ 0.1 m of latitude resolution.
  String canonicalEvidenceString() {
    String f(double v) => v.toStringAsFixed(6);
    final parts = <String>[
      'lat=${f(latitude)}',
      'lon=${f(longitude)}',
      'acc=${accuracyMeters.toStringAsFixed(2)}',
      'at=${capturedAtUtc.toUtc().toIso8601String()}',
      'src=$source',
    ];
    return parts.join('|');
  }
}
