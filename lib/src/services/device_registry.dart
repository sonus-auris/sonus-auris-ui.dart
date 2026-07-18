// Registers this install in the Supabase `devices` table and keeps its
// heartbeat fresh, using only the signed-in user's token (RLS-scoped).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart'
    as interfaces;

import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import 'supabase_key_policy.dart';

/// Client app version reported on device rows, injected at build time with
/// `--dart-define=SONUS_APP_VERSION=…`. Empty (omitted from rows) when unset.
const String kSonusAppVersion = String.fromEnvironment('SONUS_APP_VERSION');

/// Human default names per contract platform value, used only on FIRST
/// registration. Later heartbeats never send display_name, so a rename made in
/// the console sticks.
String defaultDeviceDisplayName(String platform) {
  switch (platform.trim().toLowerCase()) {
    case 'android':
      return 'Android phone';
    case 'ios':
      return 'iPhone';
    case 'macos':
      return 'Mac';
    case 'windows':
      return 'Windows PC';
    case 'linux':
      return 'Linux device';
    case 'web':
      return 'Web browser';
    default:
      return 'Sonus Auris device';
  }
}

/// Active (non-revoked) recorder rows — the ones that count against the plan's
/// device limit.
List<interfaces.DeviceRecord> activeRecorderDevices(
  List<interfaces.DeviceRecord> devices,
) {
  return devices
      .where(
        (device) =>
            (device.revokedAt ?? '').trim().isEmpty &&
            device.role.trim().toLowerCase() == 'recorder',
      )
      .toList(growable: false);
}

/// Picks which active recorder devices are OVER the account's device limit:
/// the `limit` most recently seen stay in; everything staler is excess. Pure
/// so the mobile soft-gate and its tests share one definition (server-side
/// hard enforcement must reimplement the same ordering).
///
/// Ordering: `last_seen_at` descending, then `created_at` descending, then
/// `device_id` — deterministic even when timestamps tie or fail to parse.
Set<String> selectDeviceIdsOverLimit(
  List<interfaces.DeviceRecord> devices,
  int limit,
) {
  final active = [...activeRecorderDevices(devices)];
  if (limit < 0 || active.length <= limit) {
    return const <String>{};
  }
  DateTime parse(String? raw) =>
      DateTime.tryParse((raw ?? '').trim())?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  active.sort((a, b) {
    final bySeen = parse(b.lastSeenAt).compareTo(parse(a.lastSeenAt));
    if (bySeen != 0) {
      return bySeen;
    }
    final byCreated = parse(b.createdAt).compareTo(parse(a.createdAt));
    if (byCreated != 0) {
      return byCreated;
    }
    return a.deviceId.compareTo(b.deviceId);
  });
  return {for (final device in active.skip(limit)) device.deviceId};
}

/// Result of a registry read/write: the row (when known) and a short error.
typedef DeviceRegistryResult = ({interfaces.DeviceRecord? device, String? error});

/// PostgREST client for the owner-scoped `devices` table.
///
/// Every install registers itself once (with a friendly default name) and then
/// only heartbeats `last_seen_at`/`app_version`, so console renames are never
/// clobbered. `user_id` is NEVER sent — the server defaults it to `auth.uid()`
/// and RLS confines every statement to the signed-in owner.
class DeviceRegistry {
  DeviceRegistry({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration requestTimeout;

  bool canUse(AppConfig config, CloudSecrets secrets) {
    return config.supabaseUrl.trim().isNotEmpty &&
        config.supabaseAnonKey.trim().isNotEmpty &&
        secrets.hasSupabaseToken;
  }

  /// Loads this install's own row, or null when it was never registered.
  Future<DeviceRegistryResult> fetchOwnDevice({
    required AppConfig config,
    required CloudSecrets secrets,
  }) async {
    final rows = await _fetchRows(
      config,
      secrets,
      query: {
        'select': '*',
        'device_id': 'eq.${config.deviceId}',
        'limit': '1',
      },
    );
    if (rows.error != null) {
      return (device: null, error: rows.error);
    }
    return (device: rows.devices.firstOrNull, error: null);
  }

  /// Loads every device row on the account (RLS returns only the owner's).
  Future<({List<interfaces.DeviceRecord> devices, String? error})>
  fetchDevices({
    required AppConfig config,
    required CloudSecrets secrets,
  }) async {
    return _fetchRows(config, secrets, query: const {'select': '*'});
  }

  /// Registers this install on first sight, or refreshes its heartbeat.
  ///
  /// - Missing row → INSERT with the friendly default [platform] name.
  ///   `on_conflict=user_id,device_id` + merge-duplicates keeps a racing
  ///   double-registration idempotent.
  /// - Existing row → PATCH only `last_seen_at` (+ `app_version`), never
  ///   `display_name`, so a console rename sticks.
  /// - Existing but revoked → returned untouched; the caller must treat the
  ///   device as removed from the account (no heartbeat, no cloud sync).
  Future<DeviceRegistryResult> registerOrHeartbeat({
    required AppConfig config,
    required CloudSecrets secrets,
    required String platform,
    DateTime? nowUtc,
  }) async {
    if (!canUse(config, secrets)) {
      return (
        device: null,
        error: 'Supabase URL, anon key, and a signed-in session are required.',
      );
    }
    final existing = await fetchOwnDevice(config: config, secrets: secrets);
    if (existing.error != null) {
      return existing;
    }
    final lastSeenAt = (nowUtc ?? DateTime.now().toUtc())
        .toUtc()
        .toIso8601String();
    final current = existing.device;
    if (current == null) {
      return _insertOwnRow(config, secrets, platform, lastSeenAt);
    }
    if ((current.revokedAt ?? '').trim().isNotEmpty) {
      // Removed from the account in the console. Do not refresh the heartbeat;
      // surfacing the revoked row lets the controller halt cloud sync.
      return (device: current, error: null);
    }
    return _heartbeat(config, secrets, current, lastSeenAt);
  }

  Future<DeviceRegistryResult> _insertOwnRow(
    AppConfig config,
    CloudSecrets secrets,
    String platform,
    String lastSeenAt,
  ) async {
    final Uri uri;
    try {
      uri = _restUri(config).replace(
        queryParameters: const {'on_conflict': 'user_id,device_id'},
      );
    } on FormatException catch (error) {
      return (device: null, error: error.message);
    }
    final headers = _headers(config, secrets)
      ..['prefer'] = 'resolution=merge-duplicates,return=representation';
    final row = <String, Object?>{
      'device_id': config.deviceId,
      'display_name': defaultDeviceDisplayName(platform),
      'platform': platform,
      'role': 'recorder',
      if (kSonusAppVersion.trim().isNotEmpty)
        'app_version': kSonusAppVersion.trim(),
      'last_seen_at': lastSeenAt,
    };
    try {
      final response = await _httpClient
          .post(uri, headers: headers, body: jsonEncode([row]))
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          device: null,
          error:
              'Device registration failed (${response.statusCode}): '
              '${_shortBody(response.body)}',
        );
      }
      return (device: _firstRow(response.body), error: null);
    } catch (error) {
      return (device: null, error: 'Device registration error: $error');
    }
  }

  Future<DeviceRegistryResult> _heartbeat(
    AppConfig config,
    CloudSecrets secrets,
    interfaces.DeviceRecord current,
    String lastSeenAt,
  ) async {
    final Uri uri;
    try {
      uri = _restUri(config).replace(
        queryParameters: {'device_id': 'eq.${config.deviceId}'},
      );
    } on FormatException catch (error) {
      return (device: current, error: error.message);
    }
    final headers = _headers(config, secrets)
      ..['prefer'] = 'return=representation';
    final patch = <String, Object?>{
      'last_seen_at': lastSeenAt,
      if (kSonusAppVersion.trim().isNotEmpty)
        'app_version': kSonusAppVersion.trim(),
    };
    try {
      final response = await _httpClient
          .patch(uri, headers: headers, body: jsonEncode(patch))
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          device: current,
          error:
              'Device heartbeat failed (${response.statusCode}): '
              '${_shortBody(response.body)}',
        );
      }
      return (device: _firstRow(response.body) ?? current, error: null);
    } catch (error) {
      return (device: current, error: 'Device heartbeat error: $error');
    }
  }

  Future<({List<interfaces.DeviceRecord> devices, String? error})> _fetchRows(
    AppConfig config,
    CloudSecrets secrets, {
    required Map<String, String> query,
  }) async {
    if (!canUse(config, secrets)) {
      return (
        devices: const <interfaces.DeviceRecord>[],
        error: 'Supabase URL, anon key, and a signed-in session are required.',
      );
    }
    final Uri uri;
    try {
      uri = _restUri(config).replace(queryParameters: query);
    } on FormatException catch (error) {
      return (devices: const <interfaces.DeviceRecord>[], error: error.message);
    }
    try {
      final response = await _httpClient
          .get(uri, headers: _headers(config, secrets))
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          devices: const <interfaces.DeviceRecord>[],
          error:
              'Devices read failed (${response.statusCode}): '
              '${_shortBody(response.body)}',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        return (
          devices: const <interfaces.DeviceRecord>[],
          error: 'Devices read returned an invalid response.',
        );
      }
      final devices = <interfaces.DeviceRecord>[];
      for (final row in decoded) {
        if (row is! Map) {
          continue;
        }
        try {
          devices.add(
            interfaces.DeviceRecord.fromJson(row.cast<String, Object?>()),
          );
        } catch (_) {
          // Skip malformed rows instead of failing the whole listing.
        }
      }
      return (devices: devices, error: null);
    } catch (error) {
      return (
        devices: const <interfaces.DeviceRecord>[],
        error: 'Devices read error: $error',
      );
    }
  }

  interfaces.DeviceRecord? _firstRow(String body) {
    try {
      final decoded = jsonDecode(body);
      final row = decoded is List ? decoded.firstOrNull : decoded;
      if (row is! Map) {
        return null;
      }
      return interfaces.DeviceRecord.fromJson(row.cast<String, Object?>());
    } catch (_) {
      return null;
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
            interfaces.devicesTable,
          ],
        )
        .removeFragment();
  }

  Map<String, String> _headers(AppConfig config, CloudSecrets secrets) {
    return {
      'apikey': config.supabaseAnonKey.trim(),
      'authorization': 'Bearer ${secrets.supabaseAccessToken.trim()}',
      'content-type': 'application/json',
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
