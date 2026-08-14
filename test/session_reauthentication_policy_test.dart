import 'package:audio_dashcam/src/app/session_reauthentication_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final startedAt = DateTime.utc(2026, 1, 1);

  test('does not warn before five weeks', () {
    final decision = evaluateSessionReauthentication(
      sessionStartedAtUtc: startedAt,
      lastReminderCheckpoint: 0,
      now: startedAt.add(const Duration(days: 34)),
    );
    expect(decision.shouldWarn, isFalse);
  });

  test('warns once at weeks five and ten', () {
    final weekFive = evaluateSessionReauthentication(
      sessionStartedAtUtc: startedAt,
      lastReminderCheckpoint: 0,
      now: startedAt.add(const Duration(days: 35)),
    );
    expect(weekFive.shouldWarn, isTrue);
    expect(weekFive.reminderCheckpoint, 1);
    final weekTen = evaluateSessionReauthentication(
      sessionStartedAtUtc: startedAt,
      lastReminderCheckpoint: 1,
      now: startedAt.add(const Duration(days: 70)),
    );
    expect(weekTen.shouldWarn, isTrue);
    expect(weekTen.reminderCheckpoint, 2);
  });

  test('requires full sign-in at fifteen weeks', () {
    final decision = evaluateSessionReauthentication(
      sessionStartedAtUtc: startedAt,
      lastReminderCheckpoint: 2,
      now: startedAt.add(const Duration(days: 105)),
    );
    expect(decision.expired, isTrue);
    expect(decision.message, contains('15-week'));
  });

  test('future clocks do not create false warnings', () {
    final decision = evaluateSessionReauthentication(
      sessionStartedAtUtc: startedAt.add(const Duration(minutes: 2)),
      lastReminderCheckpoint: 0,
      now: startedAt,
    );
    expect(decision.expired, isFalse);
    expect(decision.shouldWarn, isFalse);
  });
}
