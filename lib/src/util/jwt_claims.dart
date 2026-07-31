// Unverified JWT payload decoding, used to read session claims client-side.
import 'dart:convert';

/// Decodes the payload (claims) of [token] WITHOUT verifying its signature.
///
/// The result is only used for client-side UX decisions — most importantly
/// whether to show the MFA challenge screen — never for authorization. The
/// server independently validates every token on every API call, so skipping
/// signature verification here is safe. Returns `{}` for anything that is not
/// a decodable three-part JWT.
Map<String, Object?> decodeJwtClaims(String token) {
  final parts = token.split('.');
  if (parts.length != 3) {
    return const {};
  }
  try {
    final bytes = base64Url.decode(base64Url.normalize(parts[1]));
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) {
      return decoded.cast<String, Object?>();
    }
    return const {};
  } on FormatException {
    return const {};
  } on ArgumentError {
    return const {};
  }
}

/// The authenticator assurance level (`aal` claim) carried by [accessToken].
///
/// GoTrue stamps `aal1` on plain email-OTP sessions and `aal2` once a second
/// factor has been verified. Defaults to `aal1` when the claim is absent or
/// the token cannot be decoded, which fails toward requiring the MFA
/// challenge for enrolled accounts.
String aalFromJwt(String accessToken) {
  final claim = decodeJwtClaims(accessToken)['aal'];
  final value = claim?.toString().trim().toLowerCase() ?? '';
  return value.isEmpty ? 'aal1' : value;
}

bool _hasPasswordlessFirstFactor(Map<String, Object?> claims) {
  final amr = claims['amr'];
  if (amr is! List) {
    return false;
  }
  final methods = amr
      .whereType<Map>()
      .map((entry) => entry['method']?.toString().trim().toLowerCase() ?? '')
      .where((method) => method.isNotEmpty)
      .toSet();
  const passwordlessMethods = {'otp', 'magiclink', 'email/signup'};
  return !methods.contains('password') &&
      methods.any(passwordlessMethods.contains);
}

/// Whether AMR records a passwordless email first factor and no password.
bool passwordlessFirstFactorFromJwt(String accessToken) =>
    _hasPasswordlessFirstFactor(decodeJwtClaims(accessToken));

/// True only when this session has MFA and records a passwordless email first
/// factor. This is a fail-closed client gate; the server and RLS enforce the
/// same rule after verifying the JWT signature.
bool passwordlessAal2FromJwt(String accessToken) {
  final claims = decodeJwtClaims(accessToken);
  return claims['aal']?.toString().trim().toLowerCase() == 'aal2' &&
      _hasPasswordlessFirstFactor(claims);
}
