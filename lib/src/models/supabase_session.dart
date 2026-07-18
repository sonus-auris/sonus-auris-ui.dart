import 'dart:convert';

/// Decodes the `aal` (authenticator assurance level) claim from a Supabase
/// access-token JWT without verifying the signature — the value is only used
/// for client-side UX decisions ("ask for the second factor"), never as a
/// security boundary. Returns null for anything that is not a readable JWT.
///
/// GoTrue emits `aal1` after a first-factor sign-in and `aal2` once an MFA
/// factor has been verified for the session.
String? supabaseJwtAal(String accessToken) {
  final claims = decodeSupabaseJwtPayload(accessToken);
  final aal = claims?['aal'];
  if (aal is! String) {
    return null;
  }
  final normalized = aal.trim().toLowerCase();
  return normalized.isEmpty ? null : normalized;
}

/// Decodes a JWT's payload segment (base64url JSON) into a map. Pure and
/// side-effect free; returns null instead of throwing on malformed input.
Map<String, dynamic>? decodeSupabaseJwtPayload(String token) {
  final parts = token.trim().split('.');
  if (parts.length != 3) {
    return null;
  }
  try {
    final bytes = base64Url.decode(base64Url.normalize(parts[1]));
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

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

  /// Authenticator assurance level decoded from [accessToken] (`aal1`/`aal2`),
  /// or null when the token carries no readable claim.
  String? get aal => supabaseJwtAal(accessToken);

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
