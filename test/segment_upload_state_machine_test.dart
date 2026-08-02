import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/services/segment_upload_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SegmentUploadStateMachine', () {
    test('migrates legacy rows into a valid generation domain', () {
      final migrated = RecordingSegment.fromJson(<String, Object?>{
        'id': 'segment-1',
        'startedAtUtc': '2026-08-01T00:00:00Z',
        'endedAtUtc': '2026-08-01T00:01:00Z',
        'byteSize': 10,
        'uploadStatus': 'pending',
        'localPath': '/private/segment.wav',
      });

      expect(migrated.nextUploadGeneration, 1);
      expect(migrated.activeUploadGeneration, 0);
      expect(migrated.acknowledgedUploadGeneration, 0);
      expect(
        RecordingSegment.fromJson(migrated.toJson()).toJson(),
        migrated.toJson(),
      );
    });

    test('retry advances generation and stale results stutter', () {
      final first = SegmentUploadStateMachine.begin(_segment());
      expect(first.activeUploadGeneration, 1);
      expect(first.nextUploadGeneration, 2);
      expect(first.uploadStatus, SegmentUploadStatus.uploading);

      final restarted = SegmentUploadStateMachine.restart(first);
      expect(restarted.activeUploadGeneration, 0);
      expect(restarted.nextUploadGeneration, 2);

      final second = SegmentUploadStateMachine.begin(restarted);
      expect(second.activeUploadGeneration, 2);
      expect(second.nextUploadGeneration, 3);

      final staleSuccess = SegmentUploadStateMachine.succeed(
        current: second,
        generation: 1,
        remoteKey: 'stale/object',
        uploadedAtUtc: DateTime.utc(2026, 8, 1, 1),
      );
      final staleFailure = SegmentUploadStateMachine.fail(
        current: second,
        generation: 1,
        error: 'late failure',
      );
      expect(identical(staleSuccess, second), isTrue);
      expect(identical(staleFailure, second), isTrue);

      final completed = SegmentUploadStateMachine.succeed(
        current: second,
        generation: 2,
        remoteKey: 'verified/object',
        uploadedAtUtc: DateTime.utc(2026, 8, 1, 2),
      );
      expect(completed.uploadStatus, SegmentUploadStatus.uploaded);
      expect(completed.activeUploadGeneration, 0);
      expect(completed.acknowledgedUploadGeneration, 2);
      expect(completed.nextUploadGeneration, 3);
      expect(completed.remoteKey, 'verified/object');
      expect(completed.isUploaded, isTrue);
    });

    test('retention invalidation prevents late authority from returning', () {
      final uploading = SegmentUploadStateMachine.begin(_segment());
      final deleted = SegmentUploadStateMachine.invalidateForLocalDeletion(
        uploading.copyWith(localPath: null),
      );

      expect(deleted.isLocal, isFalse);
      expect(deleted.activeUploadGeneration, 0);
      expect(deleted.nextUploadGeneration, 2);
      expect(SegmentUploadStateMachine.canBegin(deleted), isFalse);

      final late = SegmentUploadStateMachine.succeed(
        current: deleted,
        generation: 1,
        remoteKey: 'late/object',
        uploadedAtUtc: DateTime.utc(2026, 8, 1, 3),
      );
      expect(identical(late, deleted), isTrue);
      expect(late.remoteKey, isNull);
    });

    test(
      'failed current attempt remains retryable with a newer generation',
      () {
        final first = SegmentUploadStateMachine.begin(_segment());
        final failed = SegmentUploadStateMachine.fail(
          current: first,
          generation: first.activeUploadGeneration,
          error: 'network unavailable',
        );
        expect(failed.uploadStatus, SegmentUploadStatus.failed);
        expect(failed.activeUploadGeneration, 0);
        expect(failed.nextUploadGeneration, 2);

        final retry = SegmentUploadStateMachine.begin(failed);
        expect(retry.activeUploadGeneration, 2);
        expect(retry.nextUploadGeneration, 3);
        expect(retry.error, isNull);
      },
    );

    test('formal projection is content-free and stable', () {
      final uploading = SegmentUploadStateMachine.begin(_segment());
      expect(SegmentUploadStateMachine.project(uploading), <String, Object?>{
        'status': 'uploading',
        'isLocal': true,
        'hasVerifiedRemote': false,
        'nextGeneration': 2,
        'activeGeneration': 1,
        'acknowledgedGeneration': 0,
      });
    });
  });
}

RecordingSegment _segment() {
  return RecordingSegment(
    id: 'segment-1',
    startedAtUtc: DateTime.utc(2026, 8, 1),
    endedAtUtc: DateTime.utc(2026, 8, 1, 0, 1),
    localPath: '/private/segment.wav',
    byteSize: 10,
    uploadStatus: SegmentUploadStatus.pending,
  );
}
