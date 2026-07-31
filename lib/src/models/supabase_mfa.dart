// Supabase (GoTrue) multi-factor auth value objects: enrolled factors and the
// secrets returned while enrolling a TOTP authenticator.
import 'dart:convert';

/// Decodes the `aal` (Authenticator Assurance Level) claim from a GoTrue access
/// token without verifying its signature — the client only needs to know
/// whether the current session already cleared MFA (`aal2`) or must still
/// challenge a factor (`aal1`). Signature verification stays server-side (RLS).
/// Returns null when the token is malformed or carries no `aal`.
String? decodeSupabaseAal(String accessToken) {
  final payload = decodeJwtPayload(accessToken);
  final aal = payload?['aal'];
  return aal is String ? aal.trim() : null;
}

/// Base64Url-decodes the payload segment of a JWT into a JSON map. Pure and
/// signature-agnostic; returns null on any malformation.
Map<String, Object?>? decodeJwtPayload(String token) {
  final parts = token.trim().split('.');
  if (parts.length != 3) {
    return null;
  }
  try {
    var segment = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    switch (segment.length % 4) {
      case 2:
        segment += '==';
      case 3:
        segment += '=';
    }
    final decoded = utf8.decode(base64.decode(segment));
    final json = jsonDecode(decoded);
    return json is Map ? json.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}

/// One MFA factor on the signed-in user, as reported by `GET /auth/v1/user`.
class MfaFactor {
  const MfaFactor({
    required this.id,
    required this.factorType,
    required this.status,
    this.friendlyName = '',
    this.phone = '',
  });

  /// Server-issued factor id, used for challenge/verify/unenroll calls.
  final String id;

  /// `totp` (authenticator app) or `phone` (SMS one-time codes).
  final String factorType;

  /// `verified` once the user proved the factor; `unverified` while enrolling.
  final String status;

  /// User-chosen label shown in factor lists.
  final String friendlyName;

  /// E.164 phone number for phone factors (may be masked by the server).
  final String phone;

  bool get isVerified => status.trim().toLowerCase() == 'verified';
  bool get isTotp => factorType.trim().toLowerCase() == 'totp';
  bool get isPhone => factorType.trim().toLowerCase() == 'phone';

  /// Defensive parse of one entry of the `factors` array. Returns null when
  /// the entry has no usable id so callers can skip it.
  static MfaFactor? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final map = json.cast<String, Object?>();
    final id = (map['id'] as String? ?? '').trim();
    if (id.isEmpty) {
      return null;
    }
    return MfaFactor(
      id: id,
      factorType: (map['factor_type'] as String? ?? '').trim(),
      status: (map['status'] as String? ?? '').trim(),
      friendlyName: (map['friendly_name'] as String? ?? '').trim(),
      phone: (map['phone'] as String? ?? '').trim(),
    );
  }

  /// Parses the `factors` array of a GoTrue user object, skipping malformed
  /// entries instead of failing the whole read.
  static List<MfaFactor> listFromUserJson(Map<String, dynamic> user) {
    final raw = user['factors'];
    if (raw is! List) {
      return const [];
    }
    return [
      for (final entry in raw) ?fromJson(entry),
    ];
  }
}

/// Secrets returned by `POST /auth/v1/factors` for a TOTP enrollment. The
/// user scans/enters these into an authenticator app, then verifies a code to
/// activate the factor.
class TotpEnrollment {
  const TotpEnrollment({
    required this.factorId,
    required this.secret,
    required this.uri,
    this.qrCodeSvg = '',
  });

  final String factorId;

  /// Base32 shared secret for manual entry.
  final String secret;

  /// `otpauth://totp/...` provisioning URI (what the QR encodes).
  final String uri;

  /// Server-rendered QR as an SVG string; may be empty on older GoTrue.
  final String qrCodeSvg;
}

/// A pending phone (SMS) factor enrollment: the factor exists but stays
/// `unverified` until the user confirms a texted code.
class PhoneEnrollment {
  const PhoneEnrollment({required this.factorId, required this.phone});

  final String factorId;
  final String phone;
}
