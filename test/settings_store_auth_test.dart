import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/models/client_telemetry_event.dart';
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
      supabaseUserId: '00000000-0000-4000-8000-000000000001',
      supabaseEmail: 'person@example.com',
    );

    await store.saveSecrets(saved);
    final restored = await store.loadSecrets();

    expect(restored.supabaseAccessToken, 'access-token');
    expect(restored.supabaseRefreshToken, 'refresh-token');
    expect(restored.supabaseAccessTokenExpiresAt, '2026-07-13T12:00:00.000Z');
    expect(restored.supabaseUserId, '00000000-0000-4000-8000-000000000001');
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

  test(
    'pending telemetry persists with stable idempotency and trace ids',
    () async {
      final store = SettingsStore(secureStorage: const FlutterSecureStorage());
      final event = ClientTelemetryEvent(
        clientEventId: '11111111-1111-4111-8111-111111111111',
        level: 'error',
        event: 'flutter_error',
        message: 'sanitized message',
        occurredAtUtc: DateTime.utc(2026, 7, 17),
        sessionId: 'session-1',
        traceId: 'trace-1',
        spanId: 'span-1',
      );

      await store.savePendingTelemetry([event]);
      final restored = await store.loadPendingTelemetry();

      expect(restored, hasLength(1));
      expect(restored.single.clientEventId, event.clientEventId);
      expect(restored.single.traceId, 'trace-1');
      expect(restored.single.spanId, 'span-1');
    },
  );
}
