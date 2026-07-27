import 'recording_segment.dart';

/// Content-free UI/telemetry projection for a local segment that has no durable
/// remote/permanent copy before its configured plaintext-retention deadline.
///
/// This model intentionally carries no audio, transcript, path, remote key, or
/// encryption material. It is safe to show in the privacy dashboard and to count
/// in diagnostics without leaking content.
class LocalRetentionWarning {
  const LocalRetentionWarning({
    required this.segmentId,
    required this.expiresAtUtc,
    required this.byteSize,
    required this.uploadStatus,
    this.lastError,
  });

  final String segmentId;
  final DateTime expiresAtUtc;
  final int byteSize;
  final SegmentUploadStatus uploadStatus;
  final String? lastError;

  Duration remainingAt(DateTime nowUtc) =>
      expiresAtUtc.difference(nowUtc.toUtc());

  bool isOverdueAt(DateTime nowUtc) =>
      !expiresAtUtc.isAfter(nowUtc.toUtc());

  String deletionMessageAt(DateTime nowUtc) {
    if (isOverdueAt(nowUtc)) {
      return 'Backup did not complete. The local copy reached its deletion deadline at ${expiresAtUtc.toIso8601String()}.';
    }
    return 'Backup has not completed. The local copy will be deleted at ${expiresAtUtc.toIso8601String()}.';
  }
}
