import 'package:audio_dashcam/src/app/app_view_model.dart';
import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_provider.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/models/playback_snapshot.dart';
import 'package:audio_dashcam/src/models/recorder_snapshot.dart';
import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('treats crash-stuck uploading segments as pending work', () {
    final startedAtUtc = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final viewModel = _viewModel(
      segments: [
        RecordingSegment(
          id: 'segment-1',
          startedAtUtc: startedAtUtc,
          endedAtUtc: startedAtUtc.add(const Duration(minutes: 1)),
          byteSize: 4,
          uploadStatus: SegmentUploadStatus.uploading,
          localPath: '/tmp/segment.wav',
        ),
      ],
    );

    expect(viewModel.pendingUploads, 1);
  });

  test('allows non-S3 provider uploads when backend is configured', () {
    final viewModel = _viewModel(
      config: const AppConfig(
        deviceId: 'device-a',
        uploadEnabled: true,
        cloudProvider: CloudProvider.googleDrive,
        backendBaseUrl: 'https://backend.example',
      ),
      secrets: const CloudSecrets(backendDeviceToken: 'device-token'),
    );

    expect(viewModel.canUploadToSelectedProvider, isTrue);
  });

  test(
    'allows permanent save for backend providers when backend is configured',
    () {
      final viewModel = _viewModel(
        config: const AppConfig(
          deviceId: 'device-a',
          cloudProvider: CloudProvider.iCloudDrive,
          backendBaseUrl: 'https://backend.example',
        ),
        secrets: const CloudSecrets(backendDeviceToken: 'device-token'),
      );

      expect(viewModel.canSavePermanently, isTrue);
    },
  );

  test('counts the active recording segment in the local window', () {
    final startedAtUtc = DateTime.now().toUtc().subtract(
      const Duration(seconds: 12),
    );
    final viewModel = _viewModel(
      recorder: RecorderSnapshot(
        isRecording: true,
        isStarting: false,
        activeSegmentStartedAtUtc: startedAtUtc,
      ),
    );

    expect(viewModel.localWindowDuration.inSeconds, greaterThanOrEqualTo(11));
    expect(viewModel.localWindowBytes, greaterThan(0));
  });

  test('tracks permanently saved segment bytes separately', () {
    final startedAtUtc = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final viewModel = _viewModel(
      segments: [
        RecordingSegment(
          id: 'segment-1',
          startedAtUtc: startedAtUtc,
          endedAtUtc: startedAtUtc.add(const Duration(minutes: 1)),
          byteSize: 4,
          uploadStatus: SegmentUploadStatus.localOnly,
          permanentRemoteKey: 'permanent/segment-1.wav',
        ),
      ],
    );

    expect(viewModel.permanentSegmentCount, 1);
    expect(viewModel.permanentBytes, 4);
  });

  test('computes the exact UTC plaintext deadline from segment end time', () {
    final endedAt = DateTime.parse('2026-07-27T18:01:00-04:00');
    final segment = _segment(
      id: 'segment-a',
      endedAtUtc: endedAt,
      status: SegmentUploadStatus.failed,
    );
    final viewModel = _viewModel(
      config: const AppConfig(deviceId: 'device-a', deviceRetentionHours: 100),
      segments: [segment],
    );

    expect(
      viewModel.localPlaintextExpiresAtUtc(segment),
      DateTime.parse('2026-08-01T02:01:00Z'),
    );
  });

  test('returns unbacked local segments expiring inside the warning horizon', () {
    final now = DateTime.utc(2026, 7, 27, 12);
    final viewModel = _viewModel(
      config: const AppConfig(deviceId: 'device-a', deviceRetentionHours: 100),
      segments: [
        _segment(
          id: 'later',
          endedAtUtc: now.subtract(const Duration(hours: 89)),
          status: SegmentUploadStatus.pending,
          error: 'offline',
        ),
        _segment(
          id: 'earlier',
          endedAtUtc: now.subtract(const Duration(hours: 95)),
          status: SegmentUploadStatus.failed,
          error: 'upload failed',
        ),
        _segment(
          id: 'outside-horizon',
          endedAtUtc: now.subtract(const Duration(hours: 80)),
          status: SegmentUploadStatus.pending,
        ),
      ],
    );

    final warnings = viewModel.localRetentionWarnings(
      nowUtc: now,
      horizon: const Duration(hours: 12),
    );

    expect(warnings.map((warning) => warning.segmentId), ['earlier', 'later']);
    expect(warnings.first.expiresAtUtc, now.add(const Duration(hours: 5)));
    expect(warnings.first.lastError, 'upload failed');
    expect(
      warnings.first.deletionMessageAt(now),
      'Backup has not completed. The local copy will be deleted at 2026-07-27T17:00:00.000Z.',
    );
  });

  test('excludes uploaded, permanently saved, and non-local segments', () {
    final now = DateTime.utc(2026, 7, 27, 12);
    final endedAt = now.subtract(const Duration(hours: 99));
    final viewModel = _viewModel(
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
    );

    expect(
      viewModel.localRetentionWarnings(
        nowUtc: now,
        horizon: const Duration(hours: 12),
      ),
      isEmpty,
    );
  });

  test('surfaces overdue local plaintext as a sweeper health failure', () {
    final now = DateTime.utc(2026, 7, 27, 12);
    final viewModel = _viewModel(
      segments: [
        _segment(
          id: 'overdue',
          endedAtUtc: now.subtract(const Duration(hours: 101)),
          status: SegmentUploadStatus.localOnly,
        ),
      ],
    );

    final warning = viewModel.earliestLocalRetentionWarning(
      nowUtc: now,
      horizon: Duration.zero,
    );
    expect(warning, isNotNull);
    expect(warning!.isOverdueAt(now), isTrue);
    expect(viewModel.overdueLocalRetentionCount(now), 1);
    expect(
      warning.deletionMessageAt(now),
      contains('reached its deletion deadline'),
    );

    expect(
      viewModel.localRetentionWarnings(
        nowUtc: now,
        horizon: Duration.zero,
        includeOverdue: false,
      ),
      isEmpty,
    );
  });

  test('rejects a negative retention-warning horizon', () {
    final viewModel = _viewModel();
    expect(
      () => viewModel.localRetentionWarnings(
        nowUtc: DateTime.utc(2026, 7, 27),
        horizon: const Duration(seconds: -1),
      ),
      throwsArgumentError,
    );
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

AppViewModel _viewModel({
  AppConfig config = const AppConfig(deviceId: 'device-a'),
  CloudSecrets secrets = const CloudSecrets(),
  List<RecordingSegment> segments = const [],
  RecorderSnapshot recorder = const RecorderSnapshot.idle(),
}) {
  return AppViewModel(
    config: config,
    secrets: secrets,
    segments: segments,
    recorder: recorder,
    playback: const PlaybackSnapshot.empty(),
    diagnosticEntries: const [],
    isInitializing: false,
    isUploading: false,
  );
}
