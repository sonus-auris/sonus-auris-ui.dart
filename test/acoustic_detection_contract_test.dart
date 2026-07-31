import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart'
    as interfaces;

void main() {
  test('client acoustic kinds stay aligned with the shared wire contract', () {
    expect(
      AcousticDetectionKind.values.map((kind) => kind.name),
      unorderedEquals(interfaces.acousticEventsKindValues),
    );
  });

  test('every acoustic kind survives JSON round-trip', () {
    final at = DateTime.utc(2026, 7, 16, 12);
    for (final kind in AcousticDetectionKind.values) {
      final detection = AcousticDetection(
        kind: kind,
        startedAtUtc: at,
        endedAtUtc: at.add(const Duration(seconds: 1)),
        confidence: 0.75,
      );
      expect(AcousticDetection.fromJson(detection.toJson()).kind, kind);
    }
  });
}
