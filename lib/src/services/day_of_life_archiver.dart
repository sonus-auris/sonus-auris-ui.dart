// Builds a Day of My Life: compresses a day's audio, adds on-device activity notes, and publishes/prunes it as a private SoundCloud track.
import 'dart:typed_data';

import 'package:intl/intl.dart';

import '../models/acoustic_detection.dart';
import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import '../models/day_of_life.dart';
import '../models/geo_tag.dart';
import 'activity_summarizer.dart';
import 'audio_encoder.dart';
import 'place_resolver.dart';
import 'soundcloud_client.dart';

class DayArchiveResult {
  const DayArchiveResult({this.trackUrl, this.noteCount = 0, this.prunedCount = 0, this.note});

  final String? trackUrl;
  final int noteCount;
  final int prunedCount;
  final String? note;

  bool get didUpload => trackUrl != null;
}

/// Publishes a full "Day of My Life" to the user's SoundCloud: one 24-hour track
/// per day, captioned with on-device AI activity notes, keeping a rolling window
/// of the last [DayOfLife.rollingDays] days (older ones pruned automatically).
///
/// Strictly opt-in: only runs when SoundCloud is linked *and* the daily-archive
/// setting is on. The audio leaves the encrypted vault by the user's explicit
/// choice — it is published as a **private** track.
class DayOfLifeArchiver {
  DayOfLifeArchiver({
    SoundCloudClient? soundCloud,
    ActivitySummarizer? summarizer,
    AudioEncoder? encoder,
    PlaceResolver? placeResolver,
  })  : _soundCloud = soundCloud ?? SoundCloudClient(),
        _summarizer = summarizer ?? const ActivitySummarizer(),
        _encoder = encoder ?? AudioEncoder(),
        _placeResolver = placeResolver ?? const PlaceResolver();

  final SoundCloudClient _soundCloud;
  final ActivitySummarizer _summarizer;
  final AudioEncoder _encoder;
  final PlaceResolver _placeResolver;

  bool isEnabled(AppConfig config, CloudSecrets secrets) =>
      config.soundCloudDailyArchive && secrets.hasSoundCloudToken;

  /// Archives [dayLocal]'s audio + AI notes, then prunes anything beyond the
  /// rolling window. Best-effort; returns what happened.
  Future<DayArchiveResult> archiveDay({
    required CloudSecrets secrets,
    required DateTime dayLocal,
    required Uint8List? wavBytes,
    required List<AcousticDetection> detections,
    List<GeoTag> geo = const [],
    bool resolvePlaces = false,
  }) async {
    var notes = _summarizer.summarize(detections: detections, geo: geo);
    if (resolvePlaces && geo.isNotEmpty) {
      notes = await _enrichDriveNotesWithPlaces(notes, geo);
    }
    final day = DayOfLife(dayLocal: dayLocal, notes: notes);

    if (wavBytes == null || wavBytes.isEmpty) {
      return const DayArchiveResult(note: 'No local audio for that day.');
    }

    // Compress on-device before upload: 24h of WAV is gigabytes. Fall back to
    // the raw WAV only if the native encoder is unavailable.
    final encoded = await _encoder.encodeToAac(wavBytes: wavBytes);
    final stamp = DateFormat('yyyy-MM-dd').format(dayLocal);
    final upload = await _soundCloud.uploadTrack(
      accessToken: secrets.soundCloudAccessToken,
      audioBytes: encoded?.bytes ?? wavBytes,
      title: day.title,
      description: day.description,
      isPublic: false,
      fileName: 'day-$stamp.${encoded?.fileExtension ?? 'wav'}',
    );
    if (upload == null) {
      return const DayArchiveResult(note: 'SoundCloud upload failed.');
    }

    final pruned = await _pruneBeyondWindow(secrets.soundCloudAccessToken);
    return DayArchiveResult(
      trackUrl: upload.permalinkUrl,
      noteCount: notes.length,
      prunedCount: pruned,
    );
  }

  /// Keeps the newest [DayOfLife.rollingDays] daily tracks; deletes the rest.
  Future<int> _pruneBeyondWindow(String accessToken) async {
    final tracks = await _soundCloud.listArchiveTracks(
      accessToken: accessToken,
      titlePrefix: DayOfLife.titlePrefix,
    );
    if (tracks.length <= DayOfLife.rollingDays) {
      return 0;
    }
    // Sort newest-first by the date parsed from the title; unparseable titles
    // sort oldest so they're the first to be pruned.
    final dated = tracks
        .map((t) => (id: t.id, day: _dayFromTitle(t.title)))
        .toList()
      ..sort((a, b) {
        final ad = a.day, bd = b.day;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad);
      });

    var pruned = 0;
    for (final track in dated.skip(DayOfLife.rollingDays)) {
      final ok = await _soundCloud.deleteTrack(
        accessToken: accessToken,
        id: track.id,
      );
      if (ok) pruned += 1;
    }
    return pruned;
  }

  /// Appends a place name to each "Drive" note ("Drive → Santa Cruz") by
  /// reverse-geocoding the GPS fix nearest that note's time. Best-effort.
  Future<List<DayNote>> _enrichDriveNotesWithPlaces(
    List<DayNote> notes,
    List<GeoTag> geo,
  ) async {
    final out = <DayNote>[];
    for (final note in notes) {
      if (note.label != 'Drive') {
        out.add(note);
        continue;
      }
      final fix = _nearestFix(geo, note.atLocal);
      final place = fix == null
          ? null
          : await _placeResolver.describe(fix.latitude, fix.longitude);
      out.add(
        place == null
            ? note
            : DayNote(atLocal: note.atLocal, label: 'Drive → $place'),
      );
    }
    return out;
  }

  GeoTag? _nearestFix(List<GeoTag> geo, DateTime atLocal) {
    GeoTag? best;
    Duration bestGap = const Duration(days: 999);
    final target = atLocal.toUtc();
    for (final g in geo) {
      final gap = (g.capturedAtUtc.difference(target)).abs();
      if (gap < bestGap) {
        bestGap = gap;
        best = g;
      }
    }
    return best;
  }

  DateTime? _dayFromTitle(String title) {
    final marker = '${DayOfLife.titlePrefix} — ';
    if (!title.startsWith(marker)) {
      return null;
    }
    try {
      return DateFormat('EEEE, MMM d, y').parse(title.substring(marker.length));
    } catch (_) {
      return null;
    }
  }

  void close() => _soundCloud.close();
}
