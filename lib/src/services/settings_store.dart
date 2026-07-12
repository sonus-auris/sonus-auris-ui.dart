// Persists app config, cloud secrets, consent, and sleep profiles across secure storage and shared preferences.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/app_config.dart';
import '../models/audio_trigger_event.dart';
import '../models/cloud_secrets.dart';
import '../models/consent.dart';
import '../models/sleep_cycle_profile.dart';

class SettingsStore {
  SettingsStore({FlutterSecureStorage? secureStorage, Uuid? uuid})
    : _secureStorage = secureStorage ?? _defaultSecureStorage,
      _uuid = uuid ?? const Uuid();

  static const _defaultSecureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
  );

  static const _configKey = 'audio_dashcam.config.v1';
  static const _pendingAlertsKey = 'audio_dashcam.pending_alerts.v1';
  static const _sleepCycleProfileKey = 'audio_dashcam.sleep_cycle_profile.v1';
  static const _consentRecordKey = 'audio_dashcam.consent_record.v1';
  static const _s3AccessKeyKey = 'audio_dashcam.s3.access_key_id';
  static const _s3SecretKeyKey = 'audio_dashcam.s3.secret_access_key';
  static const _s3SessionTokenKey = 'audio_dashcam.s3.session_token';
  static const _backendDeviceTokenKey = 'audio_dashcam.backend.device_token';
  static const _supabaseAccessTokenKey = 'audio_dashcam.supabase.access_token';
  static const _supabaseRefreshTokenKey =
      'audio_dashcam.supabase.refresh_token';
  static const _supabaseTokenExpiresAtKey =
      'audio_dashcam.supabase.token_expires_at';
  static const _supabaseEmailKey = 'audio_dashcam.supabase.email';
  static const _sttApiKeyKey = 'audio_dashcam.stt.api_key';
  static const _soundCloudAccessKey = 'audio_dashcam.soundcloud.access_token';
  static const _soundCloudRefreshKey = 'audio_dashcam.soundcloud.refresh_token';
  static const _spotifyAccessKey = 'audio_dashcam.spotify.access_token';
  static const _spotifyRefreshKey = 'audio_dashcam.spotify.refresh_token';
  static const _lastArchivedDayKey = 'audio_dashcam.day_archive.last_day';

  final FlutterSecureStorage _secureStorage;
  final Uuid _uuid;

  Future<AppConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_configKey);
    if (raw == null) {
      final config = AppConfig(deviceId: _uuid.v4());
      await saveConfig(config);
      return config;
    }
    try {
      return AppConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      final config = AppConfig(deviceId: _uuid.v4());
      await saveConfig(config);
      return config;
    }
  }

  Future<void> saveConfig(AppConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(config.toJson()));
  }

  Future<List<AudioTriggerEvent>> loadPendingAlerts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingAlertsKey);
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .cast<Map<String, dynamic>>()
          .map(AudioTriggerEvent.fromJson)
          .toList();
    } catch (_) {
      await prefs.remove(_pendingAlertsKey);
      return const [];
    }
  }

  Future<void> savePendingAlerts(List<AudioTriggerEvent> events) async {
    final prefs = await SharedPreferences.getInstance();
    if (events.isEmpty) {
      await prefs.remove(_pendingAlertsKey);
      return;
    }
    await prefs.setString(
      _pendingAlertsKey,
      jsonEncode(events.map((event) => event.toJson()).toList()),
    );
  }

  Future<SleepCycleProfile> loadSleepCycleProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sleepCycleProfileKey);
    if (raw == null || raw.trim().isEmpty) {
      return const SleepCycleProfile();
    }
    try {
      return SleepCycleProfile.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      ).pruned(DateTime.now().toUtc());
    } catch (_) {
      await prefs.remove(_sleepCycleProfileKey);
      return const SleepCycleProfile();
    }
  }

  Future<void> saveSleepCycleProfile(SleepCycleProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final pruned = profile.pruned(DateTime.now().toUtc());
    if (pruned.observations.isEmpty) {
      await prefs.remove(_sleepCycleProfileKey);
      return;
    }
    await prefs.setString(_sleepCycleProfileKey, jsonEncode(pruned.toJson()));
  }

  /// The onboarding consent the user last accepted, or null if they have not
  /// completed onboarding on this install.
  Future<ConsentRecord?> loadConsentRecord() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_consentRecordKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      return ConsentRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await prefs.remove(_consentRecordKey);
      return null;
    }
  }

  Future<void> saveConsentRecord(ConsentRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_consentRecordKey, jsonEncode(record.toJson()));
  }

  Future<CloudSecrets> loadSecrets() async {
    return CloudSecrets(
      s3AccessKeyId: await _secureStorage.read(key: _s3AccessKeyKey) ?? '',
      s3SecretAccessKey: await _secureStorage.read(key: _s3SecretKeyKey) ?? '',
      s3SessionToken: await _secureStorage.read(key: _s3SessionTokenKey) ?? '',
      backendDeviceToken:
          await _secureStorage.read(key: _backendDeviceTokenKey) ?? '',
      supabaseAccessToken:
          await _secureStorage.read(key: _supabaseAccessTokenKey) ?? '',
      supabaseRefreshToken:
          await _secureStorage.read(key: _supabaseRefreshTokenKey) ?? '',
      supabaseAccessTokenExpiresAt:
          await _secureStorage.read(key: _supabaseTokenExpiresAtKey) ?? '',
      supabaseEmail: await _secureStorage.read(key: _supabaseEmailKey) ?? '',
      sttApiKey: await _secureStorage.read(key: _sttApiKeyKey) ?? '',
      soundCloudAccessToken:
          await _secureStorage.read(key: _soundCloudAccessKey) ?? '',
      soundCloudRefreshToken:
          await _secureStorage.read(key: _soundCloudRefreshKey) ?? '',
      spotifyAccessToken:
          await _secureStorage.read(key: _spotifyAccessKey) ?? '',
      spotifyRefreshToken:
          await _secureStorage.read(key: _spotifyRefreshKey) ?? '',
    );
  }

  Future<void> saveSecrets(CloudSecrets secrets) async {
    await _writeSecure(_s3AccessKeyKey, secrets.s3AccessKeyId);
    await _writeSecure(_s3SecretKeyKey, secrets.s3SecretAccessKey);
    await _writeSecure(_s3SessionTokenKey, secrets.s3SessionToken);
    await _writeSecure(_backendDeviceTokenKey, secrets.backendDeviceToken);
    await _writeSecure(_supabaseAccessTokenKey, secrets.supabaseAccessToken);
    await _writeSecure(_supabaseRefreshTokenKey, secrets.supabaseRefreshToken);
    await _writeSecure(
      _supabaseTokenExpiresAtKey,
      secrets.supabaseAccessTokenExpiresAt,
    );
    await _writeSecure(_supabaseEmailKey, secrets.supabaseEmail);
    await _writeSecure(_sttApiKeyKey, secrets.sttApiKey);
    await _writeSecure(_soundCloudAccessKey, secrets.soundCloudAccessToken);
    await _writeSecure(_soundCloudRefreshKey, secrets.soundCloudRefreshToken);
    await _writeSecure(_spotifyAccessKey, secrets.spotifyAccessToken);
    await _writeSecure(_spotifyRefreshKey, secrets.spotifyRefreshToken);
  }

  /// The last local date (yyyy-MM-dd) successfully archived as a "Day of My
  /// Life", so the archiver doesn't re-publish across restarts. Null if never.
  Future<DateTime?> loadLastArchivedDay() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastArchivedDayKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw.trim());
  }

  Future<void> saveLastArchivedDay(DateTime dayLocal) async {
    final prefs = await SharedPreferences.getInstance();
    final d = DateTime(dayLocal.year, dayLocal.month, dayLocal.day);
    await prefs.setString(_lastArchivedDayKey, d.toIso8601String());
  }

  Future<void> _writeSecure(String key, String value) async {
    if (value.trim().isEmpty) {
      await _secureStorage.delete(key: key);
    } else {
      await _secureStorage.write(key: key, value: value.trim());
    }
  }
}
