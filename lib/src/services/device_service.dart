// PostgREST client for the owner-scoped `devices` table, plus the pure
// device-limit gate the console shares with its tests.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart' as interfaces;

import '../config/console_config.dart';
import 'key_policy.dart';

/// Active recorder devices — non-revoked rows with role `recorder`. These are
/// the ones that count against the account's device limit. The console itself
/// registers as a `viewer`, so it never consumes a recorder slot.
List<interfaces.DeviceRecord> activeRecorderDevices(
  List<interfaces.DeviceRecord> devices,
) {
  return devices
      .where(
        (d) =>
            (d.revokedAt ?? '').trim().isEmpty &&
            d.role.trim().toLowerCase() == 'recorder',
      )
      .toList(growable: false);
}

/// The device ids that are OVER the account's limit: the `limit` most recently
/// seen recorders stay unlocked; everything staler is locked (viewable only
/// after upgrading). Pure and deterministic (matches the mobile soft-gate).
///
/// Ordering: `last_seen_at` desc, then `created_at` desc, then `device_id`.
Set<String> lockedDeviceIds(
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
    if (bySeen != 0) return bySeen;
    final byCreated = parse(b.createdAt).compareTo(parse(a.createdAt));
    if (byCreated != 0) return byCreated;
    return a.deviceId.compareTo(b.deviceId);
  });
  return {for (final d in active.skip(limit)) d.deviceId};
}

typedef DevicesResult = ({List<interfaces.DeviceRecord> devices, String? error});

/// Reads and mutates the account's `devices` rows (RLS confines everything to
/// the signed-in owner). The console lists all rows, registers itself as a
/// viewer, and renames/revokes recorders.
class DeviceService {
  DeviceService({
    required this.config,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client();

  final ConsoleConfig config;
  final http.Client _http;
  final Duration requestTimeout;

  Future<DevicesResult> listDevices(String accessToken) async {
    final Uri uri;
    try {
      uri = _restUri().replace(
        queryParameters: const {'select': '*', 'order': 'last_seen_at.desc'},
      );
    } on FormatException catch (e) {
      return (devices: const <interfaces.DeviceRecord>[], error: e.message);
    }
    try {
      final response = await _http
          .get(uri, headers: _headers(accessToken))
          .timeout(requestTimeout);
      if (!_ok(response)) {
        return (
          devices: const <interfaces.DeviceRecord>[],
          error: 'Devices read failed (${response.statusCode}).',
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
        if (row is Map) {
          try {
            devices.add(interfaces.DeviceRecord.fromJson(row.cast<String, Object?>()));
          } catch (_) {
            // skip a malformed row rather than fail the whole listing
          }
        }
      }
      return (devices: devices, error: null);
    } catch (e) {
      return (devices: const <interfaces.DeviceRecord>[], error: 'Devices read error: $e');
    }
  }

  /// Registers this console install as a `viewer` device, or refreshes its
  /// heartbeat. `display_name` is only sent on first registration so a later
  /// rename in the UI sticks. `user_id` is never sent (server default).
  Future<String?> registerSelf({
    required String accessToken,
    required String deviceId,
    required String displayName,
    required String platform,
    String? appVersion,
    DateTime? nowUtc,
  }) async {
    final lastSeen = (nowUtc ?? DateTime.now().toUtc()).toUtc().toIso8601String();
    final Uri uri;
    try {
      uri = _restUri().replace(
        queryParameters: const {'on_conflict': 'user_id,device_id'},
      );
    } on FormatException catch (e) {
      return e.message;
    }
    final headers = _headers(accessToken)
      ..['prefer'] = 'resolution=merge-duplicates';
    final row = <String, Object?>{
      'device_id': deviceId,
      'display_name': displayName,
      'platform': platform,
      'role': 'viewer',
      if ((appVersion ?? '').trim().isNotEmpty) 'app_version': appVersion!.trim(),
      'last_seen_at': lastSeen,
    };
    try {
      final response = await _http
          .post(uri, headers: headers, body: jsonEncode([row]))
          .timeout(requestTimeout);
      return _ok(response)
          ? null
          : 'Registering the console failed (${response.statusCode}).';
    } catch (e) {
      return 'Registering the console failed: $e';
    }
  }

  Future<String?> rename({
    required String accessToken,
    required String deviceId,
    required String displayName,
  }) {
    return _patch(accessToken, deviceId, {'display_name': displayName.trim()});
  }

  Future<String?> setRevoked({
    required String accessToken,
    required String deviceId,
    required bool revoked,
    DateTime? nowUtc,
  }) {
    return _patch(accessToken, deviceId, {
      'revoked_at': revoked
          ? (nowUtc ?? DateTime.now().toUtc()).toUtc().toIso8601String()
          : null,
    });
  }

  Future<String?> remove({
    required String accessToken,
    required String deviceId,
  }) async {
    final Uri uri;
    try {
      uri = _restUri().replace(
        queryParameters: {'device_id': 'eq.$deviceId'},
      );
    } on FormatException catch (e) {
      return e.message;
    }
    try {
      final response = await _http
          .delete(uri, headers: _headers(accessToken))
          .timeout(requestTimeout);
      return _ok(response) ? null : 'Removing the device failed (${response.statusCode}).';
    } catch (e) {
      return 'Removing the device failed: $e';
    }
  }

  Future<String?> _patch(
    String accessToken,
    String deviceId,
    Map<String, Object?> patch,
  ) async {
    final Uri uri;
    try {
      uri = _restUri().replace(queryParameters: {'device_id': 'eq.$deviceId'});
    } on FormatException catch (e) {
      return e.message;
    }
    try {
      final response = await _http
          .patch(uri, headers: _headers(accessToken), body: jsonEncode(patch))
          .timeout(requestTimeout);
      return _ok(response) ? null : 'Updating the device failed (${response.statusCode}).';
    } catch (e) {
      return 'Updating the device failed: $e';
    }
  }

  bool _ok(http.Response r) => r.statusCode >= 200 && r.statusCode < 300;

  Uri _restUri() {
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
    return base.replace(
      pathSegments: [...baseSegments, 'rest', 'v1', interfaces.devicesTable],
    );
  }

  Map<String, String> _headers(String accessToken) {
    return {
      'apikey': config.supabaseAnonKey.trim(),
      'authorization': 'Bearer ${accessToken.trim()}',
      'content-type': 'application/json',
      'accept': 'application/json',
    };
  }

  void close() {
    _http.close();
  }
}
