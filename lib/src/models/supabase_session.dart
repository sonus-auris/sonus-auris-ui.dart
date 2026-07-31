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

bool _claimsHavePasswordlessFirstFactor(Map<String, dynamic> claims) {
  final rawAmr = claims['amr'];
  if (rawAmr is! List) {
    return false;
  }
  final methods = rawAmr
      .whereType<Map>()
      .map((entry) => entry['method'])
      .whereType<String>()
      .map((method) => method.trim().toLowerCase())
      .toSet();
  return !methods.contains('password') &&
      methods.any(
        (method) => const {'otp', 'magiclink', 'email/signup'}.contains(method),
      );
}

bool supabaseJwtHasPasswordlessFirstFactor(String accessToken) {
  final claims = decodeSupabaseJwtPayload(accessToken);
  return claims != null && _claimsHavePasswordlessFirstFactor(claims);
}

/// True only when the token records a passwordless email first factor, no
/// password method, and a completed second factor.
bool supabaseJwtIsPasswordlessAal2(String accessToken) {
  final claims = decodeSupabaseJwtPayload(accessToken);
  return claims != null &&
      claims['aal'] == 'aal2' &&
      _claimsHavePasswordlessFirstFactor(claims);
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

  bool get isPasswordlessAal2 => supabaseJwtIsPasswordlessAal2(accessToken);

  bool get hasPasswordlessFirstFactor =>
      supabaseJwtHasPasswordlessFirstFactor(accessToken);

  /// Parses a GoTrue token response (`/auth/v1/token`, `/auth/v1/signup`).
  factory SupabaseSession.fromJson(Map<String, dynamic> json, {DateTime? now}) {
    final accessToken = (json['access_token'] as String? ?? '').trim();
    if (accessToken.isEmpty) {
      throw const FormatException('Supabase response had no access_token.');
    }
    final claims = decodeSupabaseJwtPayload(accessToken);
    if (claims == null) {
      throw const FormatException(
        'Supabase returned a malformed access token.',
      );
    }
    final reference = (now ?? DateTime.now()).toUtc();
    final expiresAtUtc = _resolveExpiry(json, claims, reference);
    if (!expiresAtUtc.isAfter(reference)) {
      throw const FormatException('Supabase returned an expired access token.');
    }
    final user = json['user'];
    final userMap = user is Map<String, dynamic> ? user : const {};
    final userId = (claims['sub'] is String ? claims['sub'] as String : '')
        .trim();
    if (userId.isEmpty) {
      throw const FormatException('Supabase access token has no subject.');
    }
    final responseUserId = (userMap['id'] as String? ?? '').trim();
    if (responseUserId.isNotEmpty && responseUserId != userId) {
      throw const FormatException(
        'Supabase response identity did not match its access token.',
      );
    }
    return SupabaseSession(
      accessToken: accessToken,
      refreshToken: (json['refresh_token'] as String? ?? '').trim(),
      expiresAtUtc: expiresAtUtc,
      userId: userId,
      email:
          (userMap['email'] as String? ??
                  (claims['email'] is String ? claims['email'] as String : ''))
              .trim(),
    );
  }

  static DateTime _resolveExpiry(
    Map<String, dynamic> json,
    Map<String, dynamic> claims,
    DateTime nowUtc,
  ) {
    final tokenExpiryEpoch = claims['exp'];
    if (tokenExpiryEpoch is! num) {
      throw const FormatException('Supabase access token has no expiry.');
    }
    var earliest = DateTime.fromMillisecondsSinceEpoch(
      (tokenExpiryEpoch * 1000).round(),
      isUtc: true,
    );
    final expiresAtEpoch = json['expires_at'];
    if (expiresAtEpoch is num) {
      final responseExpiry = DateTime.fromMillisecondsSinceEpoch(
        (expiresAtEpoch * 1000).round(),
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
}
