import 'dart:math' as math;

/// Minutes in a day. A window's `endMinute` may equal this (midnight of the next
/// day) to mean "through the end of the day".
const int kMinutesPerDay = 24 * 60;

/// The smallest length a window can have and the grid the editor snaps to.
const int kScheduleSnapMinutes = 15;

/// A single recording window inside one day, expressed in local minutes from
/// midnight. `[startMinute, endMinute)` — start inclusive, end exclusive. Both
/// are clamped to `0..kMinutesPerDay`.
class RecordingWindow {
  const RecordingWindow({required this.startMinute, required this.endMinute});

  final int startMinute;
  final int endMinute;

  int get lengthMinutes => endMinute - startMinute;

  bool get isValid =>
      startMinute >= 0 &&
      endMinute <= kMinutesPerDay &&
      endMinute > startMinute;

  /// Whether [minute] (0..1439) falls inside this window.
  bool contains(int minute) => minute >= startMinute && minute < endMinute;

  RecordingWindow copyWith({int? startMinute, int? endMinute}) =>
      RecordingWindow(
        startMinute: startMinute ?? this.startMinute,
        endMinute: endMinute ?? this.endMinute,
      );

  Map<String, dynamic> toJson() => {'start': startMinute, 'end': endMinute};

  factory RecordingWindow.fromJson(Map<String, dynamic> json) =>
      RecordingWindow(
        startMinute: _asInt(json['start'], 0),
        endMinute: _asInt(json['end'], 0),
      );

  @override
  bool operator ==(Object other) =>
      other is RecordingWindow &&
      other.startMinute == startMinute &&
      other.endMinute == endMinute;

  @override
  int get hashCode => Object.hash(startMinute, endMinute);

  @override
  String toString() => 'RecordingWindow($startMinute..$endMinute)';
}

/// One day's worth of recording windows. When [allDay] is true the explicit
/// [windows] are ignored and the day is treated as a single 0..1440 window.
class DaySchedule {
  const DaySchedule({this.allDay = false, this.windows = const []});

  final bool allDay;
  final List<RecordingWindow> windows;

  static const DaySchedule empty = DaySchedule();

  /// Sorted, clamped, de-overlapped windows. Windows that overlap *or touch*
  /// (the end of one equals the start of the next) are fused into one — this is
  /// what makes dragging a handle onto its neighbour "reconnect" the two windows
  /// into a single smooth span. Zero/negative-length windows are dropped.
  List<RecordingWindow> normalizedWindows() {
    final cleaned = <RecordingWindow>[];
    for (final w in windows) {
      final start = w.startMinute.clamp(0, kMinutesPerDay);
      final end = w.endMinute.clamp(0, kMinutesPerDay);
      if (end > start) {
        cleaned.add(RecordingWindow(startMinute: start, endMinute: end));
      }
    }
    cleaned.sort((a, b) => a.startMinute.compareTo(b.startMinute));
    final merged = <RecordingWindow>[];
    for (final w in cleaned) {
      if (merged.isNotEmpty && w.startMinute <= merged.last.endMinute) {
        final last = merged.removeLast();
        merged.add(
          RecordingWindow(
            startMinute: last.startMinute,
            endMinute: math.max(last.endMinute, w.endMinute),
          ),
        );
      } else {
        merged.add(w);
      }
    }
    return merged;
  }

  /// Returns a copy with its windows normalized (and all-day collapsing the
  /// explicit list since it's unused while [allDay]).
  DaySchedule normalize() => DaySchedule(
        allDay: allDay,
        windows: allDay ? const [] : normalizedWindows(),
      );

  /// The windows that are actually active for this day: a single full-day window
  /// when [allDay], otherwise the normalized list.
  List<RecordingWindow> effectiveWindows() => allDay
      ? const [RecordingWindow(startMinute: 0, endMinute: kMinutesPerDay)]
      : normalizedWindows();

  bool isActiveAtMinute(int minute) =>
      effectiveWindows().any((w) => w.contains(minute));

  bool get hasAnyWindow => allDay || normalizedWindows().isNotEmpty;

  DaySchedule copyWith({bool? allDay, List<RecordingWindow>? windows}) =>
      DaySchedule(
        allDay: allDay ?? this.allDay,
        windows: windows ?? this.windows,
      );

  Map<String, dynamic> toJson() => {
        'allDay': allDay,
        'windows': normalizedWindows().map((w) => w.toJson()).toList(),
      };

  factory DaySchedule.fromJson(Map<String, dynamic> json) => DaySchedule(
        allDay: json['allDay'] as bool? ?? false,
        windows: (json['windows'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => RecordingWindow.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );

  @override
  bool operator ==(Object other) =>
      other is DaySchedule &&
      other.allDay == allDay &&
      _listEquals(other.normalizedWindows(), normalizedWindows());

  @override
  int get hashCode => Object.hash(allDay, Object.hashAll(normalizedWindows()));

  @override
  String toString() => 'DaySchedule(allDay: $allDay, windows: $windows)';
}

/// A transition the schedule produces at a wall-clock instant: at [at] the
/// recorder should start ([startsRecording] true) or stop (false).
class ScheduleTransition {
  const ScheduleTransition({required this.at, required this.startsRecording});

  final DateTime at;
  final bool startsRecording;

  @override
  String toString() =>
      'ScheduleTransition($at, ${startsRecording ? "start" : "stop"})';
}

/// A weekly recording schedule. [days] always has length 7; index 0 = Monday
/// through index 6 = Sunday, matching `DateTime.weekday` (1..7) minus one.
class RecordingSchedule {
  RecordingSchedule({required this.enabled, required List<DaySchedule> days})
      : assert(days.length == 7),
        days = List.unmodifiable(days);

  final bool enabled;
  final List<DaySchedule> days;

  /// Monday-first day labels aligned with [days].
  static const List<String> dayLabels = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static const List<String> dayShortLabels = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  factory RecordingSchedule.defaultSchedule() => RecordingSchedule(
        enabled: false,
        days: List.generate(7, (_) => DaySchedule.empty),
      );

  /// The [days] index for a Dart [DateTime] (weekday 1=Mon..7=Sun).
  static int dayIndexFor(DateTime dateTime) => dateTime.weekday - 1;

  DaySchedule dayFor(DateTime dateTime) => days[dayIndexFor(dateTime)];

  /// Whether recording should be active at the local wall-clock [at].
  bool isActiveAt(DateTime at) {
    if (!enabled) {
      return false;
    }
    final minute = at.hour * 60 + at.minute;
    return dayFor(at).isActiveAtMinute(minute);
  }

  /// The next transition strictly after [from] (local time), scanning forward up
  /// to [horizonDays]. Returns null when the schedule is disabled or empty.
  /// Correctly handles back-to-back windows across midnight (e.g. all-day today
  /// and all-day tomorrow collapse to no transition at the boundary).
  ScheduleTransition? nextTransitionAfter(
    DateTime from, {
    int horizonDays = 8,
  }) {
    if (!enabled) {
      return null;
    }
    // Every window edge across the horizon is a candidate transition instant.
    final startOfDay = DateTime(from.year, from.month, from.day);
    final candidates = <DateTime>[];
    for (var dayOffset = 0; dayOffset <= horizonDays; dayOffset++) {
      final date = startOfDay.add(Duration(days: dayOffset));
      for (final w in days[dayIndexFor(date)].effectiveWindows()) {
        candidates
          ..add(date.add(Duration(minutes: w.startMinute)))
          ..add(date.add(Duration(minutes: w.endMinute)));
      }
    }
    candidates.sort();
    for (final at in candidates) {
      if (!at.isAfter(from)) {
        continue;
      }
      // A real transition is where the active-state actually flips. Comparing
      // the minute before with the edge instant collapses abutting windows
      // (incl. all-day spans across midnight), which share an instant but don't
      // change the state.
      final before = isActiveAt(at.subtract(const Duration(minutes: 1)));
      final atState = isActiveAt(at);
      if (atState != before) {
        return ScheduleTransition(at: at, startsRecording: atState);
      }
    }
    return null;
  }

  /// All transitions in `(from, from + horizonDays]`, in chronological order —
  /// used to batch-register OS alarms/notifications.
  List<ScheduleTransition> upcomingTransitions(
    DateTime from, {
    int horizonDays = 8,
  }) {
    final transitions = <ScheduleTransition>[];
    var cursor = from;
    final limit = from.add(Duration(days: horizonDays));
    while (true) {
      final next = nextTransitionAfter(cursor, horizonDays: horizonDays);
      if (next == null || next.at.isAfter(limit)) {
        break;
      }
      transitions.add(next);
      cursor = next.at;
    }
    return transitions;
  }

  RecordingSchedule copyWith({bool? enabled, List<DaySchedule>? days}) =>
      RecordingSchedule(
        enabled: enabled ?? this.enabled,
        days: days ?? this.days,
      );

  /// Replaces a single day (by [index]) and returns a new schedule.
  RecordingSchedule withDay(int index, DaySchedule day) {
    final next = List<DaySchedule>.from(days);
    next[index] = day;
    return copyWith(days: next);
  }

  /// Normalizes every day (merge/clamp) — call before persisting.
  RecordingSchedule normalize() =>
      copyWith(days: days.map((d) => d.normalize()).toList());

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'days': days.map((d) => d.toJson()).toList(),
      };

  factory RecordingSchedule.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return RecordingSchedule.defaultSchedule();
    }
    final rawDays = (json['days'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => DaySchedule.fromJson(e.cast<String, dynamic>()))
        .toList();
    // Tolerate a malformed/short list by padding to 7 empty days.
    final days = List<DaySchedule>.generate(
      7,
      (i) => i < rawDays.length ? rawDays[i] : DaySchedule.empty,
    );
    return RecordingSchedule(
      enabled: json['enabled'] as bool? ?? false,
      days: days,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RecordingSchedule &&
      other.enabled == enabled &&
      _listEquals(other.days, days);

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll(days));

  @override
  String toString() => 'RecordingSchedule(enabled: $enabled, days: $days)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

int _asInt(Object? value, int fallback) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}
