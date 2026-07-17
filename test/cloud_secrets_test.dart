import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 6, 9, 12, 0, 0);

  test('needs refresh when only a refresh token is held', () {
    const secrets = CloudSecrets(supabaseRefreshToken: 'refresh');
    expect(secrets.supabaseTokenNeedsRefresh(now: now), isTrue);
  });

  test('does not need refresh well before expiry', () {
    final secrets = CloudSecrets(
      supabaseAccessToken: 'access',
      supabaseRefreshToken: 'refresh',
      supabaseAccessTokenExpiresAt: now
          .add(const Duration(minutes: 30))
          .toIso8601String(),
    );
    expect(secrets.supabaseTokenNeedsRefresh(now: now), isFalse);
  });

  test('needs refresh within the skew window of expiry', () {
    final secrets = CloudSecrets(
      supabaseAccessToken: 'access',
      supabaseRefreshToken: 'refresh',
      supabaseAccessTokenExpiresAt: now
          .add(const Duration(seconds: 30))
          .toIso8601String(),
    );
    expect(secrets.supabaseTokenNeedsRefresh(now: now), isTrue);
  });

  test('no session means nothing to refresh', () {
    const secrets = CloudSecrets();
    expect(secrets.supabaseTokenNeedsRefresh(now: now), isFalse);
  });

  test(
    'withoutSupabaseSession clears identity but keeps cloud credentials',
    () {
      const secrets = CloudSecrets(
        s3AccessKeyId: 'akid',
        s3SecretAccessKey: 'secret',
        backendDeviceToken: 'device',
        supabaseAccessToken: 'access',
        supabaseRefreshToken: 'refresh',
        supabaseEmail: 'user@example.com',
      );
      final cleared = secrets.withoutSupabaseSession();
      expect(cleared.hasSupabaseSession, isFalse);
      expect(cleared.supabaseEmail, isEmpty);
      expect(cleared.s3AccessKeyId, 'akid');
      expect(cleared.backendDeviceToken, 'device');
    },
  );
}
