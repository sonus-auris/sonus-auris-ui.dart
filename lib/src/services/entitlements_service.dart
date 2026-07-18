// Reads the account's plan/entitlements row from Supabase. Strictly read-only:
// RLS grants clients SELECT on their own row and nothing else — entitlements
// are written exclusively server-side by billing processors (service role).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart'
    as interfaces;

import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import 'supabase_key_policy.dart';

/// Devices included with the free tier when no entitlements row exists yet.
const int kFreeTierDeviceLimit = 2;

/// Immutable view of the account's current plan, defaulting to free/2 when
/// the account has no entitlements row.
class EntitlementsSnapshot {
  const EntitlementsSnapshot({
    this.plan = 'free',
    this.deviceLimit = kFreeTierDeviceLimit,
    this.features = const <String, Object?>{},
    this.source = 'none',
    this.currentPeriodEnd,
    required this.fetchedAtUtc,
  });

  factory EntitlementsSnapshot.fallback({DateTime? nowUtc}) {
    return EntitlementsSnapshot(
      fetchedAtUtc: (nowUtc ?? DateTime.now().toUtc()).toUtc(),
    );
  }

  factory EntitlementsSnapshot.fromRow(
    interfaces.Entitlement row, {
    DateTime? nowUtc,
  }) {
    return EntitlementsSnapshot(
      plan: row.plan.trim().isEmpty ? 'free' : row.plan.trim(),
      deviceLimit: row.deviceLimit < 0 ? 0 : row.deviceLimit,
      features: row.features,
      source: row.source.trim().isEmpty ? 'none' : row.source.trim(),
      currentPeriodEnd: DateTime.tryParse((row.currentPeriodEnd ?? '').trim()),
      fetchedAtUtc: (nowUtc ?? DateTime.now().toUtc()).toUtc(),
    );
  }

  final String plan;
  final int deviceLimit;
  final Map<String, Object?> features;
  final String source;
  final DateTime? currentPeriodEnd;
  final DateTime fetchedAtUtc;

  bool get isPlus => plan.trim().toLowerCase() == 'plus';

  /// True when a boolean feature flag is granted (e.g. `permanent_saves`).
  bool hasFeature(String key) => features[key] == true;
}

/// Fetches (and memoizes) the signed-in user's entitlements row.
class EntitlementsService {
  EntitlementsService({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
    this.cacheTtl = const Duration(minutes: 5),
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration requestTimeout;

  /// How long a fetched snapshot is served from memory before [fetch] hits
  /// the network again (use `force: true` to bypass, e.g. after a purchase).
  final Duration cacheTtl;

  EntitlementsSnapshot? _cached;

  /// Most recently fetched snapshot, if any (may be stale).
  EntitlementsSnapshot? get cached => _cached;

  /// Drops the cache, e.g. on sign-out or account switch.
  void invalidate() {
    _cached = null;
  }

  bool canUse(AppConfig config, CloudSecrets secrets) {
    return config.supabaseUrl.trim().isNotEmpty &&
        config.supabaseAnonKey.trim().isNotEmpty &&
        secrets.hasSupabaseToken;
  }

  /// Returns the account's entitlements: the cached copy while fresh, else the
  /// user's row from Supabase, else the free-tier default (a missing row is
  /// not an error — free accounts have no row until they ever pay).
  ///
  /// On read errors the previous cache (or the free default) is returned along
  /// with the error string so callers degrade gracefully.
  Future<({EntitlementsSnapshot entitlements, String? error})> fetch({
    required AppConfig config,
    required CloudSecrets secrets,
    bool force = false,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    final cached = _cached;
    if (!force &&
        cached != null &&
        now.difference(cached.fetchedAtUtc) < cacheTtl) {
      return (entitlements: cached, error: null);
    }
    if (!canUse(config, secrets)) {
      return (
        entitlements: cached ?? EntitlementsSnapshot.fallback(nowUtc: now),
        error: 'Supabase URL, anon key, and a signed-in session are required.',
      );
    }
    final Uri uri;
    try {
      uri = _restUri(
        config,
      ).replace(queryParameters: const {'select': '*', 'limit': '1'});
    } on FormatException catch (error) {
      return (
        entitlements: cached ?? EntitlementsSnapshot.fallback(nowUtc: now),
        error: error.message,
      );
    }
    try {
      final response = await _httpClient
          .get(uri, headers: _headers(config, secrets))
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          entitlements: cached ?? EntitlementsSnapshot.fallback(nowUtc: now),
          error:
              'Entitlements read failed (${response.statusCode}): '
              '${_shortBody(response.body)}',
        );
      }
      final decoded = jsonDecode(response.body);
      EntitlementsSnapshot snapshot;
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        try {
          snapshot = EntitlementsSnapshot.fromRow(
            interfaces.Entitlement.fromJson(
              (decoded.first as Map).cast<String, Object?>(),
            ),
            nowUtc: now,
          );
        } catch (_) {
          snapshot = EntitlementsSnapshot.fallback(nowUtc: now);
        }
      } else {
        // No row yet — the account is on the free tier by definition.
        snapshot = EntitlementsSnapshot.fallback(nowUtc: now);
      }
      _cached = snapshot;
      return (entitlements: snapshot, error: null);
    } catch (error) {
      return (
        entitlements: cached ?? EntitlementsSnapshot.fallback(nowUtc: now),
        error: 'Entitlements read error: $error',
      );
    }
  }

  Uri _restUri(AppConfig config) {
    requireSafeSupabaseClientKey(config.supabaseAnonKey);
    final base = Uri.parse(config.supabaseUrl.trim());
    if (base.host.trim().isEmpty) {
      throw const FormatException('Supabase URL must include a host.');
    }
    if (base.scheme != 'https' &&
        base.host != 'localhost' &&
        base.host != '127.0.0.1') {
      throw const FormatException(
        'Supabase URL must use HTTPS except localhost development.',
      );
    }
    final baseSegments = base.pathSegments.where((p) => p.isNotEmpty);
    return base
        .replace(
          pathSegments: [
            ...baseSegments,
            'rest',
            'v1',
            interfaces.entitlementsTable,
          ],
        )
        .removeFragment();
  }

  Map<String, String> _headers(AppConfig config, CloudSecrets secrets) {
    return {
      'apikey': config.supabaseAnonKey.trim(),
      'authorization': 'Bearer ${secrets.supabaseAccessToken.trim()}',
      'accept': 'application/json',
    };
  }

  String _shortBody(String body) {
    final trimmed = body.trim();
    return trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed;
  }

  void close() {
    _httpClient.close();
  }
}
