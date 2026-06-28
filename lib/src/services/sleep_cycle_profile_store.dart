import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/sleep_cycle_profile.dart';
import '../models/sleep_session.dart';

/// Persists the rolling window of nightly [SleepSession] summaries and derives
/// the per-user [SleepCycleProfile] from them.
///
/// Retention is **35 nights** (the spec): older sessions are pruned on every
/// save. Records are tiny summaries (cycle lengths + a coarse depth envelope, no
/// audio), so the whole history is a small JSON blob in [SharedPreferences].
class SleepCycleProfileStore {
  SleepCycleProfileStore({this.retentionDays = 35, this.maxSessions = 60});

  static const _sessionsKey = 'audio_dashcam.sleep.sessions.v1';

  /// Keep at most this many days of history.
  final int retentionDays;

  /// Hard cap on stored sessions regardless of age (belt-and-braces).
  final int maxSessions;

  Future<List<SleepSession>> loadSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sessionsKey);
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .cast<Map<String, dynamic>>()
          .map(SleepSession.fromJson)
          .toList();
    } catch (_) {
      await prefs.remove(_sessionsKey);
      return const [];
    }
  }

  /// Append (or replace by id) [session], prune to the retention window, and
  /// persist. Returns the stored list, newest-last.
  Future<List<SleepSession>> saveSession(
    SleepSession session, {
    DateTime? now,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadSessions();
    final merged = <String, SleepSession>{
      for (final s in existing) s.id: s,
      session.id: session,
    };
    final pruned = _prune(merged.values.toList(), now ?? DateTime.now().toUtc());
    await prefs.setString(
      _sessionsKey,
      jsonEncode(pruned.map((s) => s.toJson()).toList()),
    );
    return pruned;
  }

  /// Load the learned profile. [defaultCycleMinutes] is the cold-start prior used
  /// before any history exists.
  Future<SleepCycleProfile> loadProfile({double defaultCycleMinutes = 90.0}) async {
    final sessions = await loadSessions();
    return SleepCycleProfile.learn(
      sessions,
      defaultCycleMinutes: defaultCycleMinutes,
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionsKey);
  }

  List<SleepSession> _prune(List<SleepSession> sessions, DateTime now) {
    final cutoff = now.subtract(Duration(days: retentionDays));
    final kept = sessions
        .where((s) => s.startedAtUtc.isAfter(cutoff))
        .toList()
      ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    if (kept.length > maxSessions) {
      return kept.sublist(kept.length - maxSessions);
    }
    return kept;
  }
}
