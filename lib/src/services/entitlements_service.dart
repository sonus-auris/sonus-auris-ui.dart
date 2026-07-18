// Reads the account's plan/device-limit from Supabase. Read-only by RLS —
// entitlements are written server-side by billing processors (service role).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart' as interfaces;

import '../config/console_config.dart';
import 'key_policy.dart';

/// Devices included with the free tier when the account has no entitlement row.
const int kFreeTierDeviceLimit = 2;

/// The account's current plan; free/2 by default when no row exists.
class Entitlement {
  const Entitlement({
    this.plan = 'free',
    this.deviceLimit = kFreeTierDeviceLimit,
    this.features = const <String, Object?>{},
    this.source = 'none',
    this.currentPeriodEnd,
  });

  factory Entitlement.fromRow(interfaces.Entitlement row) {
    return Entitlement(
      plan: row.plan.trim().isEmpty ? 'free' : row.plan.trim(),
      deviceLimit: row.deviceLimit < 0 ? 0 : row.deviceLimit,
      features: row.features,
      source: row.source.trim().isEmpty ? 'none' : row.source.trim(),
      currentPeriodEnd: DateTime.tryParse((row.currentPeriodEnd ?? '').trim()),
    );
  }

  final String plan;
  final int deviceLimit;
  final Map<String, Object?> features;
  final String source;
  final DateTime? currentPeriodEnd;

  bool get isPlus => plan.trim().toLowerCase() == 'plus';
  bool hasFeature(String key) => features[key] == true;

  static const Entitlement free = Entitlement();
}

typedef EntitlementResult = ({Entitlement entitlement, String? error});

class EntitlementsService {
  EntitlementsService({
    required this.config,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client();

  final ConsoleConfig config;
  final http.Client _http;
  final Duration requestTimeout;

  /// The signed-in user's entitlement row, or the free-tier default when the
  /// account has none (a missing row is not an error).
  Future<EntitlementResult> fetch(String accessToken) async {
    final Uri uri;
    try {
      uri = _restUri().replace(
        queryParameters: const {'select': '*', 'limit': '1'},
      );
    } on FormatException catch (e) {
      return (entitlement: Entitlement.free, error: e.message);
    }
    try {
      final response = await _http
          .get(uri, headers: _headers(accessToken))
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          entitlement: Entitlement.free,
          error: 'Entitlements read failed (${response.statusCode}).',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        try {
          return (
            entitlement: Entitlement.fromRow(
              interfaces.Entitlement.fromJson(
                (decoded.first as Map).cast<String, Object?>(),
              ),
            ),
            error: null,
          );
        } catch (_) {
          return (entitlement: Entitlement.free, error: null);
        }
      }
      return (entitlement: Entitlement.free, error: null);
    } catch (e) {
      return (entitlement: Entitlement.free, error: 'Entitlements read error: $e');
    }
  }

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
      pathSegments: [...baseSegments, 'rest', 'v1', interfaces.entitlementsTable],
    );
  }

  Map<String, String> _headers(String accessToken) {
    return {
      'apikey': config.supabaseAnonKey.trim(),
      'authorization': 'Bearer ${accessToken.trim()}',
      'accept': 'application/json',
    };
  }

  void close() {
    _http.close();
  }
}
