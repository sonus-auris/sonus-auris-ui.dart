// Short-lived PKCE state that binds a Supabase magic link to this installation.
class PendingSupabaseAuth {
  const PendingSupabaseAuth({
    required this.codeVerifier,
    required this.email,
    required this.supabaseUrl,
    required this.redirectUrl,
    required this.requestedAtUtc,
  });

  final String codeVerifier;
  final String email;
  final String supabaseUrl;
  final String redirectUrl;
  final DateTime requestedAtUtc;

  bool isExpired({
    DateTime? now,
    Duration maximumAge = const Duration(minutes: 15),
  }) {
    final reference = (now ?? DateTime.now()).toUtc();
    final requested = requestedAtUtc.toUtc();
    return requested.isAfter(reference.add(const Duration(minutes: 1))) ||
        !reference.isBefore(requested.add(maximumAge));
  }

  Map<String, Object?> toJson() => {
    'code_verifier': codeVerifier,
    'email': email,
    'supabase_url': supabaseUrl,
    'redirect_url': redirectUrl,
    'requested_at': requestedAtUtc.toUtc().toIso8601String(),
  };

  factory PendingSupabaseAuth.fromJson(Map<String, Object?> json) {
    final requestedAt = DateTime.tryParse(
      (json['requested_at'] as String? ?? '').trim(),
    );
    if (requestedAt == null) {
      throw const FormatException('Pending sign-in timestamp is invalid.');
    }
    return PendingSupabaseAuth(
      codeVerifier: (json['code_verifier'] as String? ?? '').trim(),
      email: (json['email'] as String? ?? '').trim(),
      supabaseUrl: (json['supabase_url'] as String? ?? '').trim(),
      redirectUrl: (json['redirect_url'] as String? ?? '').trim(),
      requestedAtUtc: requestedAt.toUtc(),
    );
  }
}
