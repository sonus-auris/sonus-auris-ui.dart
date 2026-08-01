import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/retention/local_retention_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalRetentionPolicy', () {
    test('computes the exact UTC deadline at the 100-hour ceiling', () {
      final policy = LocalRetentionPolicy(retentionHours: 100);
      final segment = _segment(
        id: 'segment-a',
        endedAtUtc: DateTime.parse('2026-07-27T18:01:00-04:00'),
        status: SegmentUploadStatus.failed,
      );

      expect(
        policy.expiresAtUtc(segment),
        DateTime.parse('2026-08-01T02:01:00Z'),
      );
    });

    test('rejects zero, negative, and above-ceiling retention', () {
      expect(
        () => LocalRetentionPolicy(retentionHours: 0),
        throwsRangeError,
      );
      expect(
        () => LocalRetentionPolicy(retentionHours: -1),
        throwsRangeError,
      );
      expect(
        () => LocalRetentionPolicy(retentionHours: 101),
        throwsRangeError,
      );
      expect(
        LocalRetentionPolicy(retentionHours: 1).retention,
        const Duration(hours: 1),
      );
    });

    test('returns only unbacked local segments inside the warning horizon', () {
      final now = DateTime.utc(2026, 7, 27, 12);
      final policy = LocalRetentionPolicy(retentionHours: 100);
      final warnings = policy.warnings(
        nowUtc: now,
        segments: [
          _segment(
            id: 'later',
            endedAtUtc: now.subtract(const Duration(hours: 89)),
            status: SegmentUploadStatus.pending,
            error: 'provider/path details must never enter warning output',
          ),
          _segment(
            id: 'earlier',
            endedAtUtc: now.subtract(const Duration(hours: 95)),
            status: SegmentUploadStatus.failed,
          ),
          _segment(
            id: 'outside-horizon',
            endedAtUtc: now.subtract(const Duration(hours: 80)),
            status: SegmentUploadStatus.pending,
          ),
        ],
      );

      expect(warnings.map((warning) => warning.segmentId), ['earlier', 'later']);
      expect(warnings.first.expiresAtUtc, now.add(const Duration(hours: 5)));
      expect(
        warnings.first.deletionMessageAt(now),
        'Backup has not completed. The local copy will be deleted at 2026-07-27T17:00:00.000Z.',
      );
      expect(
        warnings.first.toDiagnosticMap(now).keys,
        containsAll(<String>[
          'segmentId',
          'expiresAtUtc',
          'byteSize',
          'uploadStatus',
          'overdue',
        ]),
      );
      expect(
        warnings.first.toDiagnosticMap(now).keys,
        isNot(contains(anyOf('path', 'remoteKey', 'error', 'transcript'))),
      );
    });

    test('excludes uploaded, permanent, and non-local segments', () {
      final now = DateTime.utc(2026, 7, 27, 12);
      final endedAt = now.subtract(const Duration(hours: 99));
      final policy = LocalRetentionPolicy(retentionHours: 100);

      expect(
        policy.warnings(
          nowUtc: now,
          segments: [
            _segment(
              id: 'uploaded',
              endedAtUtc: endedAt,
              status: SegmentUploadStatus.uploaded,
              remoteKey: 'rolling/uploaded.wav.enc',
            ),
            _segment(
              id: 'permanent',
              endedAtUtc: endedAt,
              status: SegmentUploadStatus.failed,
              permanentRemoteKey: 'permanent/saved.wav.enc',
            ),
            _segment(
              id: 'non-local',
              endedAtUtc: endedAt,
              status: SegmentUploadStatus.failed,
              localPath: null,
            ),
          ],
        ),
        isEmpty,
      );
    });

    test('remote key alone is not treated as a verified backup', () {
      final now = DateTime.utc(2026, 7, 27, 12);
      final policy = LocalRetentionPolicy(retentionHours: 100);
      final segment = _segment(
        id: 'unverified-remote',
        endedAtUtc: now.subtract(const Duration(hours: 99)),
        status: SegmentUploadStatus.failed,
        remoteKey: 'rolling/unverified.wav.enc',
      );

      expect(
        policy.warnings(nowUtc: now, segments: [segment])
            .map((warning) => warning.segmentId),
        ['unverified-remote'],
      );
    });

    test('orders equal deadlines by id and returns an immutable snapshot', () {
      final now = DateTime.utc(2026, 7, 27, 12);
      final policy = LocalRetentionPolicy(retentionHours: 100);
      final warnings = policy.warnings(
        nowUtc: now,
        segments: [
          _segment(
            id: 'z-last',
            endedAtUtc: now.subtract(const Duration(hours: 99)),
            status: SegmentUploadStatus.pending,
          ),
          _segment(
            id: 'a-first',
            endedAtUtc: now.subtract(const Duration(hours: 99)),
            status: SegmentUploadStatus.pending,
          ),
        ],
      );

      expect(warnings.map((warning) => warning.segmentId), [
        'a-first',
        'z-last',
      ]);
      expect(() => warnings.clear(), throwsUnsupportedError);
    });

    test('surfaces overdue plaintext as a sweeper health failure', () {
      final now = DateTime.utc(2026, 7, 27, 12);
      final policy = LocalRetentionPolicy(retentionHours: 100);
      final overdue = _segment(
        id: 'overdue',
        endedAtUtc: now.subtract(const Duration(hours: 101)),
        status: SegmentUploadStatus.localOnly,
      );

      final warning = policy.earliestWarning(
        nowUtc: now,
        horizon: Duration.zero,
        segments: [overdue],
      );
      expect(warning, isNotNull);
      expect(warning!.isOverdueAt(now), isTrue);
      expect(policy.overdueCount(nowUtc: now, segments: [overdue]), 1);
      expect(
        warning.deletionMessageAt(now),
        contains('reached its deletion deadline'),
      );
      expect(
        policy.warnings(
          nowUtc: now,
          horizon: Duration.zero,
          includeOverdue: false,
          segments: [overdue],
        ),
        isEmpty,
      );
    });

    test('includes an exact horizon boundary and rejects negative horizons', () {
      final now = DateTime.utc(2026, 7, 27, 12);
      final policy = LocalRetentionPolicy(retentionHours: 100);
      final atBoundary = _segment(
        id: 'boundary',
        endedAtUtc: now.subtract(const Duration(hours: 88)),
        status: SegmentUploadStatus.pending,
      );

      expect(
        policy.warnings(
          nowUtc: now,
          horizon: const Duration(hours: 12),
          segments: [atBoundary],
        ),
        hasLength(1),
      );
      expect(
        () => policy.warnings(
          nowUtc: now,
          horizon: const Duration(seconds: -1),
          segments: [atBoundary],
        ),
        throwsArgumentError,
      );
    });
  });
}

RecordingSegment _segment({
  required String id,
  required DateTime endedAtUtc,
  required SegmentUploadStatus status,
  String? localPath = '/tmp/segment.wav',
  String? remoteKey,
  String? permanentRemoteKey,
  String? error,
}) {
  return RecordingSegment(
    id: id,
    startedAtUtc: endedAtUtc.subtract(const Duration(minutes: 1)),
    endedAtUtc: endedAtUtc,
    byteSize: 1024,
    uploadStatus: status,
    localPath: localPath,
    remoteKey: remoteKey,
    permanentRemoteKey: permanentRemoteKey,
    error: error,
  );
}
