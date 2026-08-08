// Proves the infra-managed client config actually reaches a real on-device
// build. AppConfig reads SONUS_SUPABASE_URL / SONUS_SUPABASE_ANON_KEY /
// SONUS_BACKEND_BASE_URL through String.fromEnvironment, which is resolved at
// COMPILE time — so these assertions only pass when the values were supplied as
// --dart-define (as scripts/emulator/run-with-config.sh does from the
// sonus-auris.infra sops env). Run with the same defines, e.g.:
//   flutter test integration_test/env_config_smoke_test.dart \
//     --dart-define-from-file=<generated-from env/dec/dev.env>
import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('backend base URL is compiled in from the environment', () {
    expect(
      AppConfig.defaultBackendBaseUrl,
      isNotEmpty,
      reason: 'SONUS_BACKEND_BASE_URL was not supplied as a --dart-define',
    );
    final uri = Uri.parse(AppConfig.defaultBackendBaseUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, isNotEmpty);
    // The default flows through to a constructed AppConfig with no override.
    expect(const AppConfig(deviceId: 'env-smoke').backendBaseUrl,
        AppConfig.defaultBackendBaseUrl);
  });

  test('supabase client config is compiled in and client-safe', () {
    expect(AppConfig.defaultSupabaseUrl, startsWith('https://'));
    expect(AppConfig.defaultSupabaseAnonKey, isNotEmpty);
    // A service-role/secret key must never be compiled into the client.
    expect(AppConfig.defaultSupabaseAnonKey, isNot(startsWith('sb_secret_')));
    expect(
      const AppConfig(deviceId: 'env-smoke').hasSupabaseAuthConfig,
      isTrue,
      reason: 'AppConfig should report Supabase reachable with the compiled key',
    );
  });
}
