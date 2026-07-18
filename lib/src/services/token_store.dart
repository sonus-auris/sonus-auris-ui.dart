// Persistence for the session + this install's device id.
//
// Web-safe by construction: an abstract [TokenStore] with two implementations
// chosen at runtime by [kIsWeb]. Native desktop uses the OS keychain via
// flutter_secure_storage; web uses shared_preferences (browser storage — not a
// secret vault, but it only ever holds a short-lived GoTrue session that the
// server revalidates on every call, never a long-lived credential).
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/supabase_session.dart';

const _kAccessToken = 'sonus.console.accessToken';
const _kRefreshToken = 'sonus.console.refreshToken';
const _kExpiresAt = 'sonus.console.expiresAt';
const _kUserId = 'sonus.console.userId';
const _kEmail = 'sonus.console.email';
const _kDeviceId = 'sonus.console.deviceId';

/// Reads/writes the session and a stable per-install device id.
abstract class TokenStore {
  Future<void> writeSession(SupabaseSession session);
  Future<SupabaseSession?> readSession();
  Future<void> clearSession();

  /// A stable opaque id for THIS install, generated once and reused. Written to
  /// the `devices.device_id` column so the console appears as its own device.
  Future<String> deviceInstallId();
}

/// Selects the platform-appropriate store.
TokenStore createTokenStore() {
  return kIsWeb ? PrefsTokenStore() : SecureTokenStore();
}

SupabaseSession? _sessionFromParts({
  String? accessToken,
  String? refreshToken,
  String? expiresAt,
  String? userId,
  String? email,
}) {
  final token = (accessToken ?? '').trim();
  if (token.isEmpty) {
    return null;
  }
  return SupabaseSession(
    accessToken: token,
    refreshToken: (refreshToken ?? '').trim(),
    expiresAtUtc:
        DateTime.tryParse((expiresAt ?? '').trim())?.toUtc() ??
        DateTime.now().toUtc(),
    userId: (userId ?? '').trim(),
    email: (email ?? '').trim(),
  );
}

/// OS-keychain-backed store for native desktop builds.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage, Uuid? uuid})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            ),
        _uuid = uuid ?? const Uuid();

  final FlutterSecureStorage _storage;
  final Uuid _uuid;

  @override
  Future<void> writeSession(SupabaseSession session) async {
    await _storage.write(key: _kAccessToken, value: session.accessToken);
    await _storage.write(key: _kRefreshToken, value: session.refreshToken);
    await _storage.write(
      key: _kExpiresAt,
      value: session.expiresAtUtc.toUtc().toIso8601String(),
    );
    await _storage.write(key: _kUserId, value: session.userId);
    await _storage.write(key: _kEmail, value: session.email);
  }

  @override
  Future<SupabaseSession?> readSession() async {
    return _sessionFromParts(
      accessToken: await _storage.read(key: _kAccessToken),
      refreshToken: await _storage.read(key: _kRefreshToken),
      expiresAt: await _storage.read(key: _kExpiresAt),
      userId: await _storage.read(key: _kUserId),
      email: await _storage.read(key: _kEmail),
    );
  }

  @override
  Future<void> clearSession() async {
    for (final key in [_kAccessToken, _kRefreshToken, _kExpiresAt, _kUserId, _kEmail]) {
      await _storage.delete(key: key);
    }
  }

  @override
  Future<String> deviceInstallId() async {
    final existing = (await _storage.read(key: _kDeviceId) ?? '').trim();
    if (existing.isNotEmpty) {
      return existing;
    }
    final id = _uuid.v4();
    await _storage.write(key: _kDeviceId, value: id);
    return id;
  }
}

/// Browser-storage-backed store for web / mobile-web builds.
class PrefsTokenStore implements TokenStore {
  PrefsTokenStore({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<void> writeSession(SupabaseSession session) async {
    final prefs = await _p;
    await prefs.setString(_kAccessToken, session.accessToken);
    await prefs.setString(_kRefreshToken, session.refreshToken);
    await prefs.setString(
      _kExpiresAt,
      session.expiresAtUtc.toUtc().toIso8601String(),
    );
    await prefs.setString(_kUserId, session.userId);
    await prefs.setString(_kEmail, session.email);
  }

  @override
  Future<SupabaseSession?> readSession() async {
    final prefs = await _p;
    return _sessionFromParts(
      accessToken: prefs.getString(_kAccessToken),
      refreshToken: prefs.getString(_kRefreshToken),
      expiresAt: prefs.getString(_kExpiresAt),
      userId: prefs.getString(_kUserId),
      email: prefs.getString(_kEmail),
    );
  }

  @override
  Future<void> clearSession() async {
    final prefs = await _p;
    for (final key in [_kAccessToken, _kRefreshToken, _kExpiresAt, _kUserId, _kEmail]) {
      await prefs.remove(key);
    }
  }

  @override
  Future<String> deviceInstallId() async {
    final prefs = await _p;
    final existing = (prefs.getString(_kDeviceId) ?? '').trim();
    if (existing.isNotEmpty) {
      return existing;
    }
    final id = _uuid.v4();
    await prefs.setString(_kDeviceId, id);
    return id;
  }
}
