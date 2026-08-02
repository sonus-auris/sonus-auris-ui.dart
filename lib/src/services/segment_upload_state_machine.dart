// Production upload-attempt transitions shared by AppController and formal tests.
import '../models/recording_segment.dart';

/// Deterministic, persistence-safe upload-attempt transitions.
///
/// [RecordingSegment.activeUploadGeneration] identifies the only network result
/// allowed to mutate the segment. Beginning a retry advances the generation;
/// retention deletion or restart invalidates the prior active generation. A late
/// success/failure therefore stutters instead of overwriting newer durable state.
abstract final class SegmentUploadStateMachine {
  static bool canBegin(RecordingSegment segment) {
    return segment.isLocal &&
        (segment.uploadStatus == SegmentUploadStatus.pending ||
            segment.uploadStatus == SegmentUploadStatus.uploading ||
            segment.uploadStatus == SegmentUploadStatus.failed);
  }

  static RecordingSegment begin(RecordingSegment segment) {
    if (!canBegin(segment)) {
      throw StateError(
        'Upload attempts require local plaintext in a retryable state.',
      );
    }
    final generation = _nextGeneration(segment);
    return segment.copyWith(
      uploadStatus: SegmentUploadStatus.uploading,
      nextUploadGeneration: generation + 1,
      activeUploadGeneration: generation,
      error: null,
    );
  }

  static RecordingSegment succeed({
    required RecordingSegment current,
    required int generation,
    required String remoteKey,
    required DateTime uploadedAtUtc,
  }) {
    final key = remoteKey.trim();
    if (generation <= 0) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
    if (key.isEmpty) {
      throw ArgumentError.value(remoteKey, 'remoteKey', 'must not be empty');
    }
    if (current.activeUploadGeneration != generation) {
      return current;
    }
    return current.copyWith(
      uploadStatus: SegmentUploadStatus.uploaded,
      remoteKey: key,
      uploadedAtUtc: uploadedAtUtc.toUtc(),
      activeUploadGeneration: 0,
      acknowledgedUploadGeneration: generation,
      nextUploadGeneration: _atLeast(
        current.nextUploadGeneration,
        generation + 1,
      ),
      error: null,
    );
  }

  static RecordingSegment fail({
    required RecordingSegment current,
    required int generation,
    required String? error,
  }) {
    if (generation <= 0) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
    if (current.activeUploadGeneration != generation) {
      return current;
    }
    return current.copyWith(
      uploadStatus: SegmentUploadStatus.failed,
      activeUploadGeneration: 0,
      nextUploadGeneration: _atLeast(
        current.nextUploadGeneration,
        generation + 1,
      ),
      error: error,
    );
  }

  /// Invalidates any in-flight result before local deletion becomes durable.
  static RecordingSegment invalidateForLocalDeletion(
    RecordingSegment segment,
  ) {
    final invalidatedGeneration = segment.activeUploadGeneration;
    return segment.copyWith(
      activeUploadGeneration: 0,
      nextUploadGeneration: invalidatedGeneration <= 0
          ? _atLeast(segment.nextUploadGeneration, 1)
          : _atLeast(
              segment.nextUploadGeneration,
              invalidatedGeneration + 1,
            ),
    );
  }

  /// Clears process-owned attempt state while preserving the persisted status.
  static RecordingSegment restart(RecordingSegment segment) {
    return invalidateForLocalDeletion(segment);
  }

  /// Stable abstract projection used by refinement tests and future ITF replay.
  static Map<String, Object?> project(RecordingSegment segment) {
    return <String, Object?>{
      'status': segment.uploadStatus.name,
      'isLocal': segment.isLocal,
      'hasVerifiedRemote': segment.isUploaded,
      'nextGeneration': segment.nextUploadGeneration,
      'activeGeneration': segment.activeUploadGeneration,
      'acknowledgedGeneration': segment.acknowledgedUploadGeneration,
    };
  }

  static int _nextGeneration(RecordingSegment segment) {
    var generation = _atLeast(segment.nextUploadGeneration, 1);
    generation = _atLeast(generation, segment.activeUploadGeneration + 1);
    generation = _atLeast(
      generation,
      segment.acknowledgedUploadGeneration + 1,
    );
    return generation;
  }

  static int _atLeast(int value, int minimum) {
    return value < minimum ? minimum : value;
  }
}
