// Persistence for the session + this install's device id.
//
// Web-safe by construction: an abstract [TokenStore] with two implementations
// chosen at runtime by [kIsWeb]. Native desktop uses the OS keychain via
// flutter_secure_storage. Web sessions stay in memory because a Supabase
// refresh token is a long-lived bearer credential and browser preferences are
// readable by injected script. Only the non-secret install id and the pending
// magic-link PKCE state (useless without the emailed link) are persisted on
// web.
import 'dart:convert';

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
const _kPendingAuth = 'sonus.console.pendingAuth.v1';

class PendingMagicLink {
  const PendingMagicLink({
    required this.codeVerifier,
    required this.email,
    required this.supabaseUrl,
    required this.redirectUrl,
    required this.requestedAtUtc,
  });

  final String codeVerifier;
  final String email;
  final String supabaseUrl;
  final String redirectUrl;
  final DateTime requestedAtUtc;

  bool isExpired({
    DateTime? now,
    Duration maximumAge = const Duration(minutes: 15),
  }) {
    final reference = (now ?? DateTime.now()).toUtc();
    final requested = requestedAtUtc.toUtc();
    return requested.isAfter(reference.add(const Duration(minutes: 1))) ||
        !reference.isBefore(requested.add(maximumAge));
  }

  String encode() => jsonEncode({
    'code_verifier': codeVerifier,
    'email': email,
    'supabase_url': supabaseUrl,
    'redirect_url': redirectUrl,
    'requested_at': requestedAtUtc.toUtc().toIso8601String(),
  });

  factory PendingMagicLink.decode(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map) {
      throw const FormatException('Pending magic-link state is invalid.');
    }
    final json = value.cast<String, Object?>();
    final requested = DateTime.tryParse(
      (json['requested_at'] as String? ?? '').trim(),
    );
    if (requested == null) {
      throw const FormatException('Pending magic-link timestamp is invalid.');
    }
    return PendingMagicLink(
      codeVerifier: (json['code_verifier'] as String? ?? '').trim(),
      email: (json['email'] as String? ?? '').trim(),
      supabaseUrl: (json['supabase_url'] as String? ?? '').trim(),
      redirectUrl: (json['redirect_url'] as String? ?? '').trim(),
      requestedAtUtc: requested.toUtc(),
    );
  }
}

/// Reads/writes the session and a stable per-install device id.
abstract class TokenStore {
  Future<void> writeSession(SupabaseSession session);
  Future<SupabaseSession?> readSession();
  Future<void> clearSession();
  Future<void> writePendingMagicLink(PendingMagicLink pending);
  Future<PendingMagicLink?> readPendingMagicLink();
  Future<void> clearPendingMagicLink();

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
    : _storage =
          storage ??
          const FlutterSecureStorage(
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
    for (final key in [
      _kAccessToken,
      _kRefreshToken,
      _kExpiresAt,
      _kUserId,
      _kEmail,
    ]) {
      await _storage.delete(key: key);
    }
  }

  @override
  Future<void> writePendingMagicLink(PendingMagicLink pending) {
    return _storage.write(key: _kPendingAuth, value: pending.encode());
  }

  @override
  Future<PendingMagicLink?> readPendingMagicLink() async {
    final raw = await _storage.read(key: _kPendingAuth);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      return PendingMagicLink.decode(raw);
    } catch (_) {
      await clearPendingMagicLink();
      return null;
    }
  }

  @override
  Future<void> clearPendingMagicLink() {
    return _storage.delete(key: _kPendingAuth);
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
  SupabaseSession? _session;
  bool _legacySessionPurged = false;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> _purgeLegacyBrowserSession() async {
    if (_legacySessionPurged) {
      return;
    }
    final prefs = await _p;
    for (final key in [
      _kAccessToken,
      _kRefreshToken,
      _kExpiresAt,
      _kUserId,
      _kEmail,
    ]) {
      await prefs.remove(key);
    }
    _legacySessionPurged = true;
  }

  @override
  Future<void> writeSession(SupabaseSession session) async {
    await _purgeLegacyBrowserSession();
    _session = session;
  }

  @override
  Future<SupabaseSession?> readSession() async {
    await _purgeLegacyBrowserSession();
    return _session;
  }

  @override
  Future<void> clearSession() async {
    await _purgeLegacyBrowserSession();
    _session = null;
  }

  @override
  Future<void> writePendingMagicLink(PendingMagicLink pending) async {
    final prefs = await _p;
    await prefs.setString(_kPendingAuth, pending.encode());
  }

  @override
  Future<PendingMagicLink?> readPendingMagicLink() async {
    final prefs = await _p;
    final raw = prefs.getString(_kPendingAuth);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      return PendingMagicLink.decode(raw);
    } catch (_) {
      await prefs.remove(_kPendingAuth);
      return null;
    }
  }

  @override
  Future<void> clearPendingMagicLink() async {
    final prefs = await _p;
    await prefs.remove(_kPendingAuth);
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
