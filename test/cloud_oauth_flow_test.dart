import 'package:audio_dashcam/src/services/cloud_oauth_flow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hosted callback preserves HTTPS host and explicit port', () {
    final callback = hostedCloudOAuthRedirect(
      'https://api.sonusauris.app:8443/api/mobile/v1',
    );

    expect(
      callback,
      Uri.parse('https://api.sonusauris.app:8443/oauth/callback'),
    );
  });

  test('manual desktop callback uses its separately registered HTTPS path', () {
    expect(
      hostedCloudOAuthManualRedirect(
        'https://api.sonusauris.app:8443/api/mobile/v1',
      ),
      Uri.parse('https://api.sonusauris.app:8443/oauth/manual-callback'),
    );
  });

  test('hosted callback permits loopback HTTP only', () {
    expect(
      hostedCloudOAuthRedirect('http://localhost:8126/api'),
      Uri.parse('http://localhost:8126/oauth/callback'),
    );
    expect(hostedCloudOAuthRedirect('http://10.0.2.2:8126/api'), isNull);
    expect(hostedCloudOAuthRedirect('http://example.test/api'), isNull);
    expect(hostedCloudOAuthManualRedirect('http://example.test/api'), isNull);
  });

  test('app callback is pinned to the OAuth host and path', () {
    expect(
      isCloudOAuthAppCallback(
        Uri.parse(
          'sonusauris://oauth/callback?state=state&code=authorization-code',
        ),
      ),
      isTrue,
    );
    expect(
      isCloudOAuthAppCallback(
        Uri.parse('sonusauris://auth/callback?code=authorization-code'),
      ),
      isFalse,
    );
    expect(
      isCloudOAuthAppCallback(
        Uri.parse('sonusauris://oauth/other?code=authorization-code'),
      ),
      isFalse,
    );
  });

  test('callback extracts a code only when state matches', () {
    final callback = Uri.parse(
      'sonusauris://oauth/callback?state=expected&code=authorization-code',
    );

    expect(
      authorizationCodeFromCloudOAuthCallback(
        callback,
        expectedState: 'expected',
      ),
      'authorization-code',
    );
    expect(
      () => authorizationCodeFromCloudOAuthCallback(
        callback,
        expectedState: 'different',
      ),
      throwsFormatException,
    );
  });

  test('callback surfaces a provider denial and never treats it as a code', () {
    final callback = Uri.parse(
      'sonusauris://oauth/callback?state=expected'
      '&error=access_denied&error_description=User%20cancelled',
    );

    expect(
      () => authorizationCodeFromCloudOAuthCallback(
        callback,
        expectedState: 'expected',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'User cancelled',
        ),
      ),
    );
  });
}
