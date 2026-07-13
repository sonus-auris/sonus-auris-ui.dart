import 'dart:convert';

const String unsafeSupabaseKeyMessage =
    'Use a Supabase publishable or anon key, never a secret or service-role key.';

/// Validates that a user-entered Supabase project key is safe to embed in a
/// client. This intentionally returns only a fixed message and never includes
/// any part of the supplied key.
String? validateSupabaseClientKey(String? value) {
  final key = value?.trim() ?? '';
  if (key.isEmpty) {
    return 'Enter the publishable or anon key.';
  }
  if (key.toLowerCase().startsWith('sb_secret_')) {
    return unsafeSupabaseKeyMessage;
  }
  final role = _legacyJwtRole(key);
  if (role == 'service_role' || role == 'supabase_admin') {
    return unsafeSupabaseKeyMessage;
  }
  return null;
}

void requireSafeSupabaseClientKey(String? value) {
  final error = validateSupabaseClientKey(value);
  if (error != null) {
    throw FormatException(error);
  }
}

String? _legacyJwtRole(String key) {
  final parts = key.split('.');
  if (parts.length != 3) {
    return null;
  }
  try {
    final payloadBytes = base64Url.decode(base64Url.normalize(parts[1]));
    final payload = jsonDecode(utf8.decode(payloadBytes));
    if (payload is! Map<String, dynamic>) {
      return null;
    }
    return payload['role']?.toString().trim().toLowerCase();
  } on FormatException {
    return null;
  }
}
