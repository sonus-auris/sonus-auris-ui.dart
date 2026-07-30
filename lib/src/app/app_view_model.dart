// Immutable snapshot of everything the UI renders (config, secrets, segments, recorder/playback state, detections), emitted by the AppController.
import '../models/acoustic_detection.dart';
import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import '../models/context_trigger.dart';
import '../models/cloud_provider.dart';
import '../models/local_retention_warning.dart';
import '../models/playback_snapshot.dart';
import '../models/recorder_snapshot.dart';
import '../models/recording_segment.dart';
import '../models/storage_estimate.dart';
import '../models/supabase_session.dart';
import '../models/transfer_gate_status.dart';
import '../retention/local_retention_policy.dart';

class AppViewModel {
  const AppViewModel({
    required this.config,
    required this.secrets,
    required this.segments,
    required this.recorder,
    required this.playback,
    required this.diagnosticEntries,
    required this.isInitializing,
    required this.isUploading,
    this.isStarting = false,
    this.transferStatus = const TransferGateStatus.unknown(),
    this.message,
    this.detections = const [],
    this.consentRequest,
  });

  final AppConfig config;
  final CloudSecrets secrets;
  final List<RecordingSegment> segments;
  final RecorderSnapshot recorder;
  final PlaybackSnapshot playback;
  final List<String> diagnosticEntries;
  final bool isInitializing;
  final bool isUploading;

  /// True from the moment "Start" is tapped until capture is live (or fails) —
  /// covers the wait while the OS permission prompts load, so the button can show
  /// a spinner instead of looking frozen.
  final bool isStarting;

  /// Most recent acoustic-intelligence detections, newest first.
  final List<AcousticDetection> detections;

  /// Current power/network gate decision. When [TransferGateStatus.isPaused] is
  /// true, cloud uploads are deferred (local capture continues).
  final TransferGateStatus transferStatus;
  final String? message;

  /// A pending request to start recording, raised when a context trigger fired
  /// inside an active schedule window while idle. The Home view surfaces this as
  /// an explicit "Start recording? / Not now" consent banner.
  final ConsentRequest? consentRequest;

  /// True when uploads are configured but currently held back by the battery /
  /// network gate (as opposed to simply having nothing to upload).
  bool get isUploadGatePaused =>
      config.uploadEnabled && transferStatus.isPaused && pendingUploads > 0;

  /// Whether cloud account access is authorized: the passwordless first factor
  /// plus a verified second factor represented by an `aal2` access token.
  bool get isSignedIn =>
      secrets.hasFreshSupabaseToken() &&
      supabaseJwtIsPasswordlessAal2(secrets.supabaseAccessToken);

  /// A first-factor session may exist while mandatory MFA is being enrolled or
  /// challenged. It must not be treated as signed in.
  bool get hasFirstFactorSession => secrets.hasSupabaseSession;

  /// Email of the signed-in user, or null when signed out / unknown.
  String? get signedInEmail => secrets.supabaseEmail.trim().isEmpty
      ? null
      : secrets.supabaseEmail.trim();

  /// True once the device holds a backend device token issued after sign-in.
  bool get isDeviceRegistered => secrets.hasBackendDeviceToken;

  /// Signed in and configured for the backend, but not yet registered — the
  /// controller will register on the next backend interaction.
  bool get isAwaitingDeviceRegistration =>
      isSignedIn &&
      config.backendBaseUrl.trim().isNotEmpty &&
      !isDeviceRegistered;

  bool get hasSupabaseAuthConfig => config.hasSupabaseAuthConfig;

  StorageEstimate get estimate => StorageEstimate(
    bitRate: config.effectiveBitRate,
    deviceHours: config.deviceRetentionHours,
    cloudHours: config.cloudRetentionHours,
  );

  List<RecordingSegment> get localSegments =>
      segments.where((segment) => segment.isLocal).toList();

  int get localBytes =>
      localSegments.fold(0, (total, segment) => total + segment.byteSize);

  Duration get activeRecordingDuration {
    if (!recorder.isRecording) {
      return Duration.zero;
    }
    final duration = recorder.activeDuration(DateTime.now().toUtc());
    if (duration == null || duration.isNegative) {
      return Duration.zero;
    }
    return duration;
  }

  int get activeRecordingBytes {
    if (activeRecordingDuration <= Duration.zero) {
      return 0;
    }
    return estimate.bytesPerSecond * activeRecordingDuration.inSeconds;
  }

  int get localWindowBytes => localBytes + activeRecordingBytes;

  int get cloudBytes => segments
      .where((segment) => segment.isUploaded)
      .fold(0, (total, segment) => total + segment.byteSize);

  int get permanentSegmentCount =>
      segments.where((segment) => segment.isPermanentlySaved).length;

  int get permanentBytes => segments
      .where((segment) => segment.isPermanentlySaved)
      .fold(0, (total, segment) => total + segment.byteSize);

  int get pendingUploads => segments
      .where(
        (segment) =>
            segment.uploadStatus == SegmentUploadStatus.pending ||
            segment.uploadStatus == SegmentUploadStatus.uploading ||
            segment.uploadStatus == SegmentUploadStatus.failed,
      )
      .length;

  int get failedUploads => segments
      .where((segment) => segment.uploadStatus == SegmentUploadStatus.failed)
      .length;

  /// Safe retention policy for UI projection. Older persisted values above the
  /// current product ceiling are reduced to 100 hours rather than allowing a
  /// stale configuration to extend plaintext lifetime or crash the dashboard.
  LocalRetentionPolicy get localRetentionPolicy => LocalRetentionPolicy(
    retentionHours: config.deviceRetentionHours
        .clamp(1, LocalRetentionPolicy.maxPlaintextRetentionHours)
        .toInt(),
  );

  List<LocalRetentionWarning> localRetentionWarnings({
    required DateTime nowUtc,
    Duration? horizon,
    bool includeOverdue = true,
  }) => localRetentionPolicy.warnings(
    segments: segments,
    nowUtc: nowUtc,
    horizon: horizon,
    includeOverdue: includeOverdue,
  );

  LocalRetentionWarning? earliestLocalRetentionWarning({
    required DateTime nowUtc,
    Duration? horizon,
    bool includeOverdue = true,
  }) => localRetentionPolicy.earliestWarning(
    segments: segments,
    nowUtc: nowUtc,
    horizon: horizon,
    includeOverdue: includeOverdue,
  );

  int overdueLocalRetentionCount(DateTime nowUtc) =>
      localRetentionPolicy.overdueCount(segments: segments, nowUtc: nowUtc);

  int get uploadedSegments =>
      segments.where((segment) => segment.isUploaded).length;

  Duration get indexedDuration {
    return segments.fold(
      Duration.zero,
      (total, segment) => total + segment.canonicalDuration,
    );
  }

  Duration get localWindowDuration => indexedDuration + activeRecordingDuration;

  int get continuityGapCount {
    final bySession = <String, List<RecordingSegment>>{};
    for (final segment in segments.where(
      (segment) => segment.hasSampleTimeline,
    )) {
      bySession.putIfAbsent(segment.captureSessionId, () => []).add(segment);
    }
    var gaps = 0;
    for (final sessionSegments in bySession.values) {
      sessionSegments.sort((a, b) => a.sequence.compareTo(b.sequence));
      for (var index = 1; index < sessionSegments.length; index += 1) {
        final previous = sessionSegments[index - 1];
        final current = sessionSegments[index];
        if (previous.endSampleExclusive != current.startSample) {
          gaps += 1;
        }
      }
    }
    return gaps;
  }

  int get overlappedSegments =>
      segments.where((segment) => segment.overlapSamples > 0).length;

  bool get canUploadToSelectedProvider {
    if (!config.uploadEnabled || !config.cloudProvider.isImplemented) {
      return false;
    }
    if (config.backendBaseUrl.trim().isNotEmpty &&
        secrets.hasBackendDeviceToken) {
      return true;
    }
    return config.cloudProvider == CloudProvider.s3 &&
        config.s3TargetReady &&
        secrets.hasS3Credentials;
  }

  bool get canSavePermanently {
    if (!config.cloudProvider.isImplemented) {
      return false;
    }
    if (config.backendBaseUrl.trim().isNotEmpty &&
        secrets.hasBackendDeviceToken) {
      return true;
    }
    return config.cloudProvider == CloudProvider.s3 &&
        config.s3TargetReady &&
        secrets.hasS3Credentials;
  }
}
