import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/models/day_of_life.dart';
import 'package:audio_dashcam/src/models/geo_tag.dart';
import 'package:audio_dashcam/src/services/activity_summarizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const summarizer = ActivitySummarizer();

  AcousticDetection det(
    AcousticDetectionKind kind,
    DateTime startLocal,
    Duration length,
  ) {
    final s = startLocal.toUtc();
    return AcousticDetection(
      kind: kind,
      startedAtUtc: s,
      endedAtUtc: s.add(length),
      confidence: 0.9,
    );
  }

  test('overlapping music + speech at midday reads as a jam session', () {
    final notes = summarizer.summarize(
      detections: [
        det(
          AcousticDetectionKind.music,
          DateTime(2026, 6, 11, 13, 0),
          const Duration(minutes: 25),
        ),
        det(
          AcousticDetectionKind.speech,
          DateTime(2026, 6, 11, 13, 5),
          const Duration(minutes: 10),
        ),
      ],
    );
    expect(notes, hasLength(1));
    expect(notes.single.label, 'Band practice / jam session');
  });

  test('snoring overnight reads as sleep', () {
    final notes = summarizer.summarize(
      detections: [
        det(
          AcousticDetectionKind.snore,
          DateTime(2026, 6, 11, 2, 0),
          const Duration(minutes: 30),
        ),
      ],
    );
    expect(notes.single.label, 'Sleep');
  });

  test('a fast GPS run becomes a Drive note', () {
    GeoTag fix(DateTime atLocal, double speed) => GeoTag(
      latitude: 1,
      longitude: 2,
      accuracyMeters: 5,
      capturedAtUtc: atLocal.toUtc(),
      speedMetersPerSecond: speed,
    );
    final notes = summarizer.summarize(
      detections: const [],
      geo: [
        fix(DateTime(2026, 6, 11, 17, 0), 18), // 18 m/s ≈ 65 km/h
        fix(DateTime(2026, 6, 11, 17, 5), 20),
      ],
    );
    expect(notes.where((n) => n.label == 'Drive'), hasLength(1));
  });

  test(
    'day title and description format the way SoundCloud will show them',
    () {
      final day = DayOfLife(
        dayLocal: DateTime(2026, 6, 11),
        notes: [
          DayNote(atLocal: DateTime(2026, 6, 11, 8, 30), label: 'Conversation'),
        ],
      );
      expect(day.title, 'Day of My Life — Thursday, Jun 11, 2026');
      expect(day.description, contains('08:30  Conversation'));
    },
  );

  test('an empty day still produces a sane description', () {
    final day = DayOfLife(dayLocal: DateTime(2026, 6, 11), notes: const []);
    expect(day.description, contains('quiet 24 hours'));
  });
}
