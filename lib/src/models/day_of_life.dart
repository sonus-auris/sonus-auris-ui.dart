import 'package:intl/intl.dart';

/// A single AI-generated annotation on a day's timeline, e.g. "08:30 — Band
/// practice" or "17:10 — Drive". Times are local to the user.
class DayNote {
  const DayNote({required this.atLocal, required this.label});

  final DateTime atLocal;
  final String label;

  String get timeLabel => DateFormat('HH:mm').format(atLocal);

  Map<String, Object?> toJson() => {
    'at': atLocal.toIso8601String(),
    'label': label,
  };
}

/// One "Day of My Life" — a 24-hour capture published as a single SoundCloud
/// track, captioned with on-device AI activity notes. The app keeps a rolling
/// window of these (the last [DayOfLife.rollingDays] days) on the user's
/// SoundCloud, oldest pruned automatically.
class DayOfLife {
  const DayOfLife({required this.dayLocal, required this.notes});

  /// Midnight (local) of the day this archive covers.
  final DateTime dayLocal;
  final List<DayNote> notes;

  /// How many recent days are kept on SoundCloud before the oldest is pruned.
  static const int rollingDays = 100;

  /// Stable title prefix used to recognise (and prune) our own daily tracks.
  static const String titlePrefix = 'Day of My Life';

  String get dateLabel => DateFormat('EEEE, MMM d, y').format(dayLocal);

  /// "Day of My Life — Thursday, Jun 11, 2026"
  String get title => '$titlePrefix — $dateLabel';

  /// SoundCloud track description: the AI activity notes as a readable timeline.
  String get description {
    if (notes.isEmpty) {
      return 'A quiet 24 hours, captured by Sonus Auris. No standout moments detected.';
    }
    final lines = notes.map((n) => '${n.timeLabel}  ${n.label}').join('\n');
    return 'A day in the life, captured by Sonus Auris.\n\n$lines';
  }
}
