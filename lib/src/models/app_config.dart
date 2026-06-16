import 'cloud_provider.dart';
import 'upload_network_policy.dart';

class RecordingWindow {
  const RecordingWindow({required this.startMinute, required this.endMinute});

  static const int minutesPerDay = 24 * 60;
  static const RecordingWindow fullDay = RecordingWindow(
    startMinute: 0,
    endMinute: minutesPerDay,
  );

  final int startMinute;
  final int endMinute;

  bool get isValid =>
      startMinute >= 0 && endMinute <= minutesPerDay && startMinute < endMinute;

  bool containsMinute(int minute) {
    final clamped = minute.clamp(0, minutesPerDay - 1);
    return startMinute <= clamped && clamped < endMinute;
  }

  RecordingWindow copyWith({int? startMinute, int? endMinute}) {
    return RecordingWindow(
      startMinute: startMinute ?? this.startMinute,
      endMinute: endMinute ?? this.endMinute,
    );
  }

  Map<String, dynamic> toJson() {
    return {'startMinute': startMinute, 'endMinute': endMinute};
  }

  factory RecordingWindow.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const RecordingWindow(startMinute: 9 * 60, endMinute: 17 * 60);
    }
    return RecordingWindow(
      startMinute: AppConfig._asInt(
        json['startMinute'],
        9 * 60,
      ).clamp(0, minutesPerDay - 1),
      endMinute: AppConfig._asInt(
        json['endMinute'],
        17 * 60,
      ).clamp(1, minutesPerDay),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is RecordingWindow &&
        startMinute == other.startMinute &&
        endMinute == other.endMinute;
  }

  @override
  int get hashCode => Object.hash(startMinute, endMinute);
}

class RecordingDaySchedule {
  const RecordingDaySchedule({
    required this.dayOfWeek,
    this.allDay = false,
    this.windows = const [],
  });

  final int dayOfWeek;
  final bool allDay;
  final List<RecordingWindow> windows;

  bool get hasWindows => allDay || normalizedWindows.isNotEmpty;

  List<RecordingWindow> get effectiveWindows =>
      allDay ? const [RecordingWindow.fullDay] : normalizedWindows;

  List<RecordingWindow> get normalizedWindows => _normalizeWindows(windows);

  bool containsMinute(int minute) {
    if (allDay) {
      return true;
    }
    return normalizedWindows.any((window) => window.containsMinute(minute));
  }

  RecordingDaySchedule copyWith({
    int? dayOfWeek,
    bool? allDay,
    List<RecordingWindow>? windows,
  }) {
    return RecordingDaySchedule(
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      allDay: allDay ?? this.allDay,
      windows: windows ?? this.windows,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dayOfWeek': dayOfWeek,
      'allDay': allDay,
      'windows': normalizedWindows.map((window) => window.toJson()).toList(),
    };
  }

  factory RecordingDaySchedule.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const RecordingDaySchedule(dayOfWeek: DateTime.monday);
    }
    final rawWindows = json['windows'];
    return RecordingDaySchedule(
      dayOfWeek: AppConfig._asInt(
        json['dayOfWeek'],
        DateTime.monday,
      ).clamp(1, 7),
      allDay: json['allDay'] as bool? ?? false,
      windows: rawWindows is List
          ? rawWindows
                .map(RecordingWindow.fromJson)
                .where((w) => w.isValid)
                .toList()
          : const [],
    );
  }

  static List<RecordingWindow> _normalizeWindows(
    List<RecordingWindow> windows,
  ) {
    final sorted =
        windows
            .where((window) => window.isValid)
            .map(
              (window) => RecordingWindow(
                startMinute: window.startMinute.clamp(
                  0,
                  RecordingWindow.minutesPerDay - 1,
                ),
                endMinute: window.endMinute.clamp(
                  1,
                  RecordingWindow.minutesPerDay,
                ),
              ),
            )
            .toList()
          ..sort((a, b) => a.startMinute.compareTo(b.startMinute));
    final merged = <RecordingWindow>[];
    for (final window in sorted) {
      if (merged.isEmpty || window.startMinute > merged.last.endMinute) {
        merged.add(window);
        continue;
      }
      final last = merged.removeLast();
      merged.add(
        RecordingWindow(
          startMinute: last.startMinute,
          endMinute: window.endMinute > last.endMinute
              ? window.endMinute
              : last.endMinute,
        ),
      );
    }
    return List.unmodifiable(merged);
  }

  @override
  bool operator ==(Object other) {
    return other is RecordingDaySchedule &&
        dayOfWeek == other.dayOfWeek &&
        allDay == other.allDay &&
        _listEquals(normalizedWindows, other.normalizedWindows);
  }

  @override
  int get hashCode =>
      Object.hash(dayOfWeek, allDay, Object.hashAll(normalizedWindows));
}

class WeeklyRecordingSchedule {
  const WeeklyRecordingSchedule({this.days = const []});

  final List<RecordingDaySchedule> days;

  bool get hasAnyWindows => normalizedDays.any((day) => day.hasWindows);

  List<RecordingDaySchedule> get normalizedDays {
    final byDay = <int, RecordingDaySchedule>{
      for (
        var weekday = DateTime.monday;
        weekday <= DateTime.sunday;
        weekday += 1
      )
        weekday: RecordingDaySchedule(dayOfWeek: weekday),
    };
    for (final day in days) {
      final weekday = day.dayOfWeek.clamp(DateTime.monday, DateTime.sunday);
      final current = byDay[weekday]!;
      byDay[weekday] = RecordingDaySchedule(
        dayOfWeek: weekday,
        allDay: current.allDay || day.allDay,
        windows: [...current.windows, ...day.normalizedWindows],
      );
    }
    return List.unmodifiable(byDay.values);
  }

  RecordingDaySchedule day(int weekday) {
    final clamped = weekday.clamp(DateTime.monday, DateTime.sunday);
    return normalizedDays.firstWhere((day) => day.dayOfWeek == clamped);
  }

  bool isActiveAt(DateTime instant) {
    if (!hasAnyWindows) {
      return false;
    }
    final local = instant.toLocal();
    final minute = local.hour * 60 + local.minute;
    return day(local.weekday).containsMinute(minute);
  }

  DateTime? nextBarrierAfter(DateTime instant) {
    if (!hasAnyWindows) {
      return null;
    }
    final now = instant.toLocal();
    final activeNow = isActiveAt(now);
    final today = DateTime(now.year, now.month, now.day);
    DateTime? best;
    for (var offset = 0; offset <= 8; offset += 1) {
      final date = today.add(Duration(days: offset));
      final daySchedule = day(date.weekday);
      for (final window in daySchedule.effectiveWindows) {
        for (final minute in [window.startMinute, window.endMinute]) {
          final candidate = date.add(Duration(minutes: minute));
          if (!candidate.isAfter(now)) {
            continue;
          }
          if (isActiveAt(candidate.add(const Duration(seconds: 1))) ==
              activeNow) {
            continue;
          }
          if (best == null || candidate.isBefore(best)) {
            best = candidate;
          }
        }
      }
    }
    return best;
  }

  WeeklyRecordingSchedule copyWith({List<RecordingDaySchedule>? days}) {
    return WeeklyRecordingSchedule(days: days ?? this.days);
  }

  Map<String, dynamic> toJson() {
    return {'days': normalizedDays.map((day) => day.toJson()).toList()};
  }

  factory WeeklyRecordingSchedule.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const WeeklyRecordingSchedule();
    }
    final rawDays = json['days'];
    return WeeklyRecordingSchedule(
      days: rawDays is List
          ? rawDays.map(RecordingDaySchedule.fromJson).toList()
          : const [],
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WeeklyRecordingSchedule &&
        _listEquals(normalizedDays, other.normalizedDays);
  }

  @override
  int get hashCode => Object.hashAll(normalizedDays);
}

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
    this.shazamEnabled = false,
    this.keywords = const [],
    this.sttEnabled = false,
    this.sttEndpoint = '',
    this.adaptiveQualityEnabled = false,
    this.captureSampleRate = 48000,
    this.quietSampleRate = 16000,
    this.adaptiveLoudnessDb = -40.0,
    this.recordingSchedule = const WeeklyRecordingSchedule(),
  });

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

  /// Optional weekly recording consent schedule. Empty means scheduling is off
  /// and manual/auto-start recording behaves exactly as before.
  final WeeklyRecordingSchedule recordingSchedule;

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
    bool? shazamEnabled,
    List<String>? keywords,
    bool? sttEnabled,
    String? sttEndpoint,
    bool? adaptiveQualityEnabled,
    int? captureSampleRate,
    int? quietSampleRate,
    double? adaptiveLoudnessDb,
    WeeklyRecordingSchedule? recordingSchedule,
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
      shazamEnabled: shazamEnabled ?? this.shazamEnabled,
      keywords: keywords ?? this.keywords,
      sttEnabled: sttEnabled ?? this.sttEnabled,
      sttEndpoint: sttEndpoint ?? this.sttEndpoint,
      adaptiveQualityEnabled:
          adaptiveQualityEnabled ?? this.adaptiveQualityEnabled,
      captureSampleRate: captureSampleRate ?? this.captureSampleRate,
      quietSampleRate: quietSampleRate ?? this.quietSampleRate,
      adaptiveLoudnessDb: adaptiveLoudnessDb ?? this.adaptiveLoudnessDb,
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
      'shazamEnabled': shazamEnabled,
      'keywords': keywords,
      'sttEnabled': sttEnabled,
      'sttEndpoint': sttEndpoint,
      'adaptiveQualityEnabled': adaptiveQualityEnabled,
      'captureSampleRate': captureSampleRate,
      'quietSampleRate': quietSampleRate,
      'adaptiveLoudnessDb': adaptiveLoudnessDb,
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
      recordingSchedule: WeeklyRecordingSchedule.fromJson(
        json['recordingSchedule'],
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

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
