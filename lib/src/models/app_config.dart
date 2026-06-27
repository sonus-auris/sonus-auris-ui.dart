// ignore_for_file: prefer_initializing_formals

import 'cloud_provider.dart';
import 'context_trigger.dart';
import 'recording_schedule.dart';
import 'upload_network_policy.dart';

class AppConfig {
  const AppConfig({
    required this.deviceId,
    this.deviceRetentionHours = 50,
    this.cloudRetentionHours = 500,
    this.segmentMinutes = 1,
    this.overlapSeconds = 2,
    this.bitRate = 64000,
    this.sampleRate = 16000,
    this.channels = 1,
    this.uploadEnabled = false,
    this.cloudProvider = CloudProvider.s3,
    this.backendBaseUrl = '',
    this.s3Bucket = '',
    this.s3Region = 'us-east-1',
    this.s3Prefix = 'audio-dashcam',
    this.s3Endpoint = '',
    this.supabaseUrl = '',
    this.supabaseAnonKey = '',
    this.useCase = 'security',
    this.micSensitivity = 1.0,
    this.noiseTriggerSensitivity = 0.5,
    this.bassGainDb = 0.0,
    this.midGainDb = 0.0,
    this.trebleGainDb = 0.0,
    this.autoGain = true,
    this.noiseSuppress = true,
    this.verbalCuesEnabled = false,
    this.autoStartCaptureEnabled = false,
    this.locationTaggingEnabled = false,
    this.soundCloudDailyArchive = false,
    this.spotifyAutoPlaylist = false,
    this.placeNamesEnabled = false,
    this.pauseUploadsOnLowBattery = true,
    this.lowBatteryThresholdPercent = 20,
    this.uploadNetworkPolicy = UploadNetworkPolicy.any,
    this.acousticAnalysisEnabled = false,
    this.spectralSidecarEnabled = true,
    this.analysisActivationDb = -40.0,
    this.analysisSustainSeconds = 2.0,
    this.analysisHoldSeconds = 45.0,
    this.snoreDetectionEnabled = true,
    this.musicDetectionEnabled = true,
    this.speechDetectionEnabled = true,
    this.sleepSmartAlarmEnabled = true,
    this.sleepDefaultCycleMinutes = 90.0,
    this.sleepTargetCycle = 5,
    this.sleepBackstopCycle = 6,
    this.sleepSmartWindowMinutes = 25.0,
    this.sleepMotionConsent = false,
    this.sleepLightConsent = false,
    this.shazamEnabled = false,
    this.keywords = const [],
    this.sttEnabled = false,
    this.sttEndpoint = '',
    this.adaptiveQualityEnabled = false,
    this.captureSampleRate = 48000,
    this.quietSampleRate = 16000,
    this.adaptiveLoudnessDb = -40.0,
    this.contextTriggersEnabled = false,
    this.contextTriggerKinds = const [],
    this.contextTriggerCooldownSeconds = 300,
    RecordingSchedule? recordingSchedule,
  }) : _recordingSchedule = recordingSchedule;

  /// Capture intents understood by both the app and the backend. Music turns off
  /// the speech-oriented DSP so dynamics and frequency content are preserved.
  static const List<String> supportedUseCases = [
    'security',
    'music',
    'meeting',
    'voice_note',
    'ambient',
  ];

  final String deviceId;
  final int deviceRetentionHours;
  final int cloudRetentionHours;
  final int segmentMinutes;
  final int overlapSeconds;
  final int bitRate;
  final int sampleRate;
  final int channels;
  final bool uploadEnabled;
  final CloudProvider cloudProvider;
  final String backendBaseUrl;
  final String s3Bucket;
  final String s3Region;
  final String s3Prefix;
  final String s3Endpoint;

  /// Supabase project URL (e.g. https://abc.supabase.co). Used for GoTrue
  /// email/password sign-in. Non-secret.
  final String supabaseUrl;

  /// Supabase anon/publishable API key. Safe to ship in the client; never the
  /// service_role or secret key.
  final String supabaseAnonKey;

  /// One of [supportedUseCases].
  final String useCase;

  /// Linear input gain applied to captured PCM (0.25x..4x). 1.0 is unity.
  final double micSensitivity;

  /// Loudness-trigger sensitivity in 0..1; higher fires the "commotion" alert on
  /// quieter sound. Maps to RMS/peak thresholds in the recorder.
  final double noiseTriggerSensitivity;

  /// Tone controls in dB (-12..+12) applied as low/mid/high shelving+peak gain.
  final double bassGainDb;
  final double midGainDb;
  final double trebleGainDb;

  /// Platform auto-gain control. Off by default for music to keep dynamics.
  final bool autoGain;

  /// Platform noise suppression. Off by default for music.
  final bool noiseSuppress;

  /// Speak short confirmations ("recording", "saved") while capturing.
  final bool verbalCuesEnabled;

  /// "Always-on": after the user enables it once, capture starts automatically
  /// whenever the app launches (including the relaunch the boot receiver triggers
  /// after a reboot), so they never have to press Start again. Off by default.
  final bool autoStartCaptureEnabled;

  /// Opt-in GPS evidence tagging: stamp each segment with the capture location
  /// so a clip can prove where it was recorded. Off by default; requires the
  /// user to grant location permission.
  final bool locationTaggingEnabled;

  /// When SoundCloud is linked and this is on, each day is published to the
  /// user's SoundCloud as a private "Day of My Life" track (24h + AI notes),
  /// keeping a rolling last-100-days window. Off by default.
  final bool soundCloudDailyArchive;

  /// When Spotify is linked and this is on, songs recognised in a saved clip are
  /// added to a private "Sonus Auris Memories" playlist. Off by default.
  final bool spotifyAutoPlaylist;

  /// When on, "Drive" notes in a Day of My Life are enriched with a place name
  /// via reverse geocoding. This sends coordinates to the platform geocoder, so
  /// it is opt-in and off by default. Requires [locationTaggingEnabled].
  final bool placeNamesEnabled;

  /// When true, pause cloud uploads while the battery is below
  /// [lowBatteryThresholdPercent] and the device is not charging. Local capture
  /// of the rolling window is never affected — deferred segments stay on device
  /// and upload catches up once the battery recovers (or charging starts).
  final bool pauseUploadsOnLowBattery;

  /// Battery percentage (1..100) under which uploads are paused when
  /// [pauseUploadsOnLowBattery] is on.
  final int lowBatteryThresholdPercent;

  /// Which network transports uploads may use. Local capture is unaffected.
  final UploadNetworkPolicy uploadNetworkPolicy;

  /// Master switch for the on-device FFT acoustic-intelligence engine. When off,
  /// no spectral analysis runs and nothing is fed to the analyzer isolate.
  final bool acousticAnalysisEnabled;

  /// When on, every finalized rolling segment also gets a time-aligned spectral
  /// feature sidecar (`<stem>.features.json`) written next to its WAV — an FFT
  /// decomposition track parallel to the audio. Independent of the loudness-gated
  /// [acousticAnalysisEnabled] detection engine.
  final bool spectralSidecarEnabled;

  /// The analysis engine stays idle until the input is sustained at or above
  /// [analysisActivationDb] (dBFS) for [analysisSustainSeconds]. This is the
  /// "kick in once decibels get consistently high" gate.
  final double analysisActivationDb;
  final double analysisSustainSeconds;

  /// Once active, the engine keeps analyzing through quiet stretches for this
  /// long before going idle again, so gaps between snores (and apnea pauses)
  /// are observed rather than missed.
  final double analysisHoldSeconds;

  /// Per-detector toggles for the analysis engine.
  final bool snoreDetectionEnabled;
  final bool musicDetectionEnabled;
  final bool speechDetectionEnabled;

  /// Arm cycle-aware "smart" alarms during a sleep session. When on, the app
  /// wakes the sleeper at a light-sleep arousal near the end of [sleepTargetCycle]
  /// (defaults to the 5th cycle ≈ 7.5 h), but never while in deep sleep — it
  /// holds off and waits for the next light arousal, with a hard backstop at the
  /// end of [sleepBackstopCycle] (defaults to the 6th cycle ≈ 9 h).
  final bool sleepSmartAlarmEnabled;

  /// Cold-start cycle length (minutes) used before any per-user history exists.
  /// 90 min × 5 cycles = 7.5 h; × 6 = 9 h.
  final double sleepDefaultCycleMinutes;

  /// 1-based cycle whose end the smart alarm primarily targets (default 5).
  final int sleepTargetCycle;

  /// 1-based cycle whose end is the hard backstop wake (default 6).
  final int sleepBackstopCycle;

  /// How many minutes before the target-cycle end the smart alarm may fire early
  /// if a light-sleep arousal is detected (the "wake during light sleep" window).
  final double sleepSmartWindowMinutes;

  /// Express consent to use the accelerometer during a sleep session: stillness,
  /// tossing/turning, and getting up improve stage/cycle accuracy. Off until the
  /// user explicitly opts in.
  final bool sleepMotionConsent;

  /// Express consent to use the ambient-light sensor (darkness duration, lights
  /// off/on, dawn brightening) as a sleep/wake cue. Off until explicit opt-in.
  /// Android only — iOS exposes no public ambient-light API.
  final bool sleepLightConsent;

  /// When a music detection fires on iOS, identify the song with ShazamKit.
  /// No-op on Android. Sends a short audio fingerprint to Apple's service.
  final bool shazamEnabled;

  /// Keywords to watch for in transcribed speech (case-insensitive). A match
  /// raises a magic-phrase alert. Only consulted when [sttEnabled].
  final List<String> keywords;

  /// Opt-in cloud speech-to-text. When on, short clips of sustained speech are
  /// POSTed to [sttEndpoint] to scan for [keywords]. Off by default; audio only
  /// leaves the device while this is enabled.
  final bool sttEnabled;
  final String sttEndpoint;

  /// Adaptive recording quality: capture at [captureSampleRate] always (so the
  /// FFT engine and sample continuity are preserved) but store *quiet* segments
  /// downsampled to [quietSampleRate]. Loud segments keep full quality. A
  /// segment is "loud" when its trailing RMS is at or above [adaptiveLoudnessDb].
  final bool adaptiveQualityEnabled;
  final int captureSampleRate;
  final int quietSampleRate;
  final double adaptiveLoudnessDb;

  /// Opt-in weekly recording schedule. When [RecordingSchedule.enabled], capture
  /// starts/stops at the day/time windows the user drew in the Configure tab,
  /// enforced both in-app and via OS-level alarms/notifications. Stored nullable
  /// so the const constructor stays const; read through [recordingSchedule].
  final RecordingSchedule? _recordingSchedule;

  RecordingSchedule get recordingSchedule =>
      _recordingSchedule ?? RecordingSchedule.defaultSchedule();

  /// Master switch for context triggers: meaningful events (Bluetooth, Wi-Fi /
  /// network changes, nearby devices) prompt for consent to start recording —
  /// but only while idle and inside an active [recordingSchedule] window.
  final bool contextTriggersEnabled;

  /// Which [ContextTriggerKind]s are armed, by wire name. Open-ended so new
  /// sensors can be added without a schema change.
  final List<String> contextTriggerKinds;

  /// Minimum gap between two context-trigger consent prompts, so a flurry of
  /// connectivity events doesn't nag repeatedly.
  final int contextTriggerCooldownSeconds;

  Set<ContextTriggerKind> get contextTriggerKindSet =>
      ContextTriggerKind.setFromWire(contextTriggerKinds);

  /// Whether any context trigger is actually armed.
  bool get hasContextTriggers =>
      contextTriggersEnabled && contextTriggerKindSet.isNotEmpty;

  bool get isMusic => useCase == 'music';

  /// The sample rate the microphone stream actually opens at. Adaptive quality
  /// forces the high [captureSampleRate]; otherwise the plain [sampleRate].
  int get effectiveCaptureSampleRate =>
      adaptiveQualityEnabled ? captureSampleRate : sampleRate;

  /// Integer decimation factor from the capture rate down to ~16 kHz analysis.
  int get analyzerDecimationFactor {
    final ratio = (effectiveCaptureSampleRate / 16000).round();
    return ratio < 1 ? 1 : ratio;
  }

  /// Actual sample rate the analyzer sees after decimation.
  int get analyzerSampleRate =>
      effectiveCaptureSampleRate ~/ analyzerDecimationFactor;

  /// FFT window size used by the analysis engine.
  int get analyzerFftSize => 2048;

  /// Whether any spectral analysis should run at all.
  bool get hasAcousticAnalysis =>
      acousticAnalysisEnabled &&
      (snoreDetectionEnabled ||
          musicDetectionEnabled ||
          speechDetectionEnabled);

  /// Samples per segment / overlap at an arbitrary capture rate (the recorder
  /// runs at [effectiveCaptureSampleRate], which may differ from [sampleRate]).
  int samplesPerSegmentAt(int rate) =>
      rate * segmentDuration.inSeconds.clamp(1, 86400);

  int overlapSamplesAt(int rate) {
    final requested = rate * overlapSeconds.clamp(0, 30);
    return requested.clamp(0, samplesPerSegmentAt(rate) ~/ 2);
  }

  bool get hasToneAdjustment =>
      bassGainDb != 0.0 || midGainDb != 0.0 || trebleGainDb != 0.0;

  /// Whether any client-side DSP must run on the PCM stream.
  bool get hasAudioDsp => micSensitivity != 1.0 || hasToneAdjustment;

  /// Snapshot of the audio tuning, mirrored to the backend session so playback
  /// and audit can reproduce the capture configuration.
  Map<String, Object?> get audioProfile => {
    'useCase': useCase,
    'micSensitivity': micSensitivity,
    'noiseTriggerSensitivity': noiseTriggerSensitivity,
    'bassGainDb': bassGainDb,
    'midGainDb': midGainDb,
    'trebleGainDb': trebleGainDb,
    'autoGain': autoGain,
    'noiseSuppress': noiseSuppress,
  };

  bool get s3TargetReady =>
      s3Bucket.trim().isNotEmpty && s3Region.trim().isNotEmpty;

  /// Whether Supabase email/password sign-in can be attempted.
  bool get hasSupabaseAuthConfig =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

  Duration get segmentDuration => Duration(minutes: segmentMinutes);

  int get bitsPerSample => 16;

  int get pcmBitRate => sampleRate * channels * bitsPerSample;

  int get effectiveBitRate => pcmBitRate;

  int get samplesPerSegment =>
      sampleRate * segmentDuration.inSeconds.clamp(1, 86400);

  int get overlapSamples {
    final requested = sampleRate * overlapSeconds.clamp(0, 30);
    return requested.clamp(0, samplesPerSegment ~/ 2);
  }

  AppConfig copyWith({
    String? deviceId,
    int? deviceRetentionHours,
    int? cloudRetentionHours,
    int? segmentMinutes,
    int? overlapSeconds,
    int? bitRate,
    int? sampleRate,
    int? channels,
    bool? uploadEnabled,
    CloudProvider? cloudProvider,
    String? backendBaseUrl,
    String? s3Bucket,
    String? s3Region,
    String? s3Prefix,
    String? s3Endpoint,
    String? supabaseUrl,
    String? supabaseAnonKey,
    String? useCase,
    double? micSensitivity,
    double? noiseTriggerSensitivity,
    double? bassGainDb,
    double? midGainDb,
    double? trebleGainDb,
    bool? autoGain,
    bool? noiseSuppress,
    bool? verbalCuesEnabled,
    bool? autoStartCaptureEnabled,
    bool? locationTaggingEnabled,
    bool? soundCloudDailyArchive,
    bool? spotifyAutoPlaylist,
    bool? placeNamesEnabled,
    bool? pauseUploadsOnLowBattery,
    int? lowBatteryThresholdPercent,
    UploadNetworkPolicy? uploadNetworkPolicy,
    bool? acousticAnalysisEnabled,
    bool? spectralSidecarEnabled,
    double? analysisActivationDb,
    double? analysisSustainSeconds,
    double? analysisHoldSeconds,
    bool? snoreDetectionEnabled,
    bool? musicDetectionEnabled,
    bool? speechDetectionEnabled,
    bool? sleepSmartAlarmEnabled,
    double? sleepDefaultCycleMinutes,
    int? sleepTargetCycle,
    int? sleepBackstopCycle,
    double? sleepSmartWindowMinutes,
    bool? sleepMotionConsent,
    bool? sleepLightConsent,
    bool? shazamEnabled,
    List<String>? keywords,
    bool? sttEnabled,
    String? sttEndpoint,
    bool? adaptiveQualityEnabled,
    int? captureSampleRate,
    int? quietSampleRate,
    double? adaptiveLoudnessDb,
    bool? contextTriggersEnabled,
    List<String>? contextTriggerKinds,
    int? contextTriggerCooldownSeconds,
    RecordingSchedule? recordingSchedule,
  }) {
    return AppConfig(
      deviceId: deviceId ?? this.deviceId,
      deviceRetentionHours: deviceRetentionHours ?? this.deviceRetentionHours,
      cloudRetentionHours: cloudRetentionHours ?? this.cloudRetentionHours,
      segmentMinutes: segmentMinutes ?? this.segmentMinutes,
      overlapSeconds: overlapSeconds ?? this.overlapSeconds,
      bitRate: bitRate ?? this.bitRate,
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      uploadEnabled: uploadEnabled ?? this.uploadEnabled,
      cloudProvider: cloudProvider ?? this.cloudProvider,
      backendBaseUrl: backendBaseUrl ?? this.backendBaseUrl,
      s3Bucket: s3Bucket ?? this.s3Bucket,
      s3Region: s3Region ?? this.s3Region,
      s3Prefix: s3Prefix ?? this.s3Prefix,
      s3Endpoint: s3Endpoint ?? this.s3Endpoint,
      supabaseUrl: supabaseUrl ?? this.supabaseUrl,
      supabaseAnonKey: supabaseAnonKey ?? this.supabaseAnonKey,
      useCase: useCase ?? this.useCase,
      micSensitivity: micSensitivity ?? this.micSensitivity,
      noiseTriggerSensitivity:
          noiseTriggerSensitivity ?? this.noiseTriggerSensitivity,
      bassGainDb: bassGainDb ?? this.bassGainDb,
      midGainDb: midGainDb ?? this.midGainDb,
      trebleGainDb: trebleGainDb ?? this.trebleGainDb,
      autoGain: autoGain ?? this.autoGain,
      noiseSuppress: noiseSuppress ?? this.noiseSuppress,
      verbalCuesEnabled: verbalCuesEnabled ?? this.verbalCuesEnabled,
      autoStartCaptureEnabled:
          autoStartCaptureEnabled ?? this.autoStartCaptureEnabled,
      locationTaggingEnabled:
          locationTaggingEnabled ?? this.locationTaggingEnabled,
      soundCloudDailyArchive:
          soundCloudDailyArchive ?? this.soundCloudDailyArchive,
      spotifyAutoPlaylist: spotifyAutoPlaylist ?? this.spotifyAutoPlaylist,
      placeNamesEnabled: placeNamesEnabled ?? this.placeNamesEnabled,
      pauseUploadsOnLowBattery:
          pauseUploadsOnLowBattery ?? this.pauseUploadsOnLowBattery,
      lowBatteryThresholdPercent:
          lowBatteryThresholdPercent ?? this.lowBatteryThresholdPercent,
      uploadNetworkPolicy: uploadNetworkPolicy ?? this.uploadNetworkPolicy,
      acousticAnalysisEnabled:
          acousticAnalysisEnabled ?? this.acousticAnalysisEnabled,
      spectralSidecarEnabled:
          spectralSidecarEnabled ?? this.spectralSidecarEnabled,
      analysisActivationDb: analysisActivationDb ?? this.analysisActivationDb,
      analysisSustainSeconds:
          analysisSustainSeconds ?? this.analysisSustainSeconds,
      analysisHoldSeconds: analysisHoldSeconds ?? this.analysisHoldSeconds,
      snoreDetectionEnabled:
          snoreDetectionEnabled ?? this.snoreDetectionEnabled,
      musicDetectionEnabled:
          musicDetectionEnabled ?? this.musicDetectionEnabled,
      speechDetectionEnabled:
          speechDetectionEnabled ?? this.speechDetectionEnabled,
      sleepSmartAlarmEnabled:
          sleepSmartAlarmEnabled ?? this.sleepSmartAlarmEnabled,
      sleepDefaultCycleMinutes:
          sleepDefaultCycleMinutes ?? this.sleepDefaultCycleMinutes,
      sleepTargetCycle: sleepTargetCycle ?? this.sleepTargetCycle,
      sleepBackstopCycle: sleepBackstopCycle ?? this.sleepBackstopCycle,
      sleepSmartWindowMinutes:
          sleepSmartWindowMinutes ?? this.sleepSmartWindowMinutes,
      sleepMotionConsent: sleepMotionConsent ?? this.sleepMotionConsent,
      sleepLightConsent: sleepLightConsent ?? this.sleepLightConsent,
      shazamEnabled: shazamEnabled ?? this.shazamEnabled,
      keywords: keywords ?? this.keywords,
      sttEnabled: sttEnabled ?? this.sttEnabled,
      sttEndpoint: sttEndpoint ?? this.sttEndpoint,
      adaptiveQualityEnabled:
          adaptiveQualityEnabled ?? this.adaptiveQualityEnabled,
      captureSampleRate: captureSampleRate ?? this.captureSampleRate,
      quietSampleRate: quietSampleRate ?? this.quietSampleRate,
      adaptiveLoudnessDb: adaptiveLoudnessDb ?? this.adaptiveLoudnessDb,
      contextTriggersEnabled:
          contextTriggersEnabled ?? this.contextTriggersEnabled,
      contextTriggerKinds: contextTriggerKinds ?? this.contextTriggerKinds,
      contextTriggerCooldownSeconds:
          contextTriggerCooldownSeconds ?? this.contextTriggerCooldownSeconds,
      recordingSchedule: recordingSchedule ?? this.recordingSchedule,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'deviceRetentionHours': deviceRetentionHours,
      'cloudRetentionHours': cloudRetentionHours,
      'segmentMinutes': segmentMinutes,
      'overlapSeconds': overlapSeconds,
      'bitRate': bitRate,
      'sampleRate': sampleRate,
      'channels': channels,
      'uploadEnabled': uploadEnabled,
      'cloudProvider': cloudProvider.name,
      'backendBaseUrl': backendBaseUrl,
      's3Bucket': s3Bucket,
      's3Region': s3Region,
      's3Prefix': s3Prefix,
      's3Endpoint': s3Endpoint,
      'supabaseUrl': supabaseUrl,
      'supabaseAnonKey': supabaseAnonKey,
      'useCase': useCase,
      'micSensitivity': micSensitivity,
      'noiseTriggerSensitivity': noiseTriggerSensitivity,
      'bassGainDb': bassGainDb,
      'midGainDb': midGainDb,
      'trebleGainDb': trebleGainDb,
      'autoGain': autoGain,
      'noiseSuppress': noiseSuppress,
      'verbalCuesEnabled': verbalCuesEnabled,
      'autoStartCaptureEnabled': autoStartCaptureEnabled,
      'locationTaggingEnabled': locationTaggingEnabled,
      'soundCloudDailyArchive': soundCloudDailyArchive,
      'spotifyAutoPlaylist': spotifyAutoPlaylist,
      'placeNamesEnabled': placeNamesEnabled,
      'pauseUploadsOnLowBattery': pauseUploadsOnLowBattery,
      'lowBatteryThresholdPercent': lowBatteryThresholdPercent,
      'uploadNetworkPolicy': uploadNetworkPolicy.wireName,
      'acousticAnalysisEnabled': acousticAnalysisEnabled,
      'spectralSidecarEnabled': spectralSidecarEnabled,
      'analysisActivationDb': analysisActivationDb,
      'analysisSustainSeconds': analysisSustainSeconds,
      'analysisHoldSeconds': analysisHoldSeconds,
      'snoreDetectionEnabled': snoreDetectionEnabled,
      'musicDetectionEnabled': musicDetectionEnabled,
      'speechDetectionEnabled': speechDetectionEnabled,
      'sleepSmartAlarmEnabled': sleepSmartAlarmEnabled,
      'sleepDefaultCycleMinutes': sleepDefaultCycleMinutes,
      'sleepTargetCycle': sleepTargetCycle,
      'sleepBackstopCycle': sleepBackstopCycle,
      'sleepSmartWindowMinutes': sleepSmartWindowMinutes,
      'sleepMotionConsent': sleepMotionConsent,
      'sleepLightConsent': sleepLightConsent,
      'shazamEnabled': shazamEnabled,
      'keywords': keywords,
      'sttEnabled': sttEnabled,
      'sttEndpoint': sttEndpoint,
      'adaptiveQualityEnabled': adaptiveQualityEnabled,
      'captureSampleRate': captureSampleRate,
      'quietSampleRate': quietSampleRate,
      'adaptiveLoudnessDb': adaptiveLoudnessDb,
      'contextTriggersEnabled': contextTriggersEnabled,
      'contextTriggerKinds': contextTriggerKinds,
      'contextTriggerCooldownSeconds': contextTriggerCooldownSeconds,
      'recordingSchedule': recordingSchedule.toJson(),
    };
  }

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final useCase = json['useCase'] as String? ?? 'security';
    return AppConfig(
      deviceId: json['deviceId'] as String,
      deviceRetentionHours: _asInt(json['deviceRetentionHours'], 50),
      cloudRetentionHours: _asInt(json['cloudRetentionHours'], 500),
      segmentMinutes: _asInt(json['segmentMinutes'], 1).clamp(1, 60),
      overlapSeconds: _asInt(json['overlapSeconds'], 2).clamp(0, 30),
      bitRate: _asInt(json['bitRate'], 64000),
      sampleRate: _asInt(json['sampleRate'], 16000),
      channels: _asInt(json['channels'], 1).clamp(1, 2),
      uploadEnabled: json['uploadEnabled'] as bool? ?? false,
      cloudProvider: CloudProvider.fromName(json['cloudProvider'] as String?),
      backendBaseUrl: json['backendBaseUrl'] as String? ?? '',
      s3Bucket: json['s3Bucket'] as String? ?? '',
      s3Region: json['s3Region'] as String? ?? 'us-east-1',
      s3Prefix: json['s3Prefix'] as String? ?? 'audio-dashcam',
      s3Endpoint: json['s3Endpoint'] as String? ?? '',
      supabaseUrl: json['supabaseUrl'] as String? ?? '',
      supabaseAnonKey: json['supabaseAnonKey'] as String? ?? '',
      useCase: supportedUseCases.contains(useCase) ? useCase : 'security',
      micSensitivity: _asDouble(json['micSensitivity'], 1.0).clamp(0.25, 4.0),
      noiseTriggerSensitivity: _asDouble(
        json['noiseTriggerSensitivity'],
        0.5,
      ).clamp(0.0, 1.0),
      bassGainDb: _asDouble(json['bassGainDb'], 0.0).clamp(-12.0, 12.0),
      midGainDb: _asDouble(json['midGainDb'], 0.0).clamp(-12.0, 12.0),
      trebleGainDb: _asDouble(json['trebleGainDb'], 0.0).clamp(-12.0, 12.0),
      autoGain: json['autoGain'] as bool? ?? true,
      noiseSuppress: json['noiseSuppress'] as bool? ?? true,
      verbalCuesEnabled: json['verbalCuesEnabled'] as bool? ?? false,
      autoStartCaptureEnabled:
          json['autoStartCaptureEnabled'] as bool? ?? false,
      locationTaggingEnabled: json['locationTaggingEnabled'] as bool? ?? false,
      soundCloudDailyArchive: json['soundCloudDailyArchive'] as bool? ?? false,
      spotifyAutoPlaylist: json['spotifyAutoPlaylist'] as bool? ?? false,
      placeNamesEnabled: json['placeNamesEnabled'] as bool? ?? false,
      pauseUploadsOnLowBattery:
          json['pauseUploadsOnLowBattery'] as bool? ?? true,
      lowBatteryThresholdPercent: _asInt(
        json['lowBatteryThresholdPercent'],
        20,
      ).clamp(1, 100),
      uploadNetworkPolicy: UploadNetworkPolicy.fromName(
        json['uploadNetworkPolicy'] as String?,
      ),
      acousticAnalysisEnabled:
          json['acousticAnalysisEnabled'] as bool? ?? false,
      spectralSidecarEnabled: json['spectralSidecarEnabled'] as bool? ?? true,
      analysisActivationDb: _asDouble(
        json['analysisActivationDb'],
        -40.0,
      ).clamp(-90.0, 0.0),
      analysisSustainSeconds: _asDouble(
        json['analysisSustainSeconds'],
        2.0,
      ).clamp(0.5, 30.0),
      analysisHoldSeconds: _asDouble(
        json['analysisHoldSeconds'],
        45.0,
      ).clamp(0.0, 600.0),
      snoreDetectionEnabled: json['snoreDetectionEnabled'] as bool? ?? true,
      musicDetectionEnabled: json['musicDetectionEnabled'] as bool? ?? true,
      speechDetectionEnabled: json['speechDetectionEnabled'] as bool? ?? true,
      sleepSmartAlarmEnabled: json['sleepSmartAlarmEnabled'] as bool? ?? true,
      sleepDefaultCycleMinutes: _asDouble(
        json['sleepDefaultCycleMinutes'],
        90.0,
      ).clamp(60.0, 130.0),
      sleepTargetCycle: _asInt(json['sleepTargetCycle'], 5).clamp(1, 12),
      sleepBackstopCycle: _asInt(json['sleepBackstopCycle'], 6).clamp(1, 12),
      sleepSmartWindowMinutes: _asDouble(
        json['sleepSmartWindowMinutes'],
        25.0,
      ).clamp(0.0, 90.0),
      sleepMotionConsent: json['sleepMotionConsent'] as bool? ?? false,
      sleepLightConsent: json['sleepLightConsent'] as bool? ?? false,
      shazamEnabled: json['shazamEnabled'] as bool? ?? false,
      keywords: _asStringList(json['keywords']),
      sttEnabled: json['sttEnabled'] as bool? ?? false,
      sttEndpoint: json['sttEndpoint'] as String? ?? '',
      adaptiveQualityEnabled: json['adaptiveQualityEnabled'] as bool? ?? false,
      captureSampleRate: _asInt(
        json['captureSampleRate'],
        48000,
      ).clamp(8000, 48000),
      quietSampleRate: _asInt(
        json['quietSampleRate'],
        16000,
      ).clamp(8000, 48000),
      adaptiveLoudnessDb: _asDouble(
        json['adaptiveLoudnessDb'],
        -40.0,
      ).clamp(-90.0, 0.0),
      contextTriggersEnabled: json['contextTriggersEnabled'] as bool? ?? false,
      contextTriggerKinds: _asStringList(json['contextTriggerKinds']),
      contextTriggerCooldownSeconds: _asInt(
        json['contextTriggerCooldownSeconds'],
        300,
      ).clamp(10, 3600),
      recordingSchedule: RecordingSchedule.fromJson(
        (json['recordingSchedule'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }

  static List<String> _asStringList(Object? value) {
    if (value is List) {
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static int _asInt(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double _asDouble(Object? value, double fallback) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }
}
