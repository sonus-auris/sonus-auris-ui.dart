// The signed-in Supabase session held by the console.
import '../util/jwt_claims.dart';

/// A GoTrue session: the access/refresh tokens plus the identity the console
/// shows and scopes requests to. Parsed defensively from token/verify/refresh
/// responses, which vary in which fields they include.
class SupabaseSession {
  const SupabaseSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAtUtc,
    required this.userId,
    required this.email,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAtUtc;
  final String userId;
  final String email;

  /// The `aal` claim on the current access token: `aal1` (first factor only)
  /// or `aal2` (a second factor has been verified this session).
  String get aal => aalFromJwt(accessToken);

  bool get isEmpty => accessToken.trim().isEmpty;

  /// True within [skew] of expiry, so the console refreshes proactively rather
  /// than letting a request fail.
  bool needsRefresh({
    DateTime? now,
    Duration skew = const Duration(minutes: 2),
  }) {
    final reference = (now ?? DateTime.now()).toUtc();
    return reference.isAfter(expiresAtUtc.subtract(skew));
  }

  factory SupabaseSession.fromJson(Map<String, Object?> json) {
    final accessToken = (json['access_token'] as String? ?? '').trim();
    if (accessToken.isEmpty) {
      throw const FormatException(
        'Sign-in response contained no access token.',
      );
    }
    final claims = decodeJwtClaims(accessToken);
    final user = json['user'];
    final userMap = user is Map ? user.cast<String, Object?>() : const {};
    return SupabaseSession(
      accessToken: accessToken,
      refreshToken: (json['refresh_token'] as String? ?? '').trim(),
      expiresAtUtc: _expiry(json, claims),
      userId: (userMap['id'] as String? ?? claims['sub']?.toString() ?? '')
          .trim(),
      email: (userMap['email'] as String? ?? claims['email']?.toString() ?? '')
          .trim(),
    );
  }

  /// Prefers an absolute `expires_at` (epoch seconds); falls back to
  /// `expires_in` (seconds from now), then the token's own `exp` claim, then a
  /// conservative one-hour default.
  static DateTime _expiry(
    Map<String, Object?> json,
    Map<String, Object?> claims,
  ) {
    final expiresAt = json['expires_at'];
    if (expiresAt is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        (expiresAt * 1000).round(),
        isUtc: true,
      );
    }
    final expiresIn = json['expires_in'];
    if (expiresIn is num) {
      return DateTime.now().toUtc().add(Duration(seconds: expiresIn.round()));
    }
    final exp = claims['exp'];
    if (exp is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        (exp * 1000).round(),
        isUtc: true,
      );
    }
    return DateTime.now().toUtc().add(const Duration(hours: 1));
  }

  SupabaseSession copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAtUtc,
    String? userId,
    String? email,
  }) {
    return SupabaseSession(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAtUtc: expiresAtUtc ?? this.expiresAtUtc,
      userId: userId ?? this.userId,
      email: email ?? this.email,
    );
  }
}
