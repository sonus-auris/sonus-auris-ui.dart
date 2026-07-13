import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/services/settings_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('Supabase session survives secure-storage round trip', () async {
    final store = SettingsStore(secureStorage: const FlutterSecureStorage());
    const saved = CloudSecrets(
      s3AccessKeyId: 's3-access',
      s3SecretAccessKey: 's3-secret',
      supabaseAccessToken: 'access-token',
      supabaseRefreshToken: 'refresh-token',
      supabaseAccessTokenExpiresAt: '2026-07-13T12:00:00.000Z',
      supabaseEmail: 'person@example.com',
    );

    await store.saveSecrets(saved);
    final restored = await store.loadSecrets();

    expect(restored.supabaseAccessToken, 'access-token');
    expect(restored.supabaseRefreshToken, 'refresh-token');
    expect(restored.supabaseAccessTokenExpiresAt, '2026-07-13T12:00:00.000Z');
    expect(restored.supabaseEmail, 'person@example.com');
    expect(restored.s3AccessKeyId, 's3-access');
  });

  test('sign-out clearing removes only Supabase identity fields', () async {
    final store = SettingsStore(secureStorage: const FlutterSecureStorage());
    const signedIn = CloudSecrets(
      s3AccessKeyId: 's3-access',
      s3SecretAccessKey: 's3-secret',
      backendDeviceToken: 'device-token',
      supabaseAccessToken: 'access-token',
      supabaseRefreshToken: 'refresh-token',
      supabaseEmail: 'person@example.com',
    );

    await store.saveSecrets(signedIn);
    await store.saveSecrets(
      signedIn.withoutSupabaseSession().copyWith(backendDeviceToken: ''),
    );
    final restored = await store.loadSecrets();

    expect(restored.hasSupabaseSession, isFalse);
    expect(restored.supabaseEmail, isEmpty);
    expect(restored.backendDeviceToken, isEmpty);
    expect(restored.s3AccessKeyId, 's3-access');
    expect(restored.s3SecretAccessKey, 's3-secret');
  });
}
