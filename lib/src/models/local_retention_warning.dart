import 'recording_segment.dart';

/// Content-free projection for one local segment that has no durable copy before
/// its non-bypassable plaintext-retention deadline.
///
/// This model intentionally carries no audio, transcript, local path, remote
/// object key, provider error, token, or encryption material. It is suitable for
/// privacy-dashboard rendering and content-free operational counters.
class LocalRetentionWarning {
  const LocalRetentionWarning({
    required this.segmentId,
    required this.expiresAtUtc,
    required this.byteSize,
    required this.uploadStatus,
  });

  final String segmentId;
  final DateTime expiresAtUtc;
  final int byteSize;
  final SegmentUploadStatus uploadStatus;

  Duration remainingAt(DateTime nowUtc) =>
      expiresAtUtc.difference(nowUtc.toUtc());

  bool isOverdueAt(DateTime nowUtc) =>
      !expiresAtUtc.isAfter(nowUtc.toUtc());

  String deletionMessageAt(DateTime nowUtc) {
    final deadline = expiresAtUtc.toUtc().toIso8601String();
    if (isOverdueAt(nowUtc)) {
      return 'Backup did not complete. The local copy reached its deletion deadline at $deadline.';
    }
    return 'Backup has not completed. The local copy will be deleted at $deadline.';
  }

  /// A deliberately bounded diagnostic shape. Do not add paths, object keys,
  /// provider responses, transcripts, or any captured content here.
  Map<String, Object> toDiagnosticMap(DateTime nowUtc) => {
    'segmentId': segmentId,
    'expiresAtUtc': expiresAtUtc.toUtc().toIso8601String(),
    'byteSize': byteSize,
    'uploadStatus': uploadStatus.name,
    'overdue': isOverdueAt(nowUtc),
  };
}
