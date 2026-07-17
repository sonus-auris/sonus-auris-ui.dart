// Generated from schema/tables.json by @sonus-auris/interfaces. Do not edit by hand.
// SOURCE OF TRUTH: schema/tables.json. Regenerate with: node src/generate.mjs
// Contract version: 2026.07.13
// MIGRATION SAFETY: review every change; use declarative-postgres-migrate with a direct Supabase connection. Never auto-apply.

import 'dart:convert';

const acousticEventsTable = "acoustic_events";
const acousticEventsKindValues = <String>["snore", "apneaPattern", "music", "speech", "keyword", "sleepCycle", "sleepCycleAlarm", "suddenLoudNoise", "raisedVoice", "possibleArgumentPattern"];

class AcousticEvent {
  const AcousticEvent({
    required this.id,
    required this.userId,
    required this.deviceId,
    required this.kind,
    required this.startedAt,
    required this.endedAt,
    required this.confidence,
    required this.details,
    required this.createdAt,
  });

  /// Server-generated row id.
  final String id;
  /// Owning user; defaulted from the access token (auth.uid()).
  final String userId;
  /// Opaque per-install device id (AppConfig.deviceId).
  final String deviceId;
  /// Detection kind (wire value matches the client AcousticDetectionKind name).
  final String kind;
  /// UTC start of the detection.
  final String startedAt;
  /// UTC end of the detection.
  final String endedAt;
  /// Heuristic confidence in 0..1.
  final double confidence;
  /// Kind-specific, JSON-serializable extras (no audio).
  final Map<String, Object?> details;
  /// Insert time.
  final String createdAt;

  factory AcousticEvent.fromJson(Map<String, Object?> json) {
    return AcousticEvent(
      id: _reqString(json, "id"),
      userId: _reqString(json, "user_id"),
      deviceId: _reqString(json, "device_id"),
      kind: _reqString(json, "kind"),
      startedAt: _reqString(json, "started_at"),
      endedAt: _reqString(json, "ended_at"),
      confidence: _reqDouble(json, "confidence"),
      details: _reqObject(json, "details"),
      createdAt: _reqString(json, "created_at"),
    );
  }

  Map<String, Object?> toJson() {
    return {
      "id": id,
      "user_id": userId,
      "device_id": deviceId,
      "kind": kind,
      "started_at": startedAt,
      "ended_at": endedAt,
      "confidence": confidence,
      "details": details,
      "created_at": createdAt,
    };
  }

  /// Row for INSERT: server-generated columns are omitted so the
  /// database fills them (id, user_id via auth.uid(), created_at).
  Map<String, Object?> toInsertJson() {
    return {
      "device_id": deviceId,
      "kind": kind,
      "started_at": startedAt,
      "ended_at": endedAt,
      "confidence": confidence,
      "details": details,
    };
  }
}

const userConsentsTable = "user_consents";

class UserConsent {
  const UserConsent({
    required this.id,
    required this.userId,
    required this.deviceId,
    required this.consentVersion,
    this.platform,
    required this.granted,
    required this.acceptedAt,
    required this.createdAt,
  });

  final String id;
  final String userId;
  final String deviceId;
  /// The disclosure version the user agreed to (kConsentVersion).
  final String consentVersion;
  /// android / ios / other.
  final String? platform;
  /// Map of consent item key -> bool (microphone, cloud_backup, notifications, location, motion, bluetooth).
  final Map<String, Object?> granted;
  /// When the user accepted (client UTC).
  final String acceptedAt;
  final String createdAt;

  factory UserConsent.fromJson(Map<String, Object?> json) {
    return UserConsent(
      id: _reqString(json, "id"),
      userId: _reqString(json, "user_id"),
      deviceId: _reqString(json, "device_id"),
      consentVersion: _reqString(json, "consent_version"),
      platform: _optString(json, "platform"),
      granted: _reqObject(json, "granted"),
      acceptedAt: _reqString(json, "accepted_at"),
      createdAt: _reqString(json, "created_at"),
    );
  }

  Map<String, Object?> toJson() {
    return {
      "id": id,
      "user_id": userId,
      "device_id": deviceId,
      "consent_version": consentVersion,
      "platform": platform,
      "granted": granted,
      "accepted_at": acceptedAt,
      "created_at": createdAt,
    };
  }

  /// Row for INSERT: server-generated columns are omitted so the
  /// database fills them (id, user_id via auth.uid(), created_at).
  Map<String, Object?> toInsertJson() {
    return {
      "device_id": deviceId,
      "consent_version": consentVersion,
      "platform": platform,
      "granted": granted,
      "accepted_at": acceptedAt,
    };
  }
}

const userSettingsTable = "user_settings";
const userSettingsPreferredUseCaseValues = <String>["security", "music", "meeting", "voice_note", "ambient"];
const userSettingsCloudProviderValues = <String>["s3", "googleDrive", "oneDrive", "iCloudDrive"];

class UserSettings {
  const UserSettings({
    required this.userId,
    required this.preferredUseCase,
    required this.deviceRetentionHours,
    required this.cloudRetentionHours,
    required this.segmentMinutes,
    required this.overlapSeconds,
    required this.bitRate,
    required this.sampleRate,
    required this.channels,
    required this.uploadEnabled,
    required this.cloudProvider,
    required this.micSensitivity,
    required this.noiseTriggerSensitivity,
    required this.bassGainDb,
    required this.midGainDb,
    required this.trebleGainDb,
    required this.autoGain,
    required this.noiseSuppress,
    required this.acousticAnalysisEnabled,
    required this.analysisActivationDb,
    required this.analysisSustainSeconds,
    required this.analysisHoldSeconds,
    required this.snoreDetectionEnabled,
    required this.sleepAnalysisEnabled,
    required this.musicDetectionEnabled,
    required this.speechDetectionEnabled,
    required this.adaptiveQualityEnabled,
    required this.captureSampleRate,
    required this.quietSampleRate,
    required this.adaptiveLoudnessDb,
    required this.updatedAt,
  });

  /// Owning user; defaulted from the access token and limited by RLS.
  final String userId;
  final String preferredUseCase;
  final int deviceRetentionHours;
  final int cloudRetentionHours;
  final int segmentMinutes;
  final int overlapSeconds;
  final int bitRate;
  final int sampleRate;
  final int channels;
  final bool uploadEnabled;
  /// Account preference only; credentials and provider tokens are never stored in this table.
  final String cloudProvider;
  final double micSensitivity;
  final double noiseTriggerSensitivity;
  final double bassGainDb;
  final double midGainDb;
  final double trebleGainDb;
  final bool autoGain;
  final bool noiseSuppress;
  final bool acousticAnalysisEnabled;
  final double analysisActivationDb;
  final double analysisSustainSeconds;
  final double analysisHoldSeconds;
  final bool snoreDetectionEnabled;
  final bool sleepAnalysisEnabled;
  final bool musicDetectionEnabled;
  final bool speechDetectionEnabled;
  final bool adaptiveQualityEnabled;
  final int captureSampleRate;
  final int quietSampleRate;
  final double adaptiveLoudnessDb;
  /// Last client-mediated update time, used for cross-device last-write-wins reconciliation.
  final String updatedAt;

  factory UserSettings.fromJson(Map<String, Object?> json) {
    return UserSettings(
      userId: _reqString(json, "user_id"),
      preferredUseCase: _reqString(json, "preferred_use_case"),
      deviceRetentionHours: _reqInt(json, "device_retention_hours"),
      cloudRetentionHours: _reqInt(json, "cloud_retention_hours"),
      segmentMinutes: _reqInt(json, "segment_minutes"),
      overlapSeconds: _reqInt(json, "overlap_seconds"),
      bitRate: _reqInt(json, "bit_rate"),
      sampleRate: _reqInt(json, "sample_rate"),
      channels: _reqInt(json, "channels"),
      uploadEnabled: _reqBool(json, "upload_enabled"),
      cloudProvider: _reqString(json, "cloud_provider"),
      micSensitivity: _reqDouble(json, "mic_sensitivity"),
      noiseTriggerSensitivity: _reqDouble(json, "noise_trigger_sensitivity"),
      bassGainDb: _reqDouble(json, "bass_gain_db"),
      midGainDb: _reqDouble(json, "mid_gain_db"),
      trebleGainDb: _reqDouble(json, "treble_gain_db"),
      autoGain: _reqBool(json, "auto_gain"),
      noiseSuppress: _reqBool(json, "noise_suppress"),
      acousticAnalysisEnabled: _reqBool(json, "acoustic_analysis_enabled"),
      analysisActivationDb: _reqDouble(json, "analysis_activation_db"),
      analysisSustainSeconds: _reqDouble(json, "analysis_sustain_seconds"),
      analysisHoldSeconds: _reqDouble(json, "analysis_hold_seconds"),
      snoreDetectionEnabled: _reqBool(json, "snore_detection_enabled"),
      sleepAnalysisEnabled: _reqBool(json, "sleep_analysis_enabled"),
      musicDetectionEnabled: _reqBool(json, "music_detection_enabled"),
      speechDetectionEnabled: _reqBool(json, "speech_detection_enabled"),
      adaptiveQualityEnabled: _reqBool(json, "adaptive_quality_enabled"),
      captureSampleRate: _reqInt(json, "capture_sample_rate"),
      quietSampleRate: _reqInt(json, "quiet_sample_rate"),
      adaptiveLoudnessDb: _reqDouble(json, "adaptive_loudness_db"),
      updatedAt: _reqString(json, "updated_at"),
    );
  }

  Map<String, Object?> toJson() {
    return {
      "user_id": userId,
      "preferred_use_case": preferredUseCase,
      "device_retention_hours": deviceRetentionHours,
      "cloud_retention_hours": cloudRetentionHours,
      "segment_minutes": segmentMinutes,
      "overlap_seconds": overlapSeconds,
      "bit_rate": bitRate,
      "sample_rate": sampleRate,
      "channels": channels,
      "upload_enabled": uploadEnabled,
      "cloud_provider": cloudProvider,
      "mic_sensitivity": micSensitivity,
      "noise_trigger_sensitivity": noiseTriggerSensitivity,
      "bass_gain_db": bassGainDb,
      "mid_gain_db": midGainDb,
      "treble_gain_db": trebleGainDb,
      "auto_gain": autoGain,
      "noise_suppress": noiseSuppress,
      "acoustic_analysis_enabled": acousticAnalysisEnabled,
      "analysis_activation_db": analysisActivationDb,
      "analysis_sustain_seconds": analysisSustainSeconds,
      "analysis_hold_seconds": analysisHoldSeconds,
      "snore_detection_enabled": snoreDetectionEnabled,
      "sleep_analysis_enabled": sleepAnalysisEnabled,
      "music_detection_enabled": musicDetectionEnabled,
      "speech_detection_enabled": speechDetectionEnabled,
      "adaptive_quality_enabled": adaptiveQualityEnabled,
      "capture_sample_rate": captureSampleRate,
      "quiet_sample_rate": quietSampleRate,
      "adaptive_loudness_db": adaptiveLoudnessDb,
      "updated_at": updatedAt,
    };
  }

  /// Row for INSERT: server-generated columns are omitted so the
  /// database fills them (id, user_id via auth.uid(), created_at).
  Map<String, Object?> toInsertJson() {
    return {
      "preferred_use_case": preferredUseCase,
      "device_retention_hours": deviceRetentionHours,
      "cloud_retention_hours": cloudRetentionHours,
      "segment_minutes": segmentMinutes,
      "overlap_seconds": overlapSeconds,
      "bit_rate": bitRate,
      "sample_rate": sampleRate,
      "channels": channels,
      "upload_enabled": uploadEnabled,
      "cloud_provider": cloudProvider,
      "mic_sensitivity": micSensitivity,
      "noise_trigger_sensitivity": noiseTriggerSensitivity,
      "bass_gain_db": bassGainDb,
      "mid_gain_db": midGainDb,
      "treble_gain_db": trebleGainDb,
      "auto_gain": autoGain,
      "noise_suppress": noiseSuppress,
      "acoustic_analysis_enabled": acousticAnalysisEnabled,
      "analysis_activation_db": analysisActivationDb,
      "analysis_sustain_seconds": analysisSustainSeconds,
      "analysis_hold_seconds": analysisHoldSeconds,
      "snore_detection_enabled": snoreDetectionEnabled,
      "sleep_analysis_enabled": sleepAnalysisEnabled,
      "music_detection_enabled": musicDetectionEnabled,
      "speech_detection_enabled": speechDetectionEnabled,
      "adaptive_quality_enabled": adaptiveQualityEnabled,
      "capture_sample_rate": captureSampleRate,
      "quiet_sample_rate": quietSampleRate,
      "adaptive_loudness_db": adaptiveLoudnessDb,
      "updated_at": updatedAt,
    };
  }
}

const clientTelemetryTable = "client_telemetry";
const clientTelemetryLevelValues = <String>["debug", "info", "warning", "error", "fatal"];

class ClientTelemetry {
  const ClientTelemetry({
    required this.id,
    required this.userId,
    required this.deviceId,
    required this.level,
    required this.event,
    required this.message,
    this.stack,
    this.platform,
    this.appVersion,
    required this.details,
    required this.occurredAt,
    required this.createdAt,
  });

  final String id;
  /// Owning user resolved from the signed-in Supabase JWT.
  final String userId;
  /// Opaque per-install device id.
  final String deviceId;
  /// Severity level normalized by the client.
  final String level;
  /// Stable event name, e.g. diagnostic, flutter_error, platform_dispatcher_error.
  final String event;
  /// Short redacted log/error message.
  final String message;
  /// Redacted Dart stack trace when available.
  final String? stack;
  /// android / ios / macos / windows / linux / other.
  final String? platform;
  /// Client app version when available.
  final String? appVersion;
  /// Redacted JSON details for filtering/debugging.
  final Map<String, Object?> details;
  /// Client UTC timestamp for when the event occurred.
  final String occurredAt;
  /// Insert time.
  final String createdAt;

  factory ClientTelemetry.fromJson(Map<String, Object?> json) {
    return ClientTelemetry(
      id: _reqString(json, "id"),
      userId: _reqString(json, "user_id"),
      deviceId: _reqString(json, "device_id"),
      level: _reqString(json, "level"),
      event: _reqString(json, "event"),
      message: _reqString(json, "message"),
      stack: _optString(json, "stack"),
      platform: _optString(json, "platform"),
      appVersion: _optString(json, "app_version"),
      details: _reqObject(json, "details"),
      occurredAt: _reqString(json, "occurred_at"),
      createdAt: _reqString(json, "created_at"),
    );
  }

  Map<String, Object?> toJson() {
    return {
      "id": id,
      "user_id": userId,
      "device_id": deviceId,
      "level": level,
      "event": event,
      "message": message,
      "stack": stack,
      "platform": platform,
      "app_version": appVersion,
      "details": details,
      "occurred_at": occurredAt,
      "created_at": createdAt,
    };
  }

  /// Row for INSERT: server-generated columns are omitted so the
  /// database fills them (id, user_id via auth.uid(), created_at).
  Map<String, Object?> toInsertJson() {
    return {
      "device_id": deviceId,
      "level": level,
      "event": event,
      "message": message,
      "stack": stack,
      "platform": platform,
      "app_version": appVersion,
      "details": details,
      "occurred_at": occurredAt,
    };
  }
}

// --- readers ---------------------------------------------------------------
String _reqString(Map<String, Object?> j, String k) => j[k]! as String;
String? _optString(Map<String, Object?> j, String k) => j[k] as String?;
int _reqInt(Map<String, Object?> j, String k) => (j[k]! as num).toInt();
double _reqDouble(Map<String, Object?> j, String k) => (j[k]! as num).toDouble();
bool _reqBool(Map<String, Object?> j, String k) => j[k]! as bool;
Map<String, Object?> _reqObject(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is Map<String, Object?>) return v;
  if (v is Map) return v.cast<String, Object?>();
  if (v is String && v.isNotEmpty) {
    final decoded = jsonDecode(v);
    if (decoded is Map) return decoded.cast<String, Object?>();
  }
  throw FormatException('Expected a JSON object for "$k".');
}
