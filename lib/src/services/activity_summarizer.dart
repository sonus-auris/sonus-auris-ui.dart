// On-device heuristic that turns a day's acoustic + GPS signals into human-readable activity notes for a Day of My Life.
import '../models/acoustic_detection.dart';
import '../models/day_of_life.dart';
import '../models/geo_tag.dart';

/// Turns a day's on-device signals into human-readable activity notes — the
/// "AI notes" on a Day of My Life ("Band practice", "Drive", "Sleep", …).
///
/// This is an on-device heuristic labeller: it clusters acoustic detections into
/// sessions and reads movement from GPS, entirely on the phone (no audio or
/// location ever leaves the device for this). It is intentionally a clean seam —
/// the [label] step can later be swapped for an on-device LLM without touching
/// the clustering or the callers.
class ActivitySummarizer {
  const ActivitySummarizer({
    this.mergeGap = const Duration(minutes: 20),
    this.drivingSpeedMps = 6.0, // ~22 km/h: clearly vehicular, not walking
  });

  /// Detections closer together than this are treated as one session.
  final Duration mergeGap;

  /// GPS speed (m/s) at or above which a fix is labelled as a drive.
  final double drivingSpeedMps;

  List<DayNote> summarize({
    required List<AcousticDetection> detections,
    List<GeoTag> geo = const [],
  }) {
    final notes = <DayNote>[
      ..._acousticNotes(detections),
      ..._drivingNotes(geo),
    ]..sort((a, b) => a.atLocal.compareTo(b.atLocal));
    return notes;
  }

  List<DayNote> _acousticNotes(List<AcousticDetection> detections) {
    if (detections.isEmpty) {
      return const [];
    }
    final sorted = [...detections]
      ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));

    final notes = <DayNote>[];
    var sessionStart = sorted.first.startedAtUtc;
    var sessionEnd = sorted.first.endedAtUtc;
    final kinds = <AcousticDetectionKind>{sorted.first.kind};

    void flush() {
      notes.add(
        DayNote(
          atLocal: sessionStart.toLocal(),
          label: _labelForSession(
            kinds,
            sessionStart.toLocal(),
            sessionEnd.difference(sessionStart),
          ),
        ),
      );
    }

    for (final d in sorted.skip(1)) {
      if (d.startedAtUtc.difference(sessionEnd) <= mergeGap) {
        kinds.add(d.kind);
        if (d.endedAtUtc.isAfter(sessionEnd)) {
          sessionEnd = d.endedAtUtc;
        }
      } else {
        flush();
        sessionStart = d.startedAtUtc;
        sessionEnd = d.endedAtUtc;
        kinds
          ..clear()
          ..add(d.kind);
      }
    }
    flush();
    return notes;
  }

  String _labelForSession(
    Set<AcousticDetectionKind> kinds,
    DateTime startLocal,
    Duration length,
  ) {
    final hour = startLocal.hour;
    final hasMusic = kinds.contains(AcousticDetectionKind.music);
    final hasSpeech =
        kinds.contains(AcousticDetectionKind.speech) ||
        kinds.contains(AcousticDetectionKind.keyword);
    final hasSleep =
        kinds.contains(AcousticDetectionKind.snore) ||
        kinds.contains(AcousticDetectionKind.apneaPattern) ||
        kinds.contains(AcousticDetectionKind.sleepCycle) ||
        kinds.contains(AcousticDetectionKind.sleepCycleAlarm);

    final atNight = hour >= 22 || hour <= 6;
    if (hasSleep && atNight) {
      return 'Sleep';
    }
    if (hasMusic && hasSpeech && length >= const Duration(minutes: 20)) {
      return 'Band practice / jam session';
    }
    if (hasMusic) {
      return 'Music';
    }
    if (hasSpeech) {
      return length >= const Duration(minutes: 30)
          ? 'A long conversation'
          : 'Conversation';
    }
    if (hasSleep) {
      return 'Resting';
    }
    return 'Ambient sound';
  }

  /// Collapses runs of fast GPS fixes into "Drive" notes.
  List<DayNote> _drivingNotes(List<GeoTag> geo) {
    if (geo.isEmpty) {
      return const [];
    }
    final fast =
        geo
            .where((g) => (g.speedMetersPerSecond ?? 0) >= drivingSpeedMps)
            .toList()
          ..sort((a, b) => a.capturedAtUtc.compareTo(b.capturedAtUtc));
    if (fast.isEmpty) {
      return const [];
    }
    final notes = <DayNote>[];
    var runStart = fast.first.capturedAtUtc;
    var prev = fast.first.capturedAtUtc;
    for (final g in fast.skip(1)) {
      if (g.capturedAtUtc.difference(prev) > mergeGap) {
        notes.add(DayNote(atLocal: runStart.toLocal(), label: 'Drive'));
        runStart = g.capturedAtUtc;
      }
      prev = g.capturedAtUtc;
    }
    notes.add(DayNote(atLocal: runStart.toLocal(), label: 'Drive'));
    return notes;
  }
}
