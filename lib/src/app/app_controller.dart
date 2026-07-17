// Central app orchestrator: owns every service and drives the capture/encrypt/upload/analysis lifecycle, exposing app state to the UI.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show FlutterErrorDetails, ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';

import '../models/acoustic_detection.dart';
import '../models/audio_trigger_event.dart';
import '../models/app_config.dart';
import '../models/client_telemetry_event.dart';
import '../models/cloud_provider.dart';
import '../models/context_trigger.dart';
import '../models/cloud_secrets.dart';
import '../models/consent.dart';
import '../models/playback_snapshot.dart';
import '../models/recorder_snapshot.dart';
import '../models/cloud_connection.dart';
import '../models/recording_schedule.dart';
import '../models/recording_segment.dart';
import '../models/sleep_cycle_profile.dart';
import '../models/supabase_session.dart';
import '../models/transfer_gate_status.dart';
import '../services/background_capture_service.dart';
import '../services/crypto/flutter_secure_key_store.dart';
import '../services/crypto/key_manager.dart';
import '../services/crypto/segment_encryptor.dart';
import '../services/icloud_sync_service.dart';
import '../services/location_service.dart';
import '../services/diagnostic_log.dart';
import '../services/context_trigger_service.dart';
import '../services/context_trigger_sources.dart';
import '../services/local_notifications_service.dart';
import '../services/playback_service.dart';
import '../services/power_network_gate.dart';
import '../services/recording_feedback.dart';
import '../services/recording_scheduler.dart';
import '../services/recording_schedule_platform.dart';
import '../services/spectral_sidecar.dart';
import '../services/s3_storage_client.dart';
import '../services/segment_index.dart';
import '../services/segment_recorder.dart';
import '../services/settings_store.dart';
import '../services/sleep_sensor_service.dart';
import '../services/sleep_signal_model.dart';
import '../services/shazam_client.dart';
import '../services/memory_publisher.dart';
import '../services/day_of_life_archiver.dart';
import '../services/music_oauth_service.dart';
import '../services/oauth_browser.dart';
import '../services/sound_recorder_backend_client.dart';
import '../services/speech_to_text_client.dart';
import '../services/on_device_speech_client.dart';
import '../services/supabase_auth_client.dart';
import '../services/supabase_rest_client.dart';
import 'app_view_model.dart';

/// Consent string recorded against the device on registration. Bump when the
/// recording/privacy disclosure shown to the user materially changes. Bumping
/// this also re-triggers the onboarding consent flow.
const String kConsentVersion = 'audio-dashcam-consent-v1';

/// App-level Supabase project, injected at build time so the onboarding
/// login/sign-up works out of the box:
/// `--dart-define=SONUS_SUPABASE_URL=…`
/// `--dart-define=SONUS_SUPABASE_ANON_KEY=…`.
/// Both are public client values (the anon key is safe to embed); the
/// service_role key must never reach the device. When unset, the user can still
/// configure their own Supabase project in the Configure tab.
const String kDefaultSupabaseUrl = AppConfig.defaultSupabaseUrl;
const String kDefaultSupabaseAnonKey = AppConfig.defaultSupabaseAnonKey;

class AppController {
  factory AppController({
    SettingsStore? settingsStore,
    SegmentIndex? segmentIndex,
    SegmentRecorder? recorder,
    PlaybackService? playback,
    BackgroundCaptureService? backgroundCaptureService,
    S3StorageClient? s3StorageClient,
    SoundRecorderBackendClient? backendClient,
    SupabaseAuthClient? authClient,
    IcloudSyncService? icloudSyncService,
    DiagnosticLog? diagnosticLog,
    RecordingFeedback? feedback,
    LocationService? locationService,
    PowerNetworkGate? powerNetworkGate,
    SupabaseRestClient? supabaseRestClient,
    ShazamClient? shazamClient,
    MemoryPublisher? memoryPublisher,
    DayOfLifeArchiver? dayOfLifeArchiver,
    MusicOAuthService? musicOAuthService,
    OAuthBrowser? oauthBrowser,
    SpeechToTextClient? speechToTextClient,
    OnDeviceSpeechClient? onDeviceSpeechClient,
    SleepSensorService? sleepSensorService,
    RecordingScheduler? recordingScheduler,
    LocalNotificationsService? localNotifications,
    ContextTriggerService? contextTriggerService,
  }) {
    final effectiveSegmentIndex = segmentIndex ?? SegmentIndex();
    final effectiveDiagnostics = diagnosticLog ?? DiagnosticLog();
    // One notifications instance for both schedule reminders and consent prompts
    // so there is a single tap-response handler.
    final notifications =
        localNotifications ??
        LocalNotificationsService(diagnostics: effectiveDiagnostics);
    // One device-bound encryptor shared by every cloud path, so audio is sealed
    // on-device before upload and only ever opened locally. The master key lives
    // in the Keychain/Keystore via FlutterSecureKeyStore.
    final encryptor = SegmentEncryptor(
      keyManager: KeyManager(store: FlutterSecureKeyStore()),
    );
    return AppController._(
      settingsStore: settingsStore ?? SettingsStore(),
      segmentIndex: effectiveSegmentIndex,
      recorder:
          recorder ?? SegmentRecorder(segmentIndex: effectiveSegmentIndex),
      playback: playback ?? PlaybackService(),
      backgroundCaptureService:
          backgroundCaptureService ??
          BackgroundCaptureService(diagnostics: effectiveDiagnostics),
      s3StorageClient: s3StorageClient ?? S3StorageClient(encryptor: encryptor),
      backendClient:
          backendClient ?? SoundRecorderBackendClient(encryptor: encryptor),
      authClient: authClient ?? SupabaseAuthClient(),
      icloudSyncService:
          icloudSyncService ?? IcloudSyncService(encryptor: encryptor),
      diagnostics: effectiveDiagnostics,
      feedback: feedback ?? RecordingFeedback(),
      locationService: locationService ?? LocationService(),
      powerNetworkGate: powerNetworkGate ?? PowerNetworkGate(),
      supabaseRestClient: supabaseRestClient ?? SupabaseRestClient(),
      shazamClient: shazamClient ?? ShazamClient(),
      memoryPublisher: memoryPublisher ?? MemoryPublisher(),
      dayOfLifeArchiver: dayOfLifeArchiver ?? DayOfLifeArchiver(),
      musicOAuthService: musicOAuthService ?? MusicOAuthService(),
      oauthBrowser: oauthBrowser ?? const FlutterWebAuthBrowser(),
      speechToTextClient: speechToTextClient ?? SpeechToTextClient(),
      onDeviceSpeechClient: onDeviceSpeechClient ?? OnDeviceSpeechClient(),
      sleepSensorService: sleepSensorService ?? SleepSensorService(),
      scheduler:
          recordingScheduler ??
          RecordingScheduler(
            diagnostics: effectiveDiagnostics,
            platform: PluginSchedulePlatform(
              notifications: notifications,
              diagnostics: effectiveDiagnostics,
            ),
          ),
      localNotifications: notifications,
      contextTriggers:
          contextTriggerService ??
          ContextTriggerService(
            sources: defaultContextTriggerSources(),
            diagnostics: effectiveDiagnostics,
          ),
    );
  }

  AppController._({
    required this._settingsStore,
    required this._segmentIndex,
    required this._recorder,
    required this._playback,
    required this._backgroundCaptureService,
    required this._s3StorageClient,
    required this._backendClient,
    required this._authClient,
    required this._icloudSyncService,
    required this._diagnostics,
    required this._feedback,
    required this._locationService,
    required this._powerNetworkGate,
    required this._supabaseRestClient,
    required this._shazamClient,
    required this._memoryPublisher,
    required this._dayOfLifeArchiver,
    required this._musicOAuthService,
    required this._oauthBrowser,
    required this._speechToTextClient,
    required this._onDeviceSpeechClient,
    required this._sleepSensorService,
    required this._scheduler,
    required this._localNotifications,
    required this._contextTriggers,
  }) {
    _scheduler.onTransition = _onScheduleTransition;
    _contextTriggers.onTrigger = _onContextTrigger;
    _localNotifications.onConsentTap = acceptContextConsent;
    // Pre-combine the upload flag and transfer-gate status into one record so
    // both ride a single slot of the (max-arity-9) combineLatest below.
    final uploadStatus =
        Rx.combineLatest2<
          bool,
          TransferGateStatus,
          ({bool isUploading, TransferGateStatus transfer})
        >(
          _isUploading,
          _transfer,
          (isUploading, transfer) =>
              (isUploading: isUploading, transfer: transfer),
        );
    // Fold the message, detections list, and consent request into one slot
    // (combineLatest is at its max arity of 9 below).
    final messageAndDetections =
        Rx.combineLatest3<
          String?,
          List<AcousticDetection>,
          ConsentRequest?,
          ({
            String? message,
            List<AcousticDetection> detections,
            ConsentRequest? consentRequest,
          })
        >(
          _message,
          _detectionsList,
          _consentRequest,
          (message, detections, consentRequest) => (
            message: message,
            detections: detections,
            consentRequest: consentRequest,
          ),
        );
    // Fold the init + starting flags into one slot (combineLatest is at its max
    // arity of 9 below).
    final lifecycle =
        Rx.combineLatest2<bool, bool, ({bool isInitializing, bool isStarting})>(
          _isInitializing,
          _isStarting,
          (isInitializing, isStarting) =>
              (isInitializing: isInitializing, isStarting: isStarting),
        );
    _viewModels =
        Rx.combineLatest9<
              AppConfig,
              CloudSecrets,
              List<RecordingSegment>,
              RecorderSnapshot,
              PlaybackSnapshot,
              List<String>,
              ({bool isInitializing, bool isStarting}),
              ({bool isUploading, TransferGateStatus transfer}),
              ({
                String? message,
                List<AcousticDetection> detections,
                ConsentRequest? consentRequest,
              }),
              AppViewModel
            >(
              _config,
              _secrets,
              _segments,
              _recorder.snapshots,
              _playback.snapshots,
              _diagnostics.entries,
              lifecycle,
              uploadStatus,
              messageAndDetections,
              (
                config,
                secrets,
                segments,
                recorder,
                playback,
                diagnosticEntries,
                lifecycleState,
                uploadState,
                messageState,
              ) {
                return AppViewModel(
                  config: config,
                  secrets: secrets,
                  segments: segments,
                  recorder: recorder,
                  playback: playback,
                  diagnosticEntries: diagnosticEntries,
                  isInitializing: lifecycleState.isInitializing,
                  isStarting: lifecycleState.isStarting,
                  isUploading: uploadState.isUploading,
                  transferStatus: uploadState.transfer,
                  message: messageState.message,
                  detections: messageState.detections,
                  consentRequest: messageState.consentRequest,
                );
              },
            )
            .shareReplay(maxSize: 1);
  }

  final SettingsStore _settingsStore;
  final SegmentIndex _segmentIndex;
  final SegmentRecorder _recorder;
  final PlaybackService _playback;
  final BackgroundCaptureService _backgroundCaptureService;
  final S3StorageClient _s3StorageClient;
  final SoundRecorderBackendClient _backendClient;
  final SupabaseAuthClient _authClient;
  final IcloudSyncService _icloudSyncService;
  final DiagnosticLog _diagnostics;
  final RecordingFeedback _feedback;
  final LocationService _locationService;
  final PowerNetworkGate _powerNetworkGate;
  final SupabaseRestClient _supabaseRestClient;

  /// The onboarding consent the user accepted (null until first onboarding).
  ConsentRecord? _consentRecord;
  ConsentRecord? get consentRecord => _consentRecord;

  final ValueNotifier<bool> _onboardingComplete = ValueNotifier<bool>(false);

  /// Whether onboarding (consent for the current [kConsentVersion]) is done.
  /// The app root watches this to gate the onboarding flow vs. the main UI.
  ValueListenable<bool> get onboardingComplete => _onboardingComplete;
  final ShazamClient _shazamClient;
  final MemoryPublisher _memoryPublisher;
  final DayOfLifeArchiver _dayOfLifeArchiver;
  final MusicOAuthService _musicOAuthService;
  final OAuthBrowser _oauthBrowser;
  DateTime? _lastSeenLocalDay;
  DateTime? _lastArchivedDay;
  bool _archiveCaughtUp = false;
  final SpeechToTextClient _speechToTextClient;
  final OnDeviceSpeechClient _onDeviceSpeechClient;
  final SleepSensorService _sleepSensorService;
  final RecordingScheduler _scheduler;
  final LocalNotificationsService _localNotifications;
  final ContextTriggerService _contextTriggers;

  /// True when the *current* recording session was started by the schedule (not
  /// by the user). A schedule-driven stop only stops a schedule-started session,
  /// so it never kills a recording the user began manually — and vice-versa.
  bool _scheduleStartedRecording = false;

  /// When the last context-trigger consent prompt was raised, to honor the
  /// per-event cooldown so a flurry of events doesn't nag repeatedly.
  DateTime? _lastConsentPromptAt;
  Future<void>? _deviceRegistrationInFlight;
  Future<void>? _supabaseRefreshInFlight;
  Future<void>? _icloudSyncInFlight;
  StreamSubscription<void>? _transferConditionsSubscription;
  String? _lastReportedTransferSignature;
  DateTime? _lastTransferReportAt;
  SleepCycleProfile _sleepCycleProfile = const SleepCycleProfile();
  static const SleepProbabilityModel _sleepProbabilityModel =
      SleepProbabilityModel();

  /// While paused, the device re-affirms its state to the backend at least this
  /// often so the server-side pause lease (which the cloud-copy drain honors)
  /// stays fresh. Must be comfortably shorter than the backend lease window.
  static const Duration _transferReaffirmInterval = Duration(minutes: 5);

  final BehaviorSubject<AppConfig> _config = BehaviorSubject();
  final BehaviorSubject<CloudSecrets> _secrets = BehaviorSubject();
  final BehaviorSubject<List<RecordingSegment>> _segments =
      BehaviorSubject.seeded(const []);
  final BehaviorSubject<bool> _isInitializing = BehaviorSubject.seeded(true);

  /// True while [startRecording] is in flight (permission prompts loading, mic
  /// stream opening) so the UI can show a spinner instead of a frozen button.
  final BehaviorSubject<bool> _isStarting = BehaviorSubject.seeded(false);
  final BehaviorSubject<bool> _isUploading = BehaviorSubject.seeded(false);
  final BehaviorSubject<TransferGateStatus> _transfer = BehaviorSubject.seeded(
    const TransferGateStatus.unknown(),
  );
  final BehaviorSubject<String?> _message = BehaviorSubject.seeded(null);
  final BehaviorSubject<List<AcousticDetection>> _detectionsList =
      BehaviorSubject.seeded(const []);
  final BehaviorSubject<ConsentRequest?> _consentRequest =
      BehaviorSubject.seeded(null);
  final PublishSubject<void> _uploadRequests = PublishSubject();

  /// Newest-first rolling window of acoustic detections kept for the UI.
  static const int _maxDetectionsKept = 100;

  late final Stream<AppViewModel> _viewModels;
  StreamSubscription<void>? _closedSegmentsSubscription;
  StreamSubscription<dynamic>? _triggerSubscription;
  StreamSubscription<dynamic>? _detectionsSubscription;
  StreamSubscription<dynamic>? _uploadSubscription;
  StreamSubscription<String>? _resumeRequestsSubscription;
  StreamSubscription<DiagnosticEntry>? _diagnosticTelemetrySubscription;

  // Auto-resume state. [_intendRecording] is the user/schedule intent (true
  // between a successful start and the next stop), independent of whether the
  // mic stream is momentarily down. The rest rate-limit auto-restarts so a
  // device that genuinely cannot record does not spin.
  bool _intendRecording = false;
  bool _autoResuming = false;
  final List<DateTime> _recentAutoResumes = [];
  static const int _maxAutoResumesPerMinute = 4;
  BackendUploadSession? _backendSession;
  String? _backendSessionKey;
  final List<AudioTriggerEvent> _pendingAlertEvents = [];
  final List<ClientTelemetryEvent> _pendingTelemetry = [];
  Timer? _telemetryFlushTimer;
  bool _telemetryFlushInFlight = false;
  static const int _maxPendingTelemetry = 100;
  static const int _telemetryBatchSize = 20;

  /// Writes the time-aligned FFT feature sidecar next to each finalized segment.
  final SpectralSidecar _spectralSidecar = SpectralSidecar();

  Stream<AppViewModel> get viewModels => _viewModels;

  Future<void> init() async {
    _diagnostics.add('App controller init started.');
    _diagnosticTelemetrySubscription = _diagnostics.events.listen(
      _queueDiagnosticTelemetry,
      onError: (_) {},
    );
    _backgroundCaptureService.init();
    final loadedConfig = await _settingsStore.loadConfig();
    _sleepCycleProfile = (await _settingsStore.loadSleepCycleProfile()).pruned(
      DateTime.now().toUtc(),
    );
    final sleepCycleSeeds = _sleepCycleProfile.observations.isEmpty
        ? loadedConfig.sleepCycleMinutesByIndex
        : _sleepCycleProfile.cycleMinuteSeeds();
    final config = _seedSupabaseDefaults(
      loadedConfig.copyWith(sleepCycleMinutesByIndex: sleepCycleSeeds),
    );
    // Persist if build-time Supabase defaults filled in previously-empty fields.
    if (config.supabaseUrl != loadedConfig.supabaseUrl ||
        config.supabaseAnonKey != loadedConfig.supabaseAnonKey) {
      await _settingsStore.saveConfig(config);
    }
    _consentRecord = await _settingsStore.loadConsentRecord();
    _onboardingComplete.value = _hasValidConsent(_consentRecord);
    final secrets = await _settingsStore.loadSecrets();
    final pendingAlerts = await _settingsStore.loadPendingAlerts();
    final recovered = await _segmentIndex.recoverOrphanedLocalSegments(
      fallbackSegmentMinutes: config.segmentMinutes,
    );
    _pendingAlertEvents
      ..clear()
      ..addAll(pendingAlerts);
    _feedback.enabled = config.verbalCuesEnabled;
    _config.add(config);
    _secrets.add(secrets);
    _segments.add(recovered);
    _closedSegmentsSubscription = _recorder.closedSegments
        .asyncMap(_onSegmentClosed)
        .listen(
          (_) {},
          onError: (Object error) {
            _message.add('Failed to index a closed segment: $error');
          },
        );
    _triggerSubscription = _recorder.triggerEvents
        .asyncMap((event) => _sendAlertForEvent(event))
        .listen(
          (_) {},
          onError: (Object error) {
            _message.add('Audio alert failed: $error');
          },
        );
    // Handle detections without back-pressuring the (broadcast) source: a slow
    // Shazam/STT enrichment must not pause the stream and drop later detections.
    // _onDetection is self-contained and swallows its own errors.
    _detectionsSubscription = _recorder.detections.listen(
      (detection) => unawaited(_onDetection(detection)),
      onError: (Object error) {
        _diagnostics.add('Acoustic detection stream error: $error');
      },
    );
    // Auto-resume: restart capture when the recorder reports an interruption or
    // stall it could not recover from on its own (keeps overnight capture alive
    // across calls, alarms, Siri, media-services resets).
    _resumeRequestsSubscription = _recorder.resumeRequests.listen(
      (reason) => unawaited(_handleAutoResume(reason)),
      onError: (Object error) {
        _diagnostics.add('Auto-resume stream error: $error');
      },
    );
    _uploadSubscription = _uploadRequests
        .debounceTime(const Duration(milliseconds: 250))
        .exhaustMap((_) => Stream.fromFuture(_drainUploads()))
        .listen(
          (_) {},
          onError: (Object error) {
            _message.add('Upload queue failed: $error');
            _isUploading.add(false);
          },
        );
    // React to battery / connectivity changes: re-trigger the upload queue so
    // deferred segments catch up the moment conditions allow it again, and keep
    // the surfaced status fresh.
    _transferConditionsSubscription = _powerNetworkGate.changes.listen(
      (_) => unawaited(_onTransferConditionsChanged()),
      onError: (Object error) {
        _diagnostics.add('Transfer condition watch failed: $error');
      },
    );
    await _refreshTransferStatus();
    _isInitializing.add(false);
    _diagnostics.add('App controller init completed.');
    await _ensureSupabaseReady();
    await _syncPortableSettingsFromSupabase();
    _scheduleTelemetryFlush();
    // If consent was captured before sign-in (or a previous sync failed), push it
    // now that a session may be available.
    await _maybeSyncConsent();
    requestUploadDrain();
    await _enforceRetention();
    // "Always-on": if the user enabled auto-start and no weekly schedule is
    // taking over consent windows, begin capturing on launch (including the
    // boot-triggered relaunch) without them pressing Start.
    if (!config.recordingSchedule.hasAnyWindows &&
        config.autoStartCaptureEnabled &&
        !_recorder.isRecording) {
      _diagnostics.add('Auto-start capture is enabled; starting recording.');
      await startRecording();
    }
    await _localNotifications.ensureInitialized();
    final launchedFromConsent = await _localNotifications.launchedFromConsent();
    // Register OS alarms/notifications for the recording schedule and reconcile
    // current capture against the schedule. On iOS this can continue through
    // lock/background once a real recording session is active; local
    // notifications remain reminders/relaunch affordances, not the only start
    // path.
    await _scheduler.sync(config.recordingSchedule);
    final pendingScheduleCommand = await _scheduler.drainPendingShouldRecord();
    if (pendingScheduleCommand != null) {
      _diagnostics.add(
        'Drained pending schedule command: '
        '${pendingScheduleCommand ? "start" : "stop"}.',
      );
    }
    await _syncScheduleForegroundService(config.recordingSchedule);
    await _reconcileWithSchedule(config.recordingSchedule);
    // Arm context triggers and honor a consent notification the user may have
    // tapped to launch the app.
    await _updateContextTriggers();
    if (launchedFromConsent) {
      _diagnostics.add('Launched from a consent notification.');
      acceptContextConsent();
    }
  }

  /// Called by [_scheduler] when an in-app timer reaches a window barrier.
  void _onScheduleTransition(bool _) {
    final config = _config.valueOrNull;
    if (config == null || !config.recordingSchedule.enabled) {
      return;
    }
    // The timer's captured transition may have raced a settings edit. Re-read
    // the authoritative current schedule and wall clock before changing capture.
    unawaited(_reconcileWithSchedule(config.recordingSchedule));
  }

  /// Brings capture in line with what the schedule says should be happening
  /// right now, without disturbing a session the user controls manually.
  Future<void> _reconcileWithSchedule(RecordingSchedule schedule) async {
    if (!schedule.enabled) {
      return;
    }
    await _applyScheduleState(schedule.isActiveAt(DateTime.now()));
  }

  Future<void> _applyScheduleState(bool shouldRecord) async {
    if (shouldRecord) {
      if (!_recorder.isRecording) {
        _diagnostics.add('Schedule window active; starting recording.');
        await startRecording(scheduleInitiated: true);
      }
    } else {
      // Only stop a session the schedule itself started — never a manual one.
      if (_recorder.isRecording && _scheduleStartedRecording) {
        _diagnostics.add('Schedule window ended; stopping recording.');
        await stopRecording();
        _scheduleStartedRecording = false;
      }
      await _syncScheduleForegroundService(_config.value.recordingSchedule);
    }
    // The window/recording state just changed — re-arm context sources to match
    // (they run only inside an active window while idle).
    await _updateContextTriggers();
  }

  // --- Context triggers: wake & ask for consent on meaningful events --------

  /// Reconcile which context-trigger sensors run against the current config and
  /// schedule state. Sources run only while context triggers are enabled, the
  /// schedule is in an active window, and capture is idle (so BLE scanning etc.
  /// never runs needlessly).
  Future<void> _updateContextTriggers() async {
    final config = _config.valueOrNull;
    if (config == null) {
      return;
    }
    final schedule = config.recordingSchedule;
    final active =
        schedule.enabled &&
        schedule.isActiveAt(DateTime.now()) &&
        !_recorder.isRecording;
    await _contextTriggers.update(
      enabled: config.contextTriggersEnabled,
      kinds: config.contextTriggerKindSet,
      active: active,
    );
  }

  /// A context source fired. Raise a consent request only when armed, inside an
  /// active schedule window, idle, and past the cooldown.
  void _onContextTrigger(ContextTriggerEvent event) {
    final config = _config.valueOrNull;
    if (config == null || !config.contextTriggersEnabled) {
      return;
    }
    final schedule = config.recordingSchedule;
    if (!schedule.enabled || !schedule.isActiveAt(DateTime.now())) {
      return; // only ask inside a scheduled window
    }
    if (_recorder.isRecording) {
      return; // only ask when not already recording
    }
    if (_consentRequest.valueOrNull != null) {
      return; // a consent request is already awaiting the user's answer
    }
    final now = DateTime.now();
    final last = _lastConsentPromptAt;
    if (last != null &&
        now.difference(last).inSeconds < config.contextTriggerCooldownSeconds) {
      return; // honor the cooldown so a burst of events doesn't nag
    }
    _lastConsentPromptAt = now;
    _diagnostics.add('Context trigger consent prompt: ${event.description}');
    if (_isForeground) {
      // Surface an in-app "Start recording?" banner the user explicitly accepts.
      _consentRequest.add(ConsentRequest(event: event));
    } else {
      // Backgrounded but alive — ask via a tappable notification (the tap is the
      // consent). Killed-app events can't be observed, so nothing fires then.
      unawaited(_localNotifications.showConsentPrompt(event));
    }
  }

  bool get _isForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Accept a pending recording-consent request (in-app banner "Start" or a
  /// tapped notification): start recording if the gate still holds.
  void acceptContextConsent() {
    _consentRequest.add(null);
    unawaited(_localNotifications.clearConsentPrompt());
    final config = _config.valueOrNull;
    if (config == null || _recorder.isRecording) {
      return;
    }
    final schedule = config.recordingSchedule;
    if (!schedule.enabled || !schedule.isActiveAt(DateTime.now())) {
      return; // window closed before the user responded
    }
    _diagnostics.add('Recording consent accepted; starting recording.');
    unawaited(startRecording(scheduleInitiated: true));
  }

  /// Dismiss the pending consent request without recording ("Not now").
  void dismissContextConsent() {
    _consentRequest.add(null);
    unawaited(_localNotifications.clearConsentPrompt());
  }

  Future<void> _onTransferConditionsChanged() async {
    final status = await _refreshTransferStatus();
    if (status.allowed) {
      // Conditions recovered — drain pending uploads and mirror to iCloud.
      requestUploadDrain();
      unawaited(syncIcloudBackups());
    }
  }

  /// Evaluates the current power/network gate against config, publishes the
  /// status for the UI, and reports transitions to the backend so server-managed
  /// copies stay consistent with the device's intent. Returns the status.
  Future<TransferGateStatus> _refreshTransferStatus() async {
    final config = _config.valueOrNull;
    if (config == null) {
      return _transfer.value;
    }
    final status = await _powerNetworkGate.evaluate(config);
    if (!_transfer.isClosed) {
      _transfer.add(status);
    }
    unawaited(_reportTransferState(config, status));
    return status;
  }

  /// Tells the backend whether this device is currently pausing transfers and
  /// why, so server-managed (Google Drive / OneDrive) copies are held while the
  /// device defers and resume together. De-duplicated to transitions only.
  Future<void> _reportTransferState(
    AppConfig config,
    TransferGateStatus status,
  ) async {
    final secrets = _secrets.valueOrNull;
    if (secrets == null || !_backendClient.canUseBackend(config, secrets)) {
      return;
    }
    final signature =
        '${status.isPaused}|${status.wireReason ?? ''}|'
        '${config.uploadNetworkPolicy.wireName}';
    final now = DateTime.now();
    final lastAt = _lastTransferReportAt;
    // Re-affirm a still-active pause periodically so the backend lease stays
    // fresh even when the gate decision itself hasn't changed.
    final needsReaffirm =
        status.isPaused &&
        (lastAt == null || now.difference(lastAt) >= _transferReaffirmInterval);
    if (signature == _lastReportedTransferSignature && !needsReaffirm) {
      return;
    }
    _lastReportedTransferSignature = signature;
    _lastTransferReportAt = now;
    final error = await _backendClient.reportTransferState(
      config: config,
      secrets: secrets,
      paused: status.isPaused,
      reason: status.wireReason,
      networkPolicy: config.uploadNetworkPolicy.wireName,
      batteryLevel: status.batteryLevel >= 0 ? status.batteryLevel : null,
      charging: status.isCharging,
    );
    if (error != null) {
      // Don't strand future reports on a transient failure.
      _lastReportedTransferSignature = null;
      _lastTransferReportAt = null;
      _diagnostics.add('Transfer-state report failed: $error');
    }
  }

  Future<void> saveConfig(AppConfig config) async {
    final deviceRetentionHours = config.deviceRetentionHours.clamp(1, 500);
    final cloudRetentionHours = config.cloudRetentionHours.clamp(
      deviceRetentionHours,
      2000,
    );
    final useCase = AppConfig.supportedUseCases.contains(config.useCase)
        ? config.useCase
        : 'security';
    final normalized = config.copyWith(
      deviceRetentionHours: deviceRetentionHours,
      cloudRetentionHours: cloudRetentionHours,
      segmentMinutes: config.segmentMinutes.clamp(1, 60),
      overlapSeconds: config.overlapSeconds.clamp(0, 30),
      bitRate: config.bitRate.clamp(16000, 320000),
      sampleRate: config.sampleRate.clamp(8000, 48000),
      channels: config.channels.clamp(1, 2),
      backendBaseUrl: config.backendBaseUrl.trim(),
      s3Bucket: config.s3Bucket.trim(),
      s3Region: config.s3Region.trim(),
      s3Prefix: config.s3Prefix.trim(),
      s3Endpoint: config.s3Endpoint.trim(),
      useCase: useCase,
      micSensitivity: config.micSensitivity.clamp(0.25, 4.0),
      noiseTriggerSensitivity: config.noiseTriggerSensitivity.clamp(0.0, 1.0),
      bassGainDb: config.bassGainDb.clamp(-12.0, 12.0),
      midGainDb: config.midGainDb.clamp(-12.0, 12.0),
      trebleGainDb: config.trebleGainDb.clamp(-12.0, 12.0),
      lowBatteryThresholdPercent: config.lowBatteryThresholdPercent.clamp(
        1,
        100,
      ),
      analysisActivationDb: config.analysisActivationDb.clamp(-90.0, 0.0),
      analysisSustainSeconds: config.analysisSustainSeconds.clamp(0.5, 30.0),
      analysisHoldSeconds: config.analysisHoldSeconds.clamp(0.0, 600.0),
      keywords: config.keywords
          .map((k) => k.trim())
          .where((k) => k.isNotEmpty)
          .toList(),
      sttEndpoint: config.sttEndpoint.trim(),
      captureSampleRate: config.captureSampleRate.clamp(8000, 48000),
      quietSampleRate: config.quietSampleRate.clamp(8000, 48000),
      adaptiveLoudnessDb: config.adaptiveLoudnessDb.clamp(-90.0, 0.0),
      sleepCycleMinutesByIndex: _normalizedSleepCycleMinutes(
        config.sleepCycleMinutesByIndex,
      ),
      recordingSchedule: config.recordingSchedule.normalize(),
    );
    final scheduleChanged =
        _config.valueOrNull?.recordingSchedule != normalized.recordingSchedule;
    if (_backendSessionKey != _sessionKey(normalized, _secrets.valueOrNull)) {
      _backendSession = null;
      _backendSessionKey = null;
    }
    _feedback.enabled = normalized.verbalCuesEnabled;
    if (normalized.sleepCycleAlarmsEnabled) {
      await _localNotifications.requestPermission();
    }
    await _settingsStore.saveConfig(normalized);
    _config.add(normalized);
    final settingsSyncError = await _syncPortableSettingsToSupabase(normalized);
    _message.add(
      settingsSyncError == null
          ? 'Settings saved.'
          : 'Settings saved on this device. Account sync failed.',
    );
    if (settingsSyncError != null) {
      _diagnostics.add(settingsSyncError);
    }
    // Battery-saver / network-policy may have changed; re-evaluate the gate (and
    // report the new policy to the backend) before draining.
    await _refreshTransferStatus();
    requestUploadDrain();
    await _enforceRetention();
    // Re-register OS events and reconcile capture when the schedule was edited.
    if (scheduleChanged) {
      await _scheduler.sync(normalized.recordingSchedule);
      await _syncScheduleForegroundService(normalized.recordingSchedule);
      await _reconcileWithSchedule(normalized.recordingSchedule);
    }
    // Re-arm context sources for any change to trigger or schedule config.
    await _updateContextTriggers();
  }

  List<double> _normalizedSleepCycleMinutes(List<double> minutes) {
    return minutes
        .map((entry) => entry.clamp(75.0, 120.0).toDouble())
        .where((entry) => entry.isFinite)
        .take(12)
        .toList(growable: false);
  }

  /// Request the permissions the armed context-trigger [kinds] depend on:
  /// notifications (background consent prompt), Bluetooth (connect/nearby), and
  /// location (Wi-Fi SSID, and BLE scanning on older Android). Without these the
  /// affected triggers silently never fire. Best-effort; failures are logged.
  Future<void> requestContextTriggerPermissions(
    Set<ContextTriggerKind> kinds,
  ) async {
    await _localNotifications.requestPermission();
    final needsBluetooth =
        kinds.contains(ContextTriggerKind.bluetoothConnect) ||
        kinds.contains(ContextTriggerKind.nearbyDevice);
    final needsLocation =
        needsBluetooth || kinds.contains(ContextTriggerKind.wifiChange);
    try {
      if (needsBluetooth) {
        if (Platform.isAndroid) {
          await [
            Permission.bluetoothScan,
            Permission.bluetoothConnect,
          ].request();
        } else if (Platform.isIOS) {
          await Permission.bluetooth.request();
        }
      }
      if (needsLocation && (Platform.isAndroid || Platform.isIOS)) {
        await Permission.locationWhenInUse.request();
      }
    } catch (error) {
      _diagnostics.add('Context permission request failed: $error');
    }
  }

  // --- Onboarding & consent --------------------------------------------------

  bool _hasValidConsent(ConsentRecord? record) {
    return record != null &&
        record.consentVersion == kConsentVersion &&
        record.hasRequiredConsents;
  }

  AppConfig _seedSupabaseDefaults(AppConfig config) {
    final url = config.supabaseUrl.trim().isEmpty
        ? kDefaultSupabaseUrl.trim()
        : config.supabaseUrl;
    final key = config.supabaseAnonKey.trim().isEmpty
        ? kDefaultSupabaseAnonKey.trim()
        : config.supabaseAnonKey;
    if (url == config.supabaseUrl && key == config.supabaseAnonKey) {
      return config;
    }
    return config.copyWith(supabaseUrl: url, supabaseAnonKey: key);
  }

  /// Finalize onboarding: persist the consent [record] locally, apply the
  /// granted optional consents to feature flags, request the matching OS
  /// permissions, sync the record to Supabase when signed in, and unlock the
  /// main UI.
  Future<void> completeOnboarding(ConsentRecord record) async {
    _consentRecord = record;
    await _settingsStore.saveConsentRecord(record);
    await _applyConsentToConfig(record);
    await requestOnboardingPermissions(record);
    await _maybeSyncConsent();
    _onboardingComplete.value = true;
    _diagnostics.add('Onboarding completed (consent $kConsentVersion).');
  }

  Future<void> _applyConsentToConfig(ConsentRecord record) async {
    if (!_config.hasValue) {
      return;
    }
    final updated = _config.value.copyWith(
      sleepMotionSensorConsent: record.granted(ConsentItem.motion),
      locationTaggingEnabled: record.granted(ConsentItem.location),
    );
    _config.add(updated);
    await _settingsStore.saveConfig(updated);
  }

  /// Requests the OS permissions for the consents the user granted. Motion
  /// (accelerometer) needs no Android runtime permission and prompts on first use
  /// on iOS, so it is not requested here. Best-effort; failures are logged.
  Future<void> requestOnboardingPermissions(ConsentRecord record) async {
    try {
      if (record.granted(ConsentItem.microphone)) {
        await Permission.microphone.request();
      }
      if (record.granted(ConsentItem.notifications)) {
        await _localNotifications.requestPermission();
      }
      if (record.granted(ConsentItem.location) &&
          (Platform.isAndroid || Platform.isIOS)) {
        await Permission.locationWhenInUse.request();
      }
      if (record.granted(ConsentItem.bluetooth)) {
        if (Platform.isAndroid) {
          await [
            Permission.bluetoothScan,
            Permission.bluetoothConnect,
          ].request();
        } else if (Platform.isIOS) {
          await Permission.bluetooth.request();
        }
      }
    } catch (error) {
      _diagnostics.add('Onboarding permission request failed: $error');
    }
  }

  /// Writes the local consent record to Supabase once a session exists. No-op
  /// when there is nothing to sync or no signed-in session yet (it is retried on
  /// the next sign-in / launch).
  Future<void> _maybeSyncConsent() async {
    final record = _consentRecord;
    final config = _config.valueOrNull;
    final secrets = _secrets.valueOrNull;
    if (record == null || record.synced || config == null || secrets == null) {
      return;
    }
    if (!_supabaseRestClient.canInsert(config, secrets)) {
      return; // not signed in yet — sync deferred
    }
    final error = await _supabaseRestClient.insertConsent(
      config: config,
      secrets: secrets,
      record: record,
    );
    if (error == null) {
      final synced = record.copyWith(synced: true);
      _consentRecord = synced;
      await _settingsStore.saveConsentRecord(synced);
      _diagnostics.add('Consent synced to Supabase.');
    } else {
      _diagnostics.add('Consent sync deferred: $error');
    }
  }

  Future<void> saveSecrets(CloudSecrets secrets) async {
    // copyWith (not a fresh constructor) so Supabase session fields — which have
    // no settings form — are always carried through; reconstructing the object
    // by hand previously dropped them and erased the stored identity token.
    final normalized = secrets.copyWith(
      s3AccessKeyId: secrets.s3AccessKeyId.trim(),
      s3SecretAccessKey: secrets.s3SecretAccessKey.trim(),
      s3SessionToken: secrets.s3SessionToken.trim(),
      backendDeviceToken: secrets.backendDeviceToken.trim(),
    );
    if (_backendSessionKey != _sessionKey(_config.valueOrNull, normalized)) {
      _backendSession = null;
      _backendSessionKey = null;
    }
    await _settingsStore.saveSecrets(normalized);
    _secrets.add(normalized);
    _message.add('Cloud credentials saved.');
    await _ensureSupabaseReady();
    requestUploadDrain();
  }

  /// Signs in with Supabase email/password and, on success, registers the device
  /// with the backend so uploads run under the verified identity.
  Future<void> signInWithSupabase({
    required String email,
    required String password,
  }) {
    return _authenticateSupabase(
      () => _authClient.signInWithPassword(
        config: _config.value,
        email: email,
        password: password,
      ),
      successMessage: 'Signed in.',
    );
  }

  /// Creates a Supabase account. When the project requires email confirmation
  /// the returned session is null and the user must confirm, then sign in.
  Future<void> signUpWithSupabase({
    required String email,
    required String password,
  }) {
    return _authenticateSupabase(
      () => _authClient.signUp(
        config: _config.value,
        email: email,
        password: password,
      ),
      successMessage: 'Signed in.',
      pendingMessage: 'Account created. Confirm your email, then sign in.',
    );
  }

  Future<void> sendSupabasePasswordReset({required String email}) async {
    if (!_config.hasValue) {
      return;
    }
    if (!_config.value.hasSupabaseAuthConfig) {
      _message.add('Set the Supabase URL and anon key before resetting.');
      return;
    }
    if (email.trim().isEmpty) {
      _message.add('Enter your account email first.');
      return;
    }
    try {
      await _authClient.sendPasswordResetEmail(
        config: _config.value,
        email: email,
      );
      _message.add('Password reset email sent.');
    } catch (error) {
      _message.add(_describeError(error));
    }
  }

  Future<void> deleteAccount() async {
    if (!_config.hasValue || !_secrets.hasValue) {
      return;
    }
    await _ensureFreshSupabaseToken();
    final config = _config.value;
    final secrets = _secrets.value;
    if (config.backendBaseUrl.trim().isEmpty) {
      _message.add('Backend URL is required before deleting your account.');
      return;
    }
    if (!secrets.hasSupabaseToken) {
      _message.add('Sign in before deleting your account.');
      return;
    }
    try {
      if (_recorder.isRecording) {
        await stopRecording();
      }
      await _playback.stop();
      await _backendClient.deleteAccount(config: config, secrets: secrets);
      await _segmentIndex.clearAll();
      _segments.add(const []);
      _pendingAlertEvents.clear();
      await _persistPendingAlerts();
      _sleepCycleProfile = const SleepCycleProfile();
      await _settingsStore.saveSleepCycleProfile(_sleepCycleProfile);
      _detectionsList.add(const []);
      _consentRequest.add(null);
      _backendSession = null;
      _backendSessionKey = null;
      await _persistSecrets(const CloudSecrets());
      _message.add('Account deleted and local data cleared.');
    } catch (error) {
      _message.add(_describeError(error));
    }
  }

  /// Revokes the Supabase session (best-effort server-side) and clears the
  /// stored identity and device token so the next sign-in re-registers cleanly.
  Future<void> signOutSupabase() async {
    final secrets = _secrets.valueOrNull;
    if (secrets != null && secrets.hasSupabaseToken && _config.hasValue) {
      await _authClient.signOut(
        config: _config.value,
        accessToken: secrets.supabaseAccessToken,
      );
    }
    // Drop the device token too: it is bound to the signed-out account, so a
    // different user signing in on this device must get a fresh registration.
    final cleared = (secrets ?? const CloudSecrets())
        .withoutSupabaseSession()
        .copyWith(backendDeviceToken: '');
    _backendSession = null;
    _backendSessionKey = null;
    await _persistSecrets(cleared);
    _message.add('Signed out.');
  }

  Future<void> _authenticateSupabase(
    Future<SupabaseSession?> Function() run, {
    required String successMessage,
    String? pendingMessage,
  }) async {
    if (!_config.hasValue) {
      return;
    }
    if (!_config.value.hasSupabaseAuthConfig) {
      _message.add('Set the Supabase URL and anon key before signing in.');
      return;
    }
    try {
      final session = await run();
      if (session == null) {
        _message.add(pendingMessage ?? successMessage);
        return;
      }
      await _applySupabaseSession(session);
      await _syncPortableSettingsFromSupabase();
      await _ensureDeviceRegistered();
      // Flush any consent captured before sign-in.
      await _maybeSyncConsent();
      _message.add(successMessage);
      requestUploadDrain();
    } catch (error) {
      _message.add(_describeError(error));
    }
  }

  Future<void> _applySupabaseSession(SupabaseSession session) async {
    final current = _secrets.valueOrNull ?? const CloudSecrets();
    // A refresh response often omits the user object; keep the known email then.
    final email = session.email.trim().isEmpty
        ? current.supabaseEmail
        : session.email;
    // Never blank an existing refresh token if the response omitted one — that
    // would strand us with no way to refresh again until the next manual login.
    final refreshToken = session.refreshToken.trim().isEmpty
        ? current.supabaseRefreshToken
        : session.refreshToken;
    // If a *different* user signed in, the existing device token belongs to the
    // previous account — drop it so the next backend call re-registers under the
    // new identity instead of writing this user's audio into the old account.
    final identityChanged =
        current.supabaseEmail.trim().isNotEmpty &&
        session.email.trim().isNotEmpty &&
        current.supabaseEmail.trim().toLowerCase() !=
            session.email.trim().toLowerCase();
    var next = current.copyWith(
      supabaseAccessToken: session.accessToken,
      supabaseRefreshToken: refreshToken,
      supabaseAccessTokenExpiresAt: session.expiresAtUtc
          .toUtc()
          .toIso8601String(),
      supabaseEmail: email,
    );
    if (identityChanged) {
      next = next.copyWith(backendDeviceToken: '');
      _backendSession = null;
      _backendSessionKey = null;
      _pendingTelemetry.clear();
    }
    await _persistSecrets(next);
    _diagnostics.add(
      'Supabase telemetry streaming started.',
      event: 'telemetry.streaming_started',
    );
    _scheduleTelemetryFlush();
  }

  void _queueDiagnosticTelemetry(DiagnosticEntry entry) {
    final config = _config.valueOrNull;
    final secrets = _secrets.valueOrNull;
    if (config == null ||
        secrets == null ||
        !_supabaseRestClient.canInsert(config, secrets)) {
      return;
    }
    _pendingTelemetry.add(
      ClientTelemetryEvent(
        level: _normalizeTelemetryLevel(entry.level),
        event: entry.event.trim().isEmpty ? 'diagnostic' : entry.event.trim(),
        message: entry.message,
        occurredAtUtc: entry.occurredAtUtc,
        stack: entry.stack?.toString(),
        platform: _telemetryPlatform(),
        details: {'source': 'diagnostic_log', ...entry.details},
      ),
    );
    if (_pendingTelemetry.length > _maxPendingTelemetry) {
      _pendingTelemetry.removeRange(
        0,
        _pendingTelemetry.length - _maxPendingTelemetry,
      );
    }
    _scheduleTelemetryFlush();
  }

  void _scheduleTelemetryFlush({
    Duration delay = const Duration(milliseconds: 250),
  }) {
    if (_pendingTelemetry.isEmpty || _telemetryFlushInFlight) {
      return;
    }
    final config = _config.valueOrNull;
    final secrets = _secrets.valueOrNull;
    if (config == null ||
        secrets == null ||
        !_supabaseRestClient.canInsert(config, secrets)) {
      return;
    }
    if (_telemetryFlushTimer?.isActive ?? false) {
      return;
    }
    _telemetryFlushTimer = Timer(delay, () {
      unawaited(_flushTelemetry());
    });
  }

  Future<void> _flushTelemetry() async {
    if (_telemetryFlushInFlight || _pendingTelemetry.isEmpty) {
      return;
    }
    final config = _config.valueOrNull;
    final secrets = _secrets.valueOrNull;
    if (config == null ||
        secrets == null ||
        !_supabaseRestClient.canInsert(config, secrets)) {
      return;
    }
    _telemetryFlushTimer?.cancel();
    _telemetryFlushInFlight = true;
    var ok = false;
    try {
      await _ensureFreshSupabaseToken();
      final freshSecrets = _secrets.valueOrNull ?? secrets;
      final batch = _pendingTelemetry
          .take(_telemetryBatchSize)
          .toList(growable: false);
      final error = await _supabaseRestClient.insertTelemetry(
        config: _config.valueOrNull ?? config,
        secrets: freshSecrets,
        events: batch,
      );
      ok = error == null;
      if (ok && _pendingTelemetry.isNotEmpty) {
        _pendingTelemetry.removeRange(
          0,
          batch.length.clamp(0, _pendingTelemetry.length),
        );
      }
    } finally {
      _telemetryFlushInFlight = false;
    }
    if (_pendingTelemetry.isNotEmpty) {
      _scheduleTelemetryFlush(
        delay: ok
            ? const Duration(milliseconds: 250)
            : const Duration(seconds: 30),
      );
    }
  }

  String _telemetryPlatform() {
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    if (Platform.isMacOS) {
      return 'macos';
    }
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isLinux) {
      return 'linux';
    }
    return 'other';
  }

  String _normalizeTelemetryLevel(String level) {
    final normalized = level.trim().toLowerCase();
    const allowed = {'debug', 'info', 'warning', 'error', 'fatal'};
    return allowed.contains(normalized) ? normalized : 'info';
  }

  void recordFlutterError(FlutterErrorDetails details) {
    _diagnostics.add(
      details.exceptionAsString(),
      level: 'error',
      event: 'flutter_error',
      stack: details.stack,
      details: {
        'exceptionType': details.exception.runtimeType.toString(),
        if (details.library != null) 'library': details.library,
        if (details.context != null) 'context': details.context.toString(),
      },
    );
  }

  void recordUnhandledError(
    Object error,
    StackTrace stack, {
    String event = 'unhandled_dart_error',
  }) {
    _diagnostics.add(
      error.toString(),
      level: 'fatal',
      event: event,
      stack: stack,
      details: {'exceptionType': error.runtimeType.toString()},
    );
  }

  Future<void> _persistSecrets(CloudSecrets secrets) async {
    if (_backendSessionKey != _sessionKey(_config.valueOrNull, secrets)) {
      _backendSession = null;
      _backendSessionKey = null;
    }
    await _settingsStore.saveSecrets(secrets);
    _secrets.add(secrets);
  }

  Future<void> _ensureSupabaseReady() async {
    await _ensureFreshSupabaseToken();
    await _ensureDeviceRegistered();
  }

  Future<String?> _syncPortableSettingsToSupabase(AppConfig config) async {
    final currentSecrets = _secrets.valueOrNull;
    if (currentSecrets == null || !currentSecrets.hasSupabaseToken) {
      return null;
    }
    await _ensureFreshSupabaseToken();
    final secrets = _secrets.valueOrNull;
    if (secrets == null || !secrets.hasSupabaseToken) {
      return 'Portable settings sync skipped because the Supabase session is unavailable.';
    }
    return _supabaseRestClient.upsertUserSettings(
      config: config,
      secrets: secrets,
    );
  }

  Future<void> _syncPortableSettingsFromSupabase() async {
    if (!_config.hasValue) {
      return;
    }
    await _ensureFreshSupabaseToken();
    final config = _config.value;
    final secrets = _secrets.valueOrNull;
    if (secrets == null || !secrets.hasSupabaseToken) {
      return;
    }
    final result = await _supabaseRestClient.fetchUserSettings(
      config: config,
      secrets: secrets,
    );
    if (result.error != null) {
      _diagnostics.add(result.error!);
      return;
    }
    final remote = result.settings;
    if (remote == null) {
      final error = await _syncPortableSettingsToSupabase(config);
      if (error != null) {
        _diagnostics.add(error);
      }
      return;
    }
    final merged = _supabaseRestClient.mergeUserSettings(config, remote);
    await saveConfig(merged);
  }

  /// Silently refreshes the Supabase access token when it is missing or near
  /// expiry, rotating the stored refresh token. De-duplicated so concurrent
  /// backend operations don't each spend (and invalidate) the rotating token.
  Future<void> _ensureFreshSupabaseToken() async {
    if (!_config.hasValue) {
      return;
    }
    final config = _config.value;
    final secrets = _secrets.valueOrNull;
    if (secrets == null ||
        !secrets.hasSupabaseRefreshToken ||
        !secrets.supabaseTokenNeedsRefresh() ||
        !config.hasSupabaseAuthConfig) {
      return;
    }
    final inFlight = _supabaseRefreshInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final future = _refreshSupabaseToken(config, secrets.supabaseRefreshToken);
    _supabaseRefreshInFlight = future;
    try {
      await future;
    } finally {
      _supabaseRefreshInFlight = null;
    }
  }

  Future<void> _refreshSupabaseToken(
    AppConfig config,
    String refreshToken,
  ) async {
    try {
      final session = await _authClient.refreshSession(
        config: config,
        refreshToken: refreshToken,
      );
      await _applySupabaseSession(session);
      _diagnostics.add('Supabase access token refreshed.');
    } catch (error) {
      _diagnostics.add(
        'Supabase token refresh failed: ${_describeError(error)}',
      );
    }
  }

  /// Registers the device with the backend once a Supabase session exists and no
  /// device token is held yet. De-duplicated so concurrent callers share one
  /// in-flight request.
  Future<void> _ensureDeviceRegistered() async {
    if (!_config.hasValue) {
      return;
    }
    final config = _config.value;
    final secrets = _secrets.valueOrNull ?? const CloudSecrets();
    if (config.backendBaseUrl.trim().isEmpty ||
        !secrets.hasSupabaseToken ||
        secrets.hasBackendDeviceToken) {
      return;
    }
    final inFlight = _deviceRegistrationInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final future = _registerDevice(config, secrets);
    _deviceRegistrationInFlight = future;
    try {
      await future;
    } finally {
      _deviceRegistrationInFlight = null;
    }
  }

  Future<void> _registerDevice(AppConfig config, CloudSecrets secrets) async {
    try {
      final registration = await _backendClient.registerDevice(
        config: config,
        secrets: secrets,
        platform: _platformName(),
        installId: config.deviceId,
        consentVersion: kConsentVersion,
      );
      if (registration.deviceToken.trim().isEmpty) {
        return;
      }
      final updated = (_secrets.valueOrNull ?? secrets).copyWith(
        backendDeviceToken: registration.deviceToken.trim(),
      );
      await _persistSecrets(updated);
      _diagnostics.add('Device registered with backend.');
      requestUploadDrain();
    } catch (error) {
      _diagnostics.add('Device registration failed: ${_describeError(error)}');
    }
  }

  String _platformName() {
    if (Platform.isIOS) {
      return 'ios';
    }
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isMacOS) {
      return 'macos';
    }
    return 'other';
  }

  String _describeError(Object error) {
    if (error is StateError) {
      return error.message;
    }
    if (error is FormatException) {
      return error.message;
    }
    return error.toString();
  }

  Future<void> startRecording({bool scheduleInitiated = false}) async {
    // Ownership: a manual start clears schedule ownership, a schedule-driven
    // start claims it. Only a schedule-owned session is auto-stopped at a window
    // barrier (see [_applyScheduleState]).
    _scheduleStartedRecording = scheduleInitiated;
    _diagnostics.add('Start recording requested.');
    _consentRequest.add(null);
    // Surface a busy state for the whole flow — the notification + microphone
    // permission prompts can take a moment to appear, and the button should
    // spin rather than look unresponsive while the user waits for them.
    _isStarting.add(true);
    try {
      final backgroundError = await _backgroundCaptureService.start();
      if (backgroundError != null) {
        _diagnostics.add(backgroundError);
      }
      try {
        _diagnostics.add('Starting PCM microphone stream.');
        await _recorder.start(_config.value);
        // Capture is live: from here a dropped stream should be auto-resumed.
        _intendRecording = true;
        _diagnostics.add('PCM microphone stream started.');
        unawaited(_feedback.say('Recording started'));
        _message.add(
          backgroundError == null
              ? 'Recording started.'
              : 'Recording started locally. $backgroundError',
        );
      } catch (error) {
        _diagnostics.add('Recorder start failed: $error.');
        await _backgroundCaptureService.stop();
        _message.add(error.toString());
      }
    } finally {
      _isStarting.add(false);
    }
    // Recording is now (probably) live — pause context sources while we capture.
    await _updateContextTriggers();
  }

  Future<void> stopRecording() async {
    _diagnostics.add('Stop recording requested.');
    // Clear intent first so an in-flight resume request does not re-start us.
    _intendRecording = false;
    Object? recorderError;
    try {
      await _recorder.stop();
      _diagnostics.add('PCM microphone stream stopped.');
    } catch (error) {
      recorderError = error;
      _diagnostics.add('Recorder stop failed: $error.');
    } finally {
      await _backgroundCaptureService.stop();
    }
    unawaited(_feedback.say('Recording stopped'));
    _message.add(
      recorderError == null
          ? 'Recording stopped.'
          : 'Foreground service stopped after recorder error: $recorderError',
    );
    _diagnostics.add('Stop recording completed.');
    requestUploadDrain();
    // Idle again — if we're still inside a window, re-arm context sources so a
    // later event can offer to resume.
    await _updateContextTriggers();
  }

  /// Android's microphone permission is "while in use"; recent Android versions
  /// do not reliably allow a microphone foreground service to be created from a
  /// fully background/killed state. Once the user arms a schedule, keep a
  /// foreground service alive in a truthful standby mode so the in-app schedule
  /// timer can open the mic exactly at the declared windows.
  Future<void> _syncScheduleForegroundService(
    RecordingSchedule schedule,
  ) async {
    if (_recorder.isRecording) {
      return;
    }
    if (!schedule.enabled || !schedule.hasAnyWindows) {
      await _backgroundCaptureService.stop();
      return;
    }
    final error = await _backgroundCaptureService.start(
      mode: BackgroundCaptureMode.scheduleStandby,
    );
    if (error != null) {
      _diagnostics.add(error);
      _message.add(
        'Scheduled recording is armed, but Android background protection is not active: $error',
      );
    }
  }

  /// Battery-friendly voice profile (16 kHz) vs. the music-grade high-fidelity
  /// profile (48 kHz). The capture rate is what the mic stream opens at.
  static const int mediumQualitySampleRate = 16000;
  static const int highQualitySampleRate = 48000;

  /// True when capture is running at the high-fidelity profile.
  bool get isHighQualityRecording =>
      _config.hasValue && _config.value.sampleRate >= highQualitySampleRate;

  /// Switches between the medium (voice) and high (music-grade) capture
  /// profiles, speaks a confirmation prompt, and — when capture is live —
  /// restarts the mic stream so the new sample rate takes effect at once.
  Future<void> setHighQualityRecording(bool enabled) async {
    if (!_config.hasValue) {
      return;
    }
    final target = enabled ? highQualitySampleRate : mediumQualitySampleRate;
    final current = _config.value;
    if (current.sampleRate == target) {
      return;
    }
    await saveConfig(current.copyWith(sampleRate: target));
    await _feedback.say(
      enabled
          ? 'Switching to high quality recording'
          : 'Switching back to medium quality recording',
      force: true,
    );
    if (_recorder.isRecording) {
      // Re-open the stream at the new rate without an extra spoken cue.
      await restartRecording(announce: false);
    }
  }

  /// Convenience for a single toggle button.
  Future<void> toggleHighQualityRecording() =>
      setHighQualityRecording(!isHighQualityRecording);

  /// Stops and immediately restarts capture — to roll a fresh segment or apply a
  /// new capture profile. Speaks a "Restarting recording" cue unless [announce]
  /// is false (e.g. when a quality switch already announced the change).
  Future<void> restartRecording({bool announce = true}) async {
    _diagnostics.add('Restart recording requested.');
    if (announce) {
      await _feedback.say('Restarting recording', force: true);
    }
    // Preserve schedule ownership across a restart (quality switch, fresh
    // segment) so a mid-window restart doesn't reclassify the session as manual.
    final wasScheduleOwned = _scheduleStartedRecording;
    await stopRecording();
    await startRecording(scheduleInitiated: wasScheduleOwned);
  }

  /// Restarts capture after the recorder reports an interruption/stall it could
  /// not resume itself. Silent (no spoken cue, no schedule-ownership change) and
  /// rate-limited so a device that genuinely cannot record does not spin.
  Future<void> _handleAutoResume(String reason) async {
    if (!_intendRecording || _autoResuming) {
      return;
    }
    final now = DateTime.now();
    _recentAutoResumes.removeWhere(
      (t) => now.difference(t) > const Duration(seconds: 60),
    );
    if (_recentAutoResumes.length >= _maxAutoResumesPerMinute) {
      _diagnostics.add(
        'Auto-resume suppressed after '
        '${_recentAutoResumes.length} attempts in 60s ($reason).',
      );
      _message.add(
        'Recording was interrupted and could not restart automatically. '
        'Tap record to resume.',
      );
      return;
    }
    _recentAutoResumes.add(now);
    _autoResuming = true;
    _diagnostics.add('Auto-resuming capture ($reason).');
    try {
      await restartRecording(announce: false);
    } catch (error) {
      _diagnostics.add('Auto-resume restart failed: $error.');
    } finally {
      _autoResuming = false;
    }
  }

  Future<void> playLocalWindow() async {
    await _playback.playSegments(_segments.value);
  }

  /// Play a chosen wall-clock window across the rolling buffer, optionally looping.
  Future<void> playRange({
    required DateTime startUtc,
    required DateTime endUtc,
    bool loop = false,
  }) async {
    await _playback.playRange(_segments.value, startUtc, endUtc, loop: loop);
  }

  /// Earliest local audio currently available (for the playback range picker),
  /// or null when nothing is buffered yet.
  DateTime? get earliestLocalSegmentUtc {
    final locals = _segments.value.where((s) => s.localPath != null).toList();
    if (locals.isEmpty) {
      return null;
    }
    return locals
        .map((s) => s.startedAtUtc)
        .reduce((a, b) => a.isBefore(b) ? a : b);
  }

  Future<void> pausePlayback() => _playback.pause();

  Future<void> stopPlayback() => _playback.stop();

  Future<void> saveRangePermanently({
    required DateTime startedAtUtc,
    required DateTime endedAtUtc,
  }) async {
    if (!_config.hasValue || !_secrets.hasValue) {
      return;
    }
    final rangeStart = startedAtUtc.toUtc();
    final rangeEnd = endedAtUtc.toUtc();
    if (!rangeEnd.isAfter(rangeStart)) {
      _message.add('End timestamp must be after start timestamp.');
      return;
    }
    await _ensureFreshSupabaseToken();
    await _ensureDeviceRegistered();
    final config = _config.value;
    final secrets = _secrets.value;
    final useBackend = _backendClient.canUseBackend(config, secrets);
    final useDirectS3 =
        !useBackend &&
        config.cloudProvider == CloudProvider.s3 &&
        config.s3TargetReady &&
        secrets.hasS3Credentials;
    if (!useBackend && !useDirectS3) {
      _message.add(
        config.cloudProvider == CloudProvider.s3
            ? 'S3 bucket, region, access key, and secret key are required before permanent save can run.'
            : '${config.cloudProvider.label} permanent save requires the sound recorder backend URL and device token.',
      );
      return;
    }
    final matching =
        (await _segmentIndex.loadSegments())
            .where(
              (segment) =>
                  segment.endedAtUtc.isAfter(rangeStart) &&
                  segment.startedAtUtc.isBefore(rangeEnd),
            )
            .toList()
          ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    if (matching.isEmpty) {
      _message.add('No indexed segments overlap that range.');
      return;
    }
    final unsaved = matching
        .where((segment) => !segment.isPermanentlySaved)
        .toList();
    if (unsaved.isEmpty) {
      _message.add('That range is already permanently saved.');
      return;
    }
    _diagnostics.add(
      'Permanent save requested for ${unsaved.length} segment(s).',
    );
    if (useBackend) {
      await _saveRangeViaBackend(
        config: config,
        secrets: secrets,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        segments: unsaved,
      );
    } else {
      await _saveRangeViaS3(
        config: config,
        secrets: secrets,
        segments: unsaved,
      );
    }
    // A permanent save is an explicit user action — the moment to add any songs
    // heard in that range to the user's private Spotify playlist (opt-in).
    await _publishSpotifyMemoriesForRange(
      config: config,
      secrets: secrets,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    );
    await _enforceRetention();
  }

  /// Adds songs Shazam recognised in a saved range to the user's private Spotify
  /// "memories" playlist, de-duplicated. Opt-in and best-effort.
  Future<void> _publishSpotifyMemoriesForRange({
    required AppConfig config,
    required CloudSecrets secrets,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) async {
    if (!_memoryPublisher.wantsSpotify(config, secrets)) {
      return;
    }
    final songs = _recognisedSongsInRange(rangeStart, rangeEnd);
    if (songs.isEmpty) {
      return;
    }
    try {
      final result = await _memoryPublisher.publishRecognisedSongs(
        config: config,
        secrets: secrets,
        recognisedSongs: songs,
      );
      if (result.didAnything) {
        _message.add(result.notes.join(' '));
        await _feedback.say('Added to your Spotify memories', force: true);
      }
    } catch (error) {
      _diagnostics.add('Spotify memory publish failed: $error');
    }
  }

  /// Concatenates the local plaintext WAV segments in a saved range into a single
  /// WAV for upload. Returns null when no local audio is available (e.g. the
  /// clip has already rolled off the device). Local files are plaintext —
  /// encryption only happens on the way to the cloud.
  Future<Uint8List?> _assembleClipWav(List<RecordingSegment> segments) async {
    final pcm = BytesBuilder(copy: false);
    var sampleRate = 0;
    var channels = 1;
    for (final segment in segments) {
      final path = segment.localPath;
      if (path == null) {
        continue;
      }
      final file = File(path);
      if (!await file.exists()) {
        continue;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length <= 44) {
        continue; // header-only / empty
      }
      pcm.add(bytes.sublist(44)); // strip the 44-byte WAV header, keep PCM
      if (segment.sampleRate > 0) {
        sampleRate = segment.sampleRate;
      }
      if (segment.channels > 0) {
        channels = segment.channels;
      }
    }
    final pcmBytes = pcm.toBytes();
    if (pcmBytes.isEmpty || sampleRate == 0) {
      return null;
    }
    return wavBytesFromPcm16(pcmBytes, sampleRate, channels);
  }

  /// Distinct songs Shazam recognised within the saved range, newest first.
  List<RecognisedSong> _recognisedSongsInRange(
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    final out = <RecognisedSong>[];
    final seen = <String>{};
    for (final detection in _detectionsList.value) {
      if (detection.kind != AcousticDetectionKind.music) {
        continue;
      }
      if (!detection.startedAtUtc.isBefore(rangeEnd) ||
          !detection.endedAtUtc.isAfter(rangeStart)) {
        continue;
      }
      final title = (detection.details['title'] as String?)?.trim() ?? '';
      if (title.isEmpty) {
        continue;
      }
      final artist = (detection.details['artist'] as String?)?.trim();
      final key = '$title|${artist ?? ''}'.toLowerCase();
      if (seen.add(key)) {
        out.add(RecognisedSong(title: title, artist: artist));
      }
    }
    return out;
  }

  // --- Music account linking (SoundCloud / Spotify) -------------------------

  bool get isSpotifyLinked => _secrets.valueOrNull?.hasSpotifyToken ?? false;
  bool get isSoundCloudLinked =>
      _secrets.valueOrNull?.hasSoundCloudToken ?? false;

  Future<void> linkSpotify() => _linkMusic(
    label: 'Spotify',
    config: MusicOAuthService.spotify(
      clientId: MusicOAuthConstants.spotifyClientId,
      redirectUri: MusicOAuthConstants.redirectUri,
    ),
    apply: (secrets, tokens) => secrets.copyWith(
      spotifyAccessToken: tokens.accessToken,
      spotifyRefreshToken: tokens.refreshToken ?? '',
    ),
  );

  Future<void> linkSoundCloud() => _linkMusic(
    label: 'SoundCloud',
    config: MusicOAuthService.soundCloud(
      clientId: MusicOAuthConstants.soundCloudClientId,
      redirectUri: MusicOAuthConstants.redirectUri,
    ),
    apply: (secrets, tokens) => secrets.copyWith(
      soundCloudAccessToken: tokens.accessToken,
      soundCloudRefreshToken: tokens.refreshToken ?? '',
    ),
  );

  Future<void> unlinkSpotify() async {
    if (!_secrets.hasValue) return;
    await saveSecrets(_secrets.value.withoutSpotify());
    _message.add('Spotify unlinked.');
  }

  Future<void> unlinkSoundCloud() async {
    if (!_secrets.hasValue) return;
    await saveSecrets(_secrets.value.withoutSoundCloud());
    _message.add('SoundCloud unlinked.');
  }

  /// Shared OAuth-with-PKCE link flow: build the URL, run the browser leg,
  /// verify state, exchange the code, and persist the tokens via [apply].
  Future<void> _linkMusic({
    required String label,
    required OAuthProviderConfig config,
    required CloudSecrets Function(CloudSecrets, OAuthTokens) apply,
  }) async {
    if (!config.isConfigured) {
      _message.add(
        '$label isn\'t configured in this build (missing client id).',
      );
      return;
    }
    if (!_secrets.hasValue) {
      _message.add('Sign in before linking $label.');
      return;
    }
    try {
      final pkce = _musicOAuthService.generatePkce();
      final state = _musicOAuthService.randomState();
      final url = _musicOAuthService.buildAuthorizeUrl(
        config: config,
        state: state,
        codeChallenge: pkce.challenge,
      );
      final redirect = await _oauthBrowser.authorize(
        url: url,
        callbackScheme: MusicOAuthConstants.callbackScheme,
      );
      if (redirect == null) {
        _message.add('$label linking was cancelled.');
        return;
      }
      if (redirect.queryParameters['state'] != state) {
        _message.add('$label linking failed: state mismatch.');
        return;
      }
      final code = redirect.queryParameters['code'];
      if (code == null || code.isEmpty) {
        _message.add('$label linking failed: no authorization code.');
        return;
      }
      final tokens = await _musicOAuthService.exchangeCode(
        config: config,
        code: code,
        codeVerifier: pkce.verifier,
      );
      if (tokens == null) {
        _message.add('$label linking failed: token exchange error.');
        return;
      }
      await saveSecrets(apply(_secrets.value, tokens));
      _message.add('$label linked.');
    } catch (error) {
      _message.add('$label linking failed: ${_describeError(error)}');
    }
  }

  Future<void> sendManualAlert() {
    return _sendAlertForEvent(
      AudioTriggerEvent(
        type: AudioTriggerType.manual,
        occurredAtUtc: DateTime.now().toUtc(),
        captureSessionId: '',
        sampleIndex: 0,
      ),
      userVisible: true,
    );
  }

  /// In-app confirmation that capture is live: reports recording state and the
  /// current input level, and speaks it when verbal cues are enabled.
  Future<void> confirmRecording() async {
    final snapshot = _recorder.snapshots.value;
    final recording = _recorder.isRecording;
    final levelDb = snapshot.peakDb;
    if (recording) {
      final levelText = levelDb <= -120
          ? 'no input detected yet'
          : 'input level ${levelDb.toStringAsFixed(0)} dB';
      _message.add('Recording is active — $levelText.');
      await _feedback.say(
        levelDb > -50 ? 'Recording, sound detected' : 'Recording, but quiet',
      );
    } else {
      _message.add('Not recording. Press Start to begin capture.');
      await _feedback.say('Not recording');
    }
  }

  /// Validates that the backend is reachable and the device is registered, and
  /// refreshes the Supabase token, returning the context for a cloud-link call.
  Future<({AppConfig config, CloudSecrets secrets})?> _backendContext(
    String action,
  ) async {
    if (!_config.hasValue || !_secrets.hasValue) {
      return null;
    }
    final config = _config.value;
    if (config.backendBaseUrl.trim().isEmpty ||
        !_secrets.value.hasBackendDeviceToken) {
      _message.add('Sign in and register the device before $action.');
      return null;
    }
    await _ensureFreshSupabaseToken();
    return (config: config, secrets: _secrets.value);
  }

  Future<List<CloudConnection>> loadCloudConnections() async {
    final ctx = await _backendContext('viewing cloud links');
    if (ctx == null) {
      return const [];
    }
    final rows = await _backendClient.listCloudConnections(
      config: ctx.config,
      secrets: ctx.secrets,
    );
    return rows
        .map(CloudConnection.fromJson)
        .where((connection) => connection.id.isNotEmpty)
        .toList();
  }

  /// Links Apple iCloud (client-managed): the server records the destination and
  /// begins emitting copy jobs the device mirrors via [syncIcloudBackups].
  Future<void> linkICloud() async {
    final ctx = await _backendContext('linking iCloud');
    if (ctx == null) {
      return;
    }
    try {
      final start = CloudLinkStart.fromJson(
        await _backendClient.startCloudLink(
          config: ctx.config,
          secrets: ctx.secrets,
          provider: CloudProvider.iCloudDrive,
        ),
      );
      await _backendClient.completeCloudLink(
        config: ctx.config,
        secrets: ctx.secrets,
        provider: CloudProvider.iCloudDrive,
        state: start.state,
        clientManagedAcknowledged: true,
      );
      _message.add('iCloud linked. Recordings will mirror to your iCloud.');
      unawaited(syncIcloudBackups());
    } catch (error) {
      _message.add('iCloud link failed: ${_describeError(error)}');
    }
  }

  /// Starts a server-managed (Google Drive / OneDrive) link and returns the
  /// authorization details the UI shows the user to grant access.
  Future<CloudLinkStart?> startProviderLink(
    CloudProvider provider, {
    String? redirectUri,
  }) async {
    final ctx = await _backendContext('linking ${provider.label}');
    if (ctx == null) {
      return null;
    }
    try {
      return CloudLinkStart.fromJson(
        await _backendClient.startCloudLink(
          config: ctx.config,
          secrets: ctx.secrets,
          provider: provider,
          redirectUri: redirectUri,
        ),
      );
    } catch (error) {
      _message.add(
        'Starting ${provider.label} link failed: '
        '${_describeError(error)}',
      );
      return null;
    }
  }

  /// Completes a server-managed link with the authorization code the user pasted
  /// back after granting access in the browser.
  Future<bool> completeProviderLink({
    required CloudProvider provider,
    required String state,
    required String authorizationCode,
    String? redirectUri,
  }) async {
    final ctx = await _backendContext('linking ${provider.label}');
    if (ctx == null) {
      return false;
    }
    try {
      await _backendClient.completeCloudLink(
        config: ctx.config,
        secrets: ctx.secrets,
        provider: provider,
        state: state,
        authorizationCode: authorizationCode,
        redirectUri: redirectUri,
      );
      _message.add('${provider.label} linked.');
      requestUploadDrain();
      return true;
    } catch (error) {
      _message.add('${provider.label} link failed: ${_describeError(error)}');
      return false;
    }
  }

  Future<void> revokeCloudConnection(String connectionId) async {
    final ctx = await _backendContext('updating cloud links');
    if (ctx == null) {
      return;
    }
    try {
      await _backendClient.revokeCloudConnection(
        config: ctx.config,
        secrets: ctx.secrets,
        connectionId: connectionId,
      );
      _message.add('Cloud connection removed.');
    } catch (error) {
      _message.add('Removing connection failed: ${_describeError(error)}');
    }
  }

  /// Drains pending iCloud copy jobs through the native layer. Safe to call
  /// often; it no-ops unless iCloud is the selected provider and reachable.
  /// De-duplicated so overlapping callers (every upload drain triggers one)
  /// don't download and write the same jobs twice in parallel.
  Future<void> syncIcloudBackups() async {
    final inFlight = _icloudSyncInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _syncIcloudBackups();
    _icloudSyncInFlight = future;
    try {
      await future;
    } finally {
      _icloudSyncInFlight = null;
    }
  }

  Future<void> _syncIcloudBackups() async {
    if (!_config.hasValue || !_secrets.hasValue) {
      return;
    }
    final config = _config.value;
    if (config.cloudProvider != CloudProvider.iCloudDrive) {
      return;
    }
    if (config.backendBaseUrl.trim().isEmpty ||
        !_secrets.value.hasBackendDeviceToken) {
      return;
    }
    // iCloud mirroring downloads each segment and writes it into the user's
    // iCloud container — a device-originated transfer, so honor the same gate.
    final gate = await _refreshTransferStatus();
    if (!gate.allowed) {
      _diagnostics.add('iCloud mirroring deferred: ${gate.detail ?? 'gated'}');
      return;
    }
    await _ensureFreshSupabaseToken();
    final result = await _icloudSyncService.syncPendingJobs(
      backendClient: _backendClient,
      config: config,
      secrets: _secrets.value,
    );
    if (result.skipped) {
      return;
    }
    if (result.error != null) {
      _diagnostics.add('iCloud sync: ${result.error}');
    } else if (result.completed > 0 || result.failed > 0) {
      _diagnostics.add(
        'iCloud sync: ${result.completed} copied, ${result.failed} failed.',
      );
    }
  }

  void requestUploadDrain() {
    if (!_uploadRequests.isClosed) {
      _uploadRequests.add(null);
    }
  }

  Future<void> clearMessage() async {
    _message.add(null);
  }

  Future<void> dispose() async {
    // 1. Stop listening before tearing down the sources these subscriptions
    //    read, so a late event can't fire into a half-disposed controller. The
    //    cancels are mutually independent — run them together.
    await Future.wait([
      _closedSegmentsSubscription?.cancel() ?? Future<void>.value(),
      _triggerSubscription?.cancel() ?? Future<void>.value(),
      _detectionsSubscription?.cancel() ?? Future<void>.value(),
      _uploadSubscription?.cancel() ?? Future<void>.value(),
      _resumeRequestsSubscription?.cancel() ?? Future<void>.value(),
      _transferConditionsSubscription?.cancel() ?? Future<void>.value(),
      _diagnosticTelemetrySubscription?.cancel() ?? Future<void>.value(),
    ]);
    _telemetryFlushTimer?.cancel();

    // 2. Synchronous client/scheduler closes — fire them off together.
    _scheduler.dispose();
    _s3StorageClient.close();
    _icloudSyncService.close();
    _backendClient.close();
    _authClient.close();
    _supabaseRestClient.close();
    _onboardingComplete.dispose();
    _speechToTextClient.close();
    _memoryPublisher.close();
    _dayOfLifeArchiver.close();
    _musicOAuthService.close();

    // 3. Independent async teardowns + own-stream closes, now that the
    //    subscriptions feeding/reading them are gone. _diagnostics is held back
    //    to step 4 because these may still log to it.
    await Future.wait([
      _contextTriggers.dispose(),
      _uploadRequests.close(),
      _recorder.dispose(),
      _playback.dispose(),
      _feedback.dispose(),
      _config.close(),
      _secrets.close(),
      _segments.close(),
      _isInitializing.close(),
      _isStarting.close(),
      _isUploading.close(),
      _transfer.close(),
      _message.close(),
      _detectionsList.close(),
      _consentRequest.close(),
    ]);

    // 4. Diagnostics last: the teardowns above may still write to it.
    await _diagnostics.dispose();
  }

  Future<void> _onSegmentClosed(RecordingSegment segment) async {
    final tagged = await _attachGeoTag(segment);
    await _segmentIndex.upsertSegment(tagged);
    // Write the parallel FFT analysis track next to the audio (best-effort, off
    // the realtime capture path). Independent of the loudness-gated detector.
    if (_config.hasValue && _config.value.spectralSidecarEnabled) {
      try {
        await _spectralSidecar.writeForSegment(tagged);
      } catch (error) {
        _diagnostics.add('Spectral sidecar failed: $error');
      }
    }
    final nextSegments = await _segmentIndex.loadSegments();
    _segments.add(nextSegments);
    requestUploadDrain();
    await _maybeArchivePreviousDay();
    await _enforceRetention();
  }

  /// Detects a local calendar-day rollover and, if the "Day of My Life"
  /// SoundCloud archive is enabled, publishes the day that just ended. The
  /// last-seen day is tracked in memory; days missed while the app was fully
  /// closed are not back-filled (a catch-up pass is a follow-up).
  Future<void> _maybeArchivePreviousDay() async {
    if (!_config.hasValue || !_secrets.hasValue) {
      return;
    }
    final today = _localDateOnly(DateTime.now());
    if (!_dayOfLifeArchiver.isEnabled(_config.value, _secrets.value)) {
      _lastSeenLocalDay = today;
      return;
    }
    _lastArchivedDay ??= await _settingsStore.loadLastArchivedDay();

    // One-time startup catch-up: if yesterday was never archived (e.g. the app
    // was closed across midnight), publish it now. Bounded to a single day —
    // multi-day backfill is intentionally out of scope.
    if (!_archiveCaughtUp) {
      _archiveCaughtUp = true;
      final yesterday = _localDateOnly(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      if (_lastArchivedDay == null || yesterday.isAfter(_lastArchivedDay!)) {
        await _archiveDayOfLife(yesterday);
      }
    }

    final last = _lastSeenLocalDay;
    _lastSeenLocalDay = today;
    if (last == null || !today.isAfter(last)) {
      return; // same local day, or first segment since launch
    }
    // The day rolled over; archive the day that just ended (once).
    if (_lastArchivedDay == null || last.isAfter(_lastArchivedDay!)) {
      await _archiveDayOfLife(last);
    }
  }

  /// Assembles [dayLocal]'s local audio + on-device activity notes and publishes
  /// it as a private "Day of My Life" SoundCloud track, pruning the rolling
  /// window. Best-effort; never throws into the capture pipeline.
  Future<void> _archiveDayOfLife(DateTime dayLocal) async {
    try {
      final dayStartUtc = dayLocal.toUtc();
      final dayEndUtc = dayLocal.add(const Duration(days: 1)).toUtc();
      final segments =
          (await _segmentIndex.loadSegments())
              .where(
                (s) =>
                    s.endedAtUtc.isAfter(dayStartUtc) &&
                    s.startedAtUtc.isBefore(dayEndUtc),
              )
              .toList()
            ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
      if (segments.isEmpty) {
        return;
      }
      final wav = await _assembleClipWav(segments);
      final geo = [
        for (final s in segments)
          if (s.geoTag != null) s.geoTag!,
      ];
      final detections = _detectionsList.value
          .where(
            (d) =>
                d.startedAtUtc.isBefore(dayEndUtc) &&
                d.endedAtUtc.isAfter(dayStartUtc),
          )
          .toList();
      final result = await _dayOfLifeArchiver.archiveDay(
        secrets: _secrets.value,
        dayLocal: dayLocal,
        wavBytes: wav,
        detections: detections,
        geo: geo,
        resolvePlaces:
            _config.value.placeNamesEnabled &&
            _config.value.locationTaggingEnabled,
      );
      if (result.didUpload) {
        _lastArchivedDay = dayLocal;
        await _settingsStore.saveLastArchivedDay(dayLocal);
        _message.add(
          'Published "Day of My Life" to SoundCloud '
          '(${result.noteCount} note(s)'
          '${result.prunedCount > 0 ? ', pruned ${result.prunedCount} old day(s)' : ''}).',
        );
        await _feedback.say('Day of my life saved', force: true);
      } else if (result.note != null) {
        _diagnostics.add('Day of My Life: ${result.note}');
      }
    } catch (error) {
      _diagnostics.add('Day of My Life archive failed: $error');
    }
  }

  DateTime _localDateOnly(DateTime dt) {
    final local = dt.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// Stamps a closed segment with the current GPS fix when location tagging is
  /// enabled. Best-effort: a missing fix leaves the segment untagged and never
  /// blocks indexing or upload — evidence is added when available, never required.
  Future<RecordingSegment> _attachGeoTag(RecordingSegment segment) async {
    if (!_config.hasValue ||
        !_config.value.locationTaggingEnabled ||
        segment.geoTag != null) {
      return segment;
    }
    try {
      final tag = await _locationService.currentTag();
      if (tag == null) {
        return segment;
      }
      _diagnostics.add(
        'Tagged segment ${segment.sequence} @ '
        '${tag.latitude.toStringAsFixed(5)}, '
        '${tag.longitude.toStringAsFixed(5)} (${tag.accuracyLabel}).',
      );
      return segment.copyWith(geoTag: tag);
    } catch (error) {
      _diagnostics.add('Location tag skipped: $error');
      return segment;
    }
  }

  Future<void> _drainUploads() async {
    if (_isUploading.value) {
      return;
    }
    if (!_config.hasValue || !_secrets.hasValue) {
      return;
    }
    if (!_config.value.uploadEnabled) {
      return;
    }
    // Power / network gate. Recording (the rolling local window) is untouched;
    // this only defers cloud streaming, so segments stay on device and catch up
    // once the battery recovers or an allowed network is available.
    final gate = await _refreshTransferStatus();
    if (!gate.allowed) {
      _diagnostics.add('Uploads deferred: ${gate.detail ?? 'gated'}');
      return;
    }
    // Refresh identity / registration before reading secrets so the upload runs
    // with a non-expired Supabase token and a device token if one is available.
    await _ensureFreshSupabaseToken();
    await _ensureDeviceRegistered();
    final config = _config.value;
    final secrets = _secrets.value;
    final segments = await _segmentIndex.loadSegments();
    final pending =
        segments
            .where(
              (segment) =>
                  segment.localPath != null &&
                  (segment.uploadStatus == SegmentUploadStatus.pending ||
                      segment.uploadStatus == SegmentUploadStatus.uploading ||
                      segment.uploadStatus == SegmentUploadStatus.failed),
            )
            .toList()
          ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    final useBackend = _backendClient.canUseBackend(config, secrets);
    if (!useBackend && config.cloudProvider != CloudProvider.s3) {
      final message =
          '${config.cloudProvider.label} requires the sound recorder backend URL and device token.';
      _diagnostics.add(message);
      if (pending.isNotEmpty) {
        _message.add(message);
      }
      return;
    }
    if (!useBackend && (!config.s3TargetReady || !secrets.hasS3Credentials)) {
      const message =
          'S3 bucket, region, access key, and secret key are required before uploads can run.';
      _diagnostics.add(message);
      if (pending.isNotEmpty) {
        _message.add(message);
      }
      return;
    }
    _isUploading.add(true);
    try {
      for (final segment in pending) {
        final localPath = segment.localPath;
        if (localPath == null) {
          continue;
        }
        var uploading = segment.copyWith(
          uploadStatus: SegmentUploadStatus.uploading,
          error: null,
        );
        await _replaceSegment(uploading);
        late final UploadResult result;
        try {
          if (useBackend) {
            final backendResult = await _uploadViaBackend(
              config: config,
              secrets: secrets,
              segment: uploading,
              file: File(localPath),
            );
            result = backendResult.isSuccess
                ? UploadResult.success(backendResult.remoteKey!)
                : UploadResult.failure(backendResult.error);
          } else {
            result = await _s3StorageClient.uploadSegment(
              config: config,
              secrets: secrets,
              segment: uploading,
              file: File(localPath),
            );
          }
        } catch (error) {
          result = UploadResult.failure('Upload failed: $error');
        }
        final updated = result.isSuccess
            ? uploading.copyWith(
                uploadStatus: SegmentUploadStatus.uploaded,
                remoteKey: result.remoteKey,
                uploadedAtUtc: DateTime.now().toUtc(),
                error: null,
              )
            : uploading.copyWith(
                uploadStatus: SegmentUploadStatus.failed,
                error: result.error,
              );
        await _replaceSegment(updated);
      }
      _message.add(
        pending.isEmpty ? 'No pending uploads.' : 'Upload queue drained.',
      );
      await _flushPendingAlerts();
      await _enforceRetention();
      // Mirror freshly uploaded segments into the user's iCloud (no-op unless
      // iCloud is the selected provider).
      unawaited(syncIcloudBackups());
    } catch (error) {
      _message.add('Upload queue failed: $error');
    } finally {
      _isUploading.add(false);
    }
  }

  Future<void> _replaceSegment(RecordingSegment segment) async {
    final segments = [..._segments.value];
    final index = segments.indexWhere((item) => item.id == segment.id);
    if (index == -1) {
      segments.add(segment);
    } else {
      segments[index] = segment;
    }
    segments.sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    await _segmentIndex.saveSegments(segments);
    _segments.add(segments);
  }

  Future<BackendUploadResult> _uploadViaBackend({
    required AppConfig config,
    required CloudSecrets secrets,
    required RecordingSegment segment,
    required File file,
  }) async {
    var session = _backendSession;
    if (session == null || !session.isUsable) {
      session = await _backendClient.createUploadSession(
        config: config,
        secrets: secrets,
      );
      _backendSession = session;
      _backendSessionKey = _sessionKey(config, secrets);
    }
    var result = await _backendClient.uploadSegment(
      config: config,
      secrets: secrets,
      session: session,
      segment: segment,
      file: file,
    );
    if (!result.isSuccess && result.error?.contains('expired') == true) {
      session = await _backendClient.createUploadSession(
        config: config,
        secrets: secrets,
      );
      _backendSession = session;
      _backendSessionKey = _sessionKey(config, secrets);
      result = await _backendClient.uploadSegment(
        config: config,
        secrets: secrets,
        session: session,
        segment: segment,
        file: file,
      );
    }
    if (result.session != null) {
      _backendSession = result.session;
      _backendSessionKey = _sessionKey(config, secrets);
    }
    return result;
  }

  Future<void> _saveRangeViaS3({
    required AppConfig config,
    required CloudSecrets secrets,
    required List<RecordingSegment> segments,
  }) async {
    var saved = 0;
    var failed = 0;
    for (final segment in segments) {
      final localPath = segment.localPath;
      final result = await _s3StorageClient.saveSegmentPermanently(
        config: config,
        secrets: secrets,
        segment: segment,
        file: localPath == null ? null : File(localPath),
      );
      if (result.isSuccess) {
        saved += 1;
        await _replaceSegment(
          segment.copyWith(
            permanentRemoteKey: result.remoteKey,
            permanentSavedAtUtc: DateTime.now().toUtc(),
            permanentError: null,
          ),
        );
      } else {
        failed += 1;
        await _replaceSegment(segment.copyWith(permanentError: result.error));
      }
    }
    _message.add(_permanentSaveSummary(saved: saved, failed: failed));
  }

  Future<void> _saveRangeViaBackend({
    required AppConfig config,
    required CloudSecrets secrets,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required List<RecordingSegment> segments,
  }) async {
    final prepared = <RecordingSegment>[];
    var failed = 0;
    for (final segment in segments) {
      var current = segment;
      if (current.remoteKey == null || current.remoteKey!.trim().isEmpty) {
        final localPath = current.localPath;
        if (localPath == null || localPath.trim().isEmpty) {
          failed += 1;
          await _replaceSegment(
            current.copyWith(
              permanentError:
                  'Segment is not available locally or in cloud storage.',
            ),
          );
          continue;
        }
        final uploadResult = await _uploadViaBackend(
          config: config,
          secrets: secrets,
          segment: current,
          file: File(localPath),
        );
        if (!uploadResult.isSuccess) {
          failed += 1;
          await _replaceSegment(
            current.copyWith(
              uploadStatus: SegmentUploadStatus.failed,
              error: uploadResult.error,
              permanentError: uploadResult.error,
            ),
          );
          continue;
        }
        current = current.copyWith(
          uploadStatus: SegmentUploadStatus.uploaded,
          remoteKey: uploadResult.remoteKey,
          uploadedAtUtc: DateTime.now().toUtc(),
          error: null,
        );
        await _replaceSegment(current);
      }
      prepared.add(current);
    }
    if (prepared.isEmpty) {
      _message.add(_permanentSaveSummary(saved: 0, failed: failed));
      return;
    }
    final result = await _backendClient.saveSegmentsPermanently(
      config: config,
      secrets: secrets,
      rangeStartedAtUtc: rangeStart,
      rangeEndedAtUtc: rangeEnd,
      segments: prepared,
    );
    if (!result.isSuccess) {
      for (final segment in prepared) {
        await _replaceSegment(segment.copyWith(permanentError: result.error));
      }
      _message.add(
        _permanentSaveSummary(saved: 0, failed: failed + prepared.length),
      );
      return;
    }
    var saved = 0;
    for (final segment in prepared) {
      final permanentKey = result.remoteKeysBySegmentId[segment.id];
      if (permanentKey == null || permanentKey.trim().isEmpty) {
        failed += 1;
        await _replaceSegment(
          segment.copyWith(
            permanentError: 'Permanent save did not return a storage key.',
          ),
        );
        continue;
      }
      saved += 1;
      await _replaceSegment(
        segment.copyWith(
          permanentRemoteKey: permanentKey,
          permanentSavedAtUtc: DateTime.now().toUtc(),
          permanentError: null,
        ),
      );
    }
    _message.add(_permanentSaveSummary(saved: saved, failed: failed));
  }

  /// Handles one acoustic detection from the FFT engine: optionally enriches it
  /// (ShazamKit song id, cloud STT keyword scan), surfaces it in the UI, and
  /// stores it to Supabase. Errors are logged, never thrown to the stream.
  Future<void> _onDetection(AcousticDetection detection) async {
    if (!_config.hasValue) {
      return;
    }
    // Self-contained: this runs fire-and-forget off a broadcast stream, so it
    // must never let an error escape (it would become an unhandled async error).
    try {
      final config = _config.value;
      var enriched = detection;

      // Music → ShazamKit (iOS only, opt-in).
      if (detection.kind == AcousticDetectionKind.music &&
          config.shazamEnabled &&
          _shazamClient.isSupported) {
        final clip = _recorder.recentAudio(window: const Duration(seconds: 5));
        if (clip != null) {
          try {
            final match = await _shazamClient.identify(
              pcm16: clip.bytes,
              sampleRate: clip.sampleRate,
              channels: clip.channels,
            );
            if (match != null) {
              enriched = detection.copyWith(
                details: {...detection.details, ...match.toDetails()},
              );
            }
          } catch (error) {
            _diagnostics.add('Shazam match failed: $error');
          }
        }
      }

      // Speech → keyword scan. Transcription runs on-device by default (audio
      // stays in the local plaintext window); cloud STT is only an explicit
      // opt-in.
      if (detection.kind == AcousticDetectionKind.speech &&
          config.keywords.isNotEmpty) {
        await _scanSpeechForKeywords(config, detection);
      }

      if (_isSleepCycleDetection(enriched)) {
        enriched = await _enrichSleepDetection(config, enriched);
        await _recordSleepCycleObservation(enriched);
      }
      if (enriched.kind == AcousticDetectionKind.sleepCycleAlarm &&
          config.sleepCycleAlarmsEnabled) {
        await _localNotifications.showSleepCycleAlarm(enriched);
      }

      _appendDetection(enriched);
      await _storeDetections([enriched]);
    } catch (error) {
      _diagnostics.add('Acoustic detection handling failed: $error');
    }
  }

  bool _isSleepCycleDetection(AcousticDetection detection) {
    return detection.kind == AcousticDetectionKind.sleepCycle ||
        detection.kind == AcousticDetectionKind.sleepCycleAlarm;
  }

  Future<AcousticDetection> _enrichSleepDetection(
    AppConfig config,
    AcousticDetection detection,
  ) async {
    final details = {...detection.details};
    SleepSensorSnapshot? sensor;
    if (config.sleepMotionSensorConsent || config.sleepAmbientLightConsent) {
      try {
        sensor = await _sleepSensorService.sample(
          motionConsent: config.sleepMotionSensorConsent,
          ambientLightConsent: config.sleepAmbientLightConsent,
        );
      } catch (error) {
        _diagnostics.add('Sleep sensor sample failed: $error');
      }
    }
    final signalValues = sensor?.toSignalValues();
    final transfer = _transfer.valueOrNull;
    final bedtimeScore = config.sleepPhoneContextConsent
        ? _usualBedtimeScore(detection.endedAtUtc.toLocal())
        : null;
    final estimate = _sleepProbabilityModel.estimate(
      sample: SleepSignalSample(
        acousticSleepScore: _detailDouble(details['sleepScore']),
        acousticArousalScore: _detailDouble(details['arousalScore']),
        motionStillnessScore: signalValues?.motionStillnessScore,
        ambientLux: signalValues?.ambientLux,
        isCharging: config.sleepPhoneContextConsent
            ? transfer?.isCharging
            : null,
        usualBedtimeScore: bedtimeScore,
      ),
      consent: SleepSignalConsent(
        audio: true,
        motion: config.sleepMotionSensorConsent,
        ambientLight: config.sleepAmbientLightConsent,
        phoneContext: config.sleepPhoneContextConsent,
      ),
    );
    if (sensor != null) {
      if (sensor.motionAvailable && sensor.motionStillnessScore != null) {
        details['motionStillnessScore'] = _round2(sensor.motionStillnessScore!);
      }
      if (sensor.ambientLightAvailable && sensor.ambientLux != null) {
        details['ambientLux'] = _round2(sensor.ambientLux!);
      }
      if (sensor.screenBrightness != null) {
        details['screenBrightness'] = _round2(sensor.screenBrightness!);
      }
    }
    if (config.sleepPhoneContextConsent) {
      details['phoneCharging'] = transfer?.isCharging;
      if (bedtimeScore != null) {
        details['usualBedtimeScore'] = _round2(bedtimeScore);
      }
    }
    details['sleepProbability'] = _round2(estimate.sleepProbability);
    details['wakeProbability'] = _round2(estimate.wakeProbability);
    details['probabilitySignals'] = estimate.activeSignals;
    return detection.copyWith(details: details);
  }

  double? _detailDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  double _usualBedtimeScore(DateTime local) {
    final hour = local.hour + local.minute / 60.0;
    if (hour >= 22 || hour < 6) {
      return 1.0;
    }
    if (hour >= 20 && hour < 22) {
      return (hour - 20) / 2.0;
    }
    if (hour >= 6 && hour < 8) {
      return 1.0 - (hour - 6) / 2.0;
    }
    return 0.0;
  }

  double _round2(double value) => double.parse(value.toStringAsFixed(2));

  Future<void> _recordSleepCycleObservation(AcousticDetection detection) async {
    final observation = SleepCycleObservation.fromDetection(detection);
    if (observation == null) {
      return;
    }
    _sleepCycleProfile = _sleepCycleProfile.addObservation(observation);
    await _settingsStore.saveSleepCycleProfile(_sleepCycleProfile);
    final current = _config.valueOrNull;
    if (current == null) {
      return;
    }
    final maxCycles = current.sleepCycleMinutesByIndex.length < 6
        ? 6
        : current.sleepCycleMinutesByIndex.length;
    final seeds = _sleepCycleProfile.cycleMinuteSeeds(maxCycles: maxCycles);
    _config.add(current.copyWith(sleepCycleMinutesByIndex: seeds));
  }

  Future<void> _scanSpeechForKeywords(
    AppConfig config,
    AcousticDetection speech,
  ) async {
    final clip = _recorder.recentAudio(window: const Duration(seconds: 6));
    if (clip == null) {
      return;
    }
    try {
      String? transcript;
      // 1) On-device transcription — the default. Audio never leaves the phone.
      if (await _onDeviceSpeechClient.isAvailable()) {
        transcript = await _onDeviceSpeechClient.transcribe(
          pcm16: clip.bytes,
          sampleRate: clip.sampleRate,
          channels: clip.channels,
        );
      }
      // 2) Cloud STT — explicit opt-in only; this is the one path that sends
      // audio off-device, and it runs solely when the user has enabled it.
      if (transcript == null && _speechToTextClient.canTranscribe(config)) {
        transcript = await _speechToTextClient.transcribe(
          config: config,
          secrets: _secrets.valueOrNull ?? const CloudSecrets(),
          pcm16: clip.bytes,
          sampleRate: clip.sampleRate,
          channels: clip.channels,
        );
      }
      if (transcript == null) {
        return;
      }
      final match = _speechToTextClient.matchKeyword(config, transcript);
      if (match == null) {
        return;
      }
      final keywordEvent = AcousticDetection(
        kind: AcousticDetectionKind.keyword,
        startedAtUtc: speech.startedAtUtc,
        endedAtUtc: speech.endedAtUtc,
        confidence: 1.0,
        captureSessionId: speech.captureSessionId,
        details: {'keyword': match.keyword, 'transcript': match.transcript},
      );
      _appendDetection(keywordEvent);
      await _storeDetections([keywordEvent]);
      // Reuse the existing magic-phrase alert/email path.
      await _sendAlertForEvent(
        AudioTriggerEvent(
          type: AudioTriggerType.magicPhrase,
          occurredAtUtc: speech.startedAtUtc,
          captureSessionId: speech.captureSessionId,
          sampleIndex: 0,
          phrase: match.keyword,
        ),
      );
    } catch (error) {
      _diagnostics.add('Speech-to-text scan failed: $error');
    }
  }

  void _appendDetection(AcousticDetection detection) {
    if (_detectionsList.isClosed) {
      return;
    }
    final next = [detection, ..._detectionsList.value];
    if (next.length > _maxDetectionsKept) {
      next.removeRange(_maxDetectionsKept, next.length);
    }
    _detectionsList.add(next);
  }

  /// Detail keys never written to the cloud — raw recognized speech is sensitive
  /// and stays on-device (used only for the local alert), so it is stripped
  /// before any row leaves the device.
  static const Set<String> _redactedDetailKeys = {'transcript'};

  /// Persists detections to Supabase under the signed-in user (RLS-scoped).
  /// No-ops silently when Supabase is unconfigured or there is no session.
  /// Sensitive detail fields are redacted before upload.
  Future<void> _storeDetections(List<AcousticDetection> detections) async {
    if (detections.isEmpty || !_config.hasValue || !_secrets.hasValue) {
      return;
    }
    if (!_supabaseRestClient.canInsert(_config.value, _secrets.value)) {
      return;
    }
    final redacted = detections.map((d) {
      if (d.details.keys.any(_redactedDetailKeys.contains)) {
        final clean = {...d.details}
          ..removeWhere((k, _) => _redactedDetailKeys.contains(k));
        return d.copyWith(details: clean);
      }
      return d;
    }).toList();
    await _ensureFreshSupabaseToken();
    final error = await _supabaseRestClient.insertDetections(
      config: _config.value,
      secrets: _secrets.value,
      detections: redacted,
    );
    if (error != null) {
      _diagnostics.add('Acoustic event store: $error');
    }
  }

  Future<void> _sendAlertForEvent(
    AudioTriggerEvent event, {
    bool userVisible = false,
  }) async {
    if (!_config.hasValue || !_secrets.hasValue) {
      return;
    }
    await _ensureFreshSupabaseToken();
    final config = _config.value;
    final secrets = _secrets.value;
    if (!_backendClient.canUseBackend(config, secrets)) {
      if (userVisible) {
        _message.add(
          'Backend URL and device token are required before alert emails can be sent.',
        );
      }
      return;
    }
    final segments = _alertReadySegments(event);
    if (segments.isEmpty) {
      await _queueAlert(event);
      requestUploadDrain();
      if (userVisible) {
        _message.add('Alert queued until matching audio is uploaded.');
      }
      return;
    }
    final segment = segments.isEmpty ? null : segments.last;
    final error = await _backendClient.postAlert(
      config: config,
      secrets: secrets,
      trigger: event.serverTrigger,
      occurredAtUtc: event.occurredAtUtc,
      segmentId: segment?.id,
      sequence: segment?.sequence,
      metadata: event.metadata,
    );
    if (error != null) {
      if (userVisible || event.type != AudioTriggerType.commotion) {
        _message.add(error);
      }
      return;
    }
    _pendingAlertEvents.remove(event);
    await _persistPendingAlerts();
    if (userVisible) {
      _message.add('Alert email requested.');
    }
  }

  List<RecordingSegment> _alertReadySegments(AudioTriggerEvent event) {
    final listenFrom = event.occurredAtUtc.subtract(
      const Duration(seconds: 20),
    );
    final listenTo = event.occurredAtUtc.add(const Duration(seconds: 90));
    final segments =
        _segments.value
            .where(
              (segment) =>
                  segment.uploadStatus == SegmentUploadStatus.uploaded &&
                  segment.remoteKey != null &&
                  segment.endedAtUtc.isAfter(listenFrom) &&
                  segment.startedAtUtc.isBefore(listenTo),
            )
            .toList()
          ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    return segments;
  }

  Future<void> _queueAlert(AudioTriggerEvent event) async {
    final alreadyQueued = _pendingAlertEvents.any(
      (queued) =>
          queued.type == event.type &&
          queued.occurredAtUtc == event.occurredAtUtc &&
          queued.sampleIndex == event.sampleIndex,
    );
    if (!alreadyQueued) {
      _pendingAlertEvents.add(event);
    }
    if (_pendingAlertEvents.length > 20) {
      _pendingAlertEvents.removeRange(0, _pendingAlertEvents.length - 20);
    }
    await _persistPendingAlerts();
  }

  Future<void> _persistPendingAlerts() async {
    await _settingsStore.savePendingAlerts(_pendingAlertEvents);
  }

  Future<void> _flushPendingAlerts() async {
    if (_pendingAlertEvents.isEmpty) {
      return;
    }
    final pending = [..._pendingAlertEvents];
    for (final event in pending) {
      if (_alertReadySegments(event).isNotEmpty) {
        await _sendAlertForEvent(event);
      }
    }
  }

  String? _sessionKey(AppConfig? config, CloudSecrets? secrets) {
    if (config == null || secrets == null) {
      return null;
    }
    if (!_backendClient.canUseBackend(config, secrets)) {
      return null;
    }
    return '${config.backendBaseUrl.trim()}|${secrets.backendDeviceToken.trim()}';
  }

  String _permanentSaveSummary({required int saved, required int failed}) {
    if (saved > 0) {
      unawaited(_feedback.say('Saved'));
    }
    if (saved > 0 && failed == 0) {
      return 'Permanently saved $saved segment${saved == 1 ? '' : 's'}.';
    }
    if (saved > 0) {
      return 'Permanently saved $saved segment${saved == 1 ? '' : 's'}; $failed failed.';
    }
    return 'Permanent save failed for $failed segment${failed == 1 ? '' : 's'}.';
  }

  Future<void> _enforceRetention() async {
    if (!_config.hasValue || !_secrets.hasValue) {
      return;
    }
    final config = _config.value;
    final now = DateTime.now().toUtc();
    var segments = await _segmentIndex.enforceDeviceRetention(
      segments: await _segmentIndex.loadSegments(),
      cutoffUtc: now.subtract(Duration(hours: config.deviceRetentionHours)),
    );
    if (!_backendClient.canUseBackend(config, _secrets.value) &&
        config.cloudProvider == CloudProvider.s3 &&
        config.s3TargetReady &&
        _secrets.value.hasS3Credentials) {
      final cutoffUtc = now.subtract(
        Duration(hours: config.cloudRetentionHours),
      );
      final next = <RecordingSegment>[];
      for (final segment in segments) {
        if (segment.remoteKey != null &&
            segment.endedAtUtc.isBefore(cutoffUtc)) {
          final error = await _s3StorageClient.deleteSegmentObjects(
            config: config,
            secrets: _secrets.value,
            audioKey: segment.remoteKey!,
          );
          if (error == null) {
            next.add(
              segment.copyWith(
                remoteKey: null,
                uploadedAtUtc: null,
                uploadStatus: SegmentUploadStatus.localOnly,
              ),
            );
          } else {
            next.add(segment.copyWith(error: error));
          }
        } else {
          next.add(segment);
        }
      }
      segments = await _segmentIndex.dropCloudExpiredRecords(
        segments: next,
        cutoffUtc: cutoffUtc,
      );
    }
    _segments.add(segments);
  }
}
