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

  test('treats AAL1 as a pending first factor, not a signed-in account', () {
    const header = 'eyJhbGciOiJub25lIn0';
    const aal1 = '$header.eyJhYWwiOiJhYWwxIn0.signature';
    const aal2 =
        '$header.eyJhYWwiOiJhYWwyIiwiYW1yIjpbeyJtZXRob2QiOiJvdHAifSx7Im1ldGhvZCI6InRvdHAifV19.signature';

    final pending = _viewModel(
      secrets: const CloudSecrets(supabaseAccessToken: aal1),
    );
    final authorized = _viewModel(
      secrets: const CloudSecrets(
        supabaseAccessToken: aal2,
        supabaseAccessTokenExpiresAt: '2099-01-01T00:00:00Z',
      ),
    );

    expect(pending.hasFirstFactorSession, isTrue);
    expect(pending.isSignedIn, isFalse);
    expect(authorized.isSignedIn, isTrue);
  });
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
