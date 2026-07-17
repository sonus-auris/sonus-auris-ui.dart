/// A Supabase (GoTrue) auth session: the short-lived access token, the rotating
/// refresh token, and the resolved user identity. Produced by
/// `SupabaseAuthClient` and mapped into `CloudSecrets` by the controller.
class SupabaseSession {
  const SupabaseSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAtUtc,
    this.userId = '',
    this.email = '',
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAtUtc;
  final String userId;
  final String email;

  /// Parses a GoTrue token response (`/auth/v1/token`, `/auth/v1/signup`).
  factory SupabaseSession.fromJson(Map<String, dynamic> json, {DateTime? now}) {
    final accessToken = (json['access_token'] as String? ?? '').trim();
    if (accessToken.isEmpty) {
      throw const FormatException('Supabase response had no access_token.');
    }
    final reference = (now ?? DateTime.now()).toUtc();
    final expiresAtUtc = _resolveExpiry(json, reference);
    final user = json['user'];
    final userMap = user is Map<String, dynamic> ? user : const {};
    return SupabaseSession(
      accessToken: accessToken,
      refreshToken: (json['refresh_token'] as String? ?? '').trim(),
      expiresAtUtc: expiresAtUtc,
      userId: (userMap['id'] as String? ?? '').trim(),
      email: (userMap['email'] as String? ?? '').trim(),
    );
  }

  static DateTime _resolveExpiry(Map<String, dynamic> json, DateTime nowUtc) {
    final expiresAtEpoch = json['expires_at'];
    if (expiresAtEpoch is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        (expiresAtEpoch * 1000).round(),
        isUtc: true,
      );
    }
    final expiresIn = json['expires_in'];
    final seconds = expiresIn is num ? expiresIn.round() : 3600;
    return nowUtc.add(Duration(seconds: seconds.clamp(0, 86400)));
  }
}
