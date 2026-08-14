const Duration sonusSessionReminderInterval = Duration(days: 35);
const Duration sonusSessionMaximumLifetime = Duration(days: 105);

class SessionReauthenticationDecision {
  const SessionReauthenticationDecision._({
    required this.expired,
    required this.reminderCheckpoint,
    this.message,
  });

  const SessionReauthenticationDecision.none()
    : this._(expired: false, reminderCheckpoint: 0);

  final bool expired;
  final int reminderCheckpoint;
  final String? message;

  bool get shouldWarn => !expired && message != null;
}

SessionReauthenticationDecision evaluateSessionReauthentication({
  required DateTime sessionStartedAtUtc,
  required int lastReminderCheckpoint,
  DateTime? now,
}) {
  final reference = (now ?? DateTime.now()).toUtc();
  final startedAt = sessionStartedAtUtc.toUtc();
  if (startedAt.isAfter(reference)) {
    return const SessionReauthenticationDecision.none();
  }
  final age = reference.difference(startedAt);
  if (age >= sonusSessionMaximumLifetime) {
    return const SessionReauthenticationDecision._(
      expired: true,
      reminderCheckpoint: 3,
      message:
          'Your 15-week Sonus Auris session ended. Sign in again to continue.',
    );
  }
  final checkpoint = age.inDays ~/ sonusSessionReminderInterval.inDays;
  if (checkpoint < 1 || checkpoint <= lastReminderCheckpoint) {
    return const SessionReauthenticationDecision.none();
  }
  final remainingWeeks =
      (sonusSessionMaximumLifetime.inDays - age.inDays + 6) ~/ 7;
  return SessionReauthenticationDecision._(
    expired: false,
    reminderCheckpoint: checkpoint.clamp(1, 2),
    message:
        'Security reminder: sign in again to start a new 15-week session. '
        'This session has about $remainingWeeks weeks remaining.',
  );
}
