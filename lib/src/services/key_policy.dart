// Guards against ever sending a privileged Supabase key from this client.
//
// The console is a public client: it must use ONLY the anon/publishable key.
// A service-role key (or the legacy `service_role` JWT) would bypass row-level
// security and hand every account's data to anyone running the app, so we
// reject those shapes before any request leaves the device.

/// Throws [FormatException] when [key] is a secret/service-role key rather than
/// a publishable anon key.
void requireSafeSupabaseClientKey(String key) {
  final trimmed = key.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Supabase anon key is required.');
  }
  if (trimmed.startsWith('sb_secret_')) {
    throw const FormatException(
      'Refusing to use a Supabase secret key in a public client.',
    );
  }
  // Legacy JWT keys embed the role in the payload; block service_role/admin.
  final lowered = trimmed.toLowerCase();
  if (lowered.contains('service_role') || lowered.contains('supabase_admin')) {
    throw const FormatException(
      'Refusing to use a service-role key in a public client.',
    );
  }
}

/// Non-throwing variant for guard clauses.
bool isSafeSupabaseClientKey(String key) {
  try {
    requireSafeSupabaseClientKey(key);
    return true;
  } on FormatException {
    return false;
  }
}
