// Immutable snapshot of recorder state (recording flag, active segment, live peak/average dB) for the UI.
class RecorderSnapshot {
  const RecorderSnapshot({
    required this.isRecording,
    required this.isStarting,
    this.activeSegmentPath,
    this.activeSegmentStartedAtUtc,
    this.peakDb = -120,
    this.averageDb = -120,
    this.error,
  });

  const RecorderSnapshot.idle()
    : isRecording = false,
      isStarting = false,
      activeSegmentPath = null,
      activeSegmentStartedAtUtc = null,
      peakDb = -120,
      averageDb = -120,
      error = null;

  final bool isRecording;
  final bool isStarting;
  final String? activeSegmentPath;
  final DateTime? activeSegmentStartedAtUtc;
  final double peakDb;
  final double averageDb;
  final String? error;

  Duration? activeDuration(DateTime nowUtc) {
    final startedAt = activeSegmentStartedAtUtc;
    return startedAt == null ? null : nowUtc.difference(startedAt);
  }

  RecorderSnapshot copyWith({
    bool? isRecording,
    bool? isStarting,
    Object? activeSegmentPath = _unset,
    Object? activeSegmentStartedAtUtc = _unset,
    double? peakDb,
    double? averageDb,
    Object? error = _unset,
  }) {
    return RecorderSnapshot(
      isRecording: isRecording ?? this.isRecording,
      isStarting: isStarting ?? this.isStarting,
      activeSegmentPath: identical(activeSegmentPath, _unset)
          ? this.activeSegmentPath
          : activeSegmentPath as String?,
      activeSegmentStartedAtUtc: identical(activeSegmentStartedAtUtc, _unset)
          ? this.activeSegmentStartedAtUtc
          : activeSegmentStartedAtUtc as DateTime?,
      peakDb: peakDb ?? this.peakDb,
      averageDb: averageDb ?? this.averageDb,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }

  static const _unset = Object();
}
