// Supabase (GoTrue) multi-factor value objects, shared with the mobile app's
// model shapes so both clients speak the same MFA vocabulary.

/// One enrolled MFA factor from `GET /auth/v1/user`.
class MfaFactor {
  const MfaFactor({
    required this.id,
    required this.factorType,
    required this.status,
    this.friendlyName = '',
    this.phone = '',
  });

  final String id;
  final String factorType; // 'totp' | 'phone'
  final String status; // 'verified' | 'unverified'
  final String friendlyName;
  final String phone;

  bool get isVerified => status.trim().toLowerCase() == 'verified';
  bool get isTotp => factorType.trim().toLowerCase() == 'totp';
  bool get isPhone => factorType.trim().toLowerCase() == 'phone';

  String get typeLabel => isTotp
      ? 'Authenticator app'
      : isPhone
          ? 'Text message'
          : factorType;

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

  static List<MfaFactor> listFromUserJson(Map<String, Object?> user) {
    final raw = user['factors'];
    if (raw is! List) {
      return const [];
    }
    return [
      for (final entry in raw) ?fromJson(entry),
    ];
  }
}

/// Secrets returned when enrolling a TOTP authenticator; confirmed with a
/// challenge + verify before the factor becomes active.
class TotpEnrollment {
  const TotpEnrollment({
    required this.factorId,
    required this.secret,
    required this.uri,
    this.qrCodeSvg = '',
  });

  final String factorId;
  final String secret;
  final String uri;
  final String qrCodeSvg;
}

/// A pending SMS factor: exists but stays unverified until a texted code is
/// confirmed.
class PhoneEnrollment {
  const PhoneEnrollment({required this.factorId, required this.phone});

  final String factorId;
  final String phone;
}
