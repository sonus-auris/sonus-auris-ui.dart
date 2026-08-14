import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/models/client_telemetry_event.dart';
import 'package:audio_dashcam/src/models/pending_supabase_auth.dart';
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
      supabaseSessionId: '11111111-1111-4111-8111-111111111111',
      supabaseSessionStartedAt: '2026-05-01T12:00:00.000Z',
      supabaseReauthReminderCheckpoint: '1',
      supabaseUserId: '00000000-0000-4000-8000-000000000001',
      supabaseEmail: 'person@example.com',
    );

    await store.saveSecrets(saved);
    final restored = await store.loadSecrets();

    expect(restored.supabaseAccessToken, 'access-token');
    expect(restored.supabaseRefreshToken, 'refresh-token');
    expect(restored.supabaseAccessTokenExpiresAt, '2026-07-13T12:00:00.000Z');
    expect(restored.supabaseUserId, '00000000-0000-4000-8000-000000000001');
    expect(restored.supabaseSessionId, saved.supabaseSessionId);
    expect(restored.supabaseSessionStartedAt, saved.supabaseSessionStartedAt);
    expect(restored.supabaseReauthReminderCheckpointValue, 1);
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

  test('capture authentication intents persist and clear', () async {
    final store = SettingsStore(secureStorage: const FlutterSecureStorage());

    expect(await store.loadResumeCaptureAfterSignIn(), isFalse);
    expect(await store.loadAllowSignedOutRecording(), isFalse);
    await store.saveResumeCaptureAfterSignIn(true);
    await store.saveAllowSignedOutRecording(true);
    expect(await store.loadResumeCaptureAfterSignIn(), isTrue);
    expect(await store.loadAllowSignedOutRecording(), isTrue);

    await store.saveResumeCaptureAfterSignIn(false);
    await store.saveAllowSignedOutRecording(false);
    expect(await store.loadResumeCaptureAfterSignIn(), isFalse);
    expect(await store.loadAllowSignedOutRecording(), isFalse);
  });

  test('pending PKCE state is secure, expiring, and clearable', () async {
    final store = SettingsStore(secureStorage: const FlutterSecureStorage());
    final pending = PendingSupabaseAuth(
      codeVerifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
      email: 'person@example.com',
      supabaseUrl: 'https://project.supabase.co',
      redirectUrl: 'sonusauris://auth/callback',
      requestedAtUtc: DateTime.utc(2026, 7, 29, 12),
    );

    await store.savePendingSupabaseAuth(pending);
    final restored = await store.loadPendingSupabaseAuth();

    expect(restored?.codeVerifier, pending.codeVerifier);
    expect(
      restored?.isExpired(now: DateTime.utc(2026, 7, 29, 12, 10)),
      isFalse,
    );
    expect(restored?.isExpired(now: DateTime.utc(2026, 7, 29, 12, 15)), isTrue);

    await store.clearPendingSupabaseAuth();
    expect(await store.loadPendingSupabaseAuth(), isNull);
  });

  test(
    'pending PKCE state rejects future clocks and never uses preferences',
    () async {
      final store = SettingsStore(secureStorage: const FlutterSecureStorage());
      final pending = PendingSupabaseAuth(
        codeVerifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        email: 'person@example.com',
        supabaseUrl: 'https://project.supabase.co',
        redirectUrl: 'sonusauris://auth/callback',
        requestedAtUtc: DateTime.utc(2026, 7, 29, 12, 2),
      );

      await store.savePendingSupabaseAuth(pending);

      expect(pending.isExpired(now: DateTime.utc(2026, 7, 29, 12)), isTrue);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getKeys().where((key) => key.contains('pending_auth')),
        isEmpty,
      );
    },
  );

  test('corrupt pending PKCE state is rejected and removed', () async {
    const key = 'audio_dashcam.supabase.pending_auth.v1';
    FlutterSecureStorage.setMockInitialValues({key: '{"code_verifier": 3}'});
    const secureStorage = FlutterSecureStorage();
    final store = SettingsStore(secureStorage: secureStorage);

    expect(await store.loadPendingSupabaseAuth(), isNull);
    expect(await secureStorage.read(key: key), isNull);
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
