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

  /// Whether the JWT proves both a passwordless first factor and MFA.
  bool get isPasswordlessAal2 => passwordlessAal2FromJwt(accessToken);

  bool get hasPasswordlessFirstFactor =>
      passwordlessFirstFactorFromJwt(accessToken);

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
    if (claims.isEmpty) {
      throw const FormatException(
        'Sign-in response contained a malformed access token.',
      );
    }
    final user = json['user'];
    final userMap = user is Map ? user.cast<String, Object?>() : const {};
    final userId = (claims['sub']?.toString() ?? '').trim();
    if (userId.isEmpty) {
      throw const FormatException('Sign-in access token contained no subject.');
    }
    final responseUserId = (userMap['id'] as String? ?? '').trim();
    if (responseUserId.isNotEmpty && responseUserId != userId) {
      throw const FormatException(
        'Sign-in response identity did not match its access token.',
      );
    }
    final nowUtc = DateTime.now().toUtc();
    final expiresAtUtc = _expiry(json, claims, nowUtc);
    if (!expiresAtUtc.isAfter(nowUtc)) {
      throw const FormatException(
        'Sign-in response contained an expired access token.',
      );
    }
    return SupabaseSession(
      accessToken: accessToken,
      refreshToken: (json['refresh_token'] as String? ?? '').trim(),
      expiresAtUtc: expiresAtUtc,
      userId: userId,
      email: (userMap['email'] as String? ?? claims['email']?.toString() ?? '')
          .trim(),
    );
  }

  /// Requires the token's signed `exp` claim, then chooses the earliest of that
  /// and any response-level expiry fields. Inconsistent metadata can only
  /// shorten a session, never extend it beyond the JWT.
  static DateTime _expiry(
    Map<String, Object?> json,
    Map<String, Object?> claims,
    DateTime nowUtc,
  ) {
    final exp = claims['exp'];
    if (exp is! num) {
      throw const FormatException('Sign-in access token contained no expiry.');
    }
    var earliest = DateTime.fromMillisecondsSinceEpoch(
      (exp * 1000).round(),
      isUtc: true,
    );
    final expiresAt = json['expires_at'];
    if (expiresAt is num) {
      final responseExpiry = DateTime.fromMillisecondsSinceEpoch(
        (expiresAt * 1000).round(),
        isUtc: true,
      );
      if (responseExpiry.isBefore(earliest)) {
        earliest = responseExpiry;
      }
    }
    final expiresIn = json['expires_in'];
    if (expiresIn is num && expiresIn > 0) {
      final responseExpiry = nowUtc.add(Duration(seconds: expiresIn.round()));
      if (responseExpiry.isBefore(earliest)) {
        earliest = responseExpiry;
      }
    }
    return earliest;
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
