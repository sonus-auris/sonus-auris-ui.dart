import '../models/local_retention_warning.dart';
import '../models/recording_segment.dart';

/// Computes truthful, content-free pre-expiry warnings for local plaintext.
///
/// Upload retries, offline operation, timezone changes, and provider failures do
/// not move the deadline. The policy rejects any configured duration above the
/// product's 100-hour hard ceiling instead of silently extending retention.
class LocalRetentionPolicy {
  LocalRetentionPolicy({
    required int retentionHours,
    this.warningHorizon = const Duration(hours: 12),
  }) : retention = _validatedRetention(retentionHours) {
    _validateHorizon(warningHorizon, 'warningHorizon');
  }

  static const int maxPlaintextRetentionHours = 100;

  final Duration retention;
  final Duration warningHorizon;

  DateTime expiresAtUtc(RecordingSegment segment) =>
      segment.endedAtUtc.toUtc().add(retention);

  List<LocalRetentionWarning> warnings({
    required Iterable<RecordingSegment> segments,
    required DateTime nowUtc,
    Duration? horizon,
    bool includeOverdue = true,
  }) {
    final effectiveHorizon = horizon ?? warningHorizon;
    _validateHorizon(effectiveHorizon, 'horizon');

    final now = nowUtc.toUtc();
    final cutoff = now.add(effectiveHorizon);
    final result = <LocalRetentionWarning>[];

    for (final segment in segments) {
      // A remote key alone is not enough: RecordingSegment.isUploaded also
      // requires the verified uploaded state. A permanent copy is separately
      // explicit. Everything else remains subject to local deletion.
      if (!segment.isLocal || segment.isUploaded || segment.isPermanentlySaved) {
        continue;
      }

      final expiresAt = expiresAtUtc(segment);
      final overdue = !expiresAt.isAfter(now);
      if ((!includeOverdue && overdue) || expiresAt.isAfter(cutoff)) {
        continue;
      }

      result.add(
        LocalRetentionWarning(
          segmentId: segment.id,
          expiresAtUtc: expiresAt,
          byteSize: segment.byteSize,
          uploadStatus: segment.uploadStatus,
        ),
      );
    }

    result.sort((left, right) {
      final byExpiry = left.expiresAtUtc.compareTo(right.expiresAtUtc);
      return byExpiry != 0
          ? byExpiry
          : left.segmentId.compareTo(right.segmentId);
    });
    return List.unmodifiable(result);
  }

  LocalRetentionWarning? earliestWarning({
    required Iterable<RecordingSegment> segments,
    required DateTime nowUtc,
    Duration? horizon,
    bool includeOverdue = true,
  }) {
    final matches = warnings(
      segments: segments,
      nowUtc: nowUtc,
      horizon: horizon,
      includeOverdue: includeOverdue,
    );
    return matches.isEmpty ? null : matches.first;
  }

  int overdueCount({
    required Iterable<RecordingSegment> segments,
    required DateTime nowUtc,
  }) => warnings(
    segments: segments,
    nowUtc: nowUtc,
    horizon: Duration.zero,
  ).length;

  static Duration _validatedRetention(int hours) {
    if (hours < 1 || hours > maxPlaintextRetentionHours) {
      throw RangeError.range(
        hours,
        1,
        maxPlaintextRetentionHours,
        'retentionHours',
        'must remain inside the non-bypassable plaintext-retention ceiling',
      );
    }
    return Duration(hours: hours);
  }

  static void _validateHorizon(Duration value, String name) {
    if (value.isNegative) {
      throw ArgumentError.value(value, name, 'must not be negative');
    }
  }
}
