// App-wide OAuth redirect config and the browser leg of the music OAuth flow.
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// App-wide OAuth redirect settings. Client ids are injected at build time
/// (`--dart-define=SPOTIFY_CLIENT_ID=… --dart-define=SOUNDCLOUD_CLIENT_ID=…`)
/// so no secrets live in source. The redirect URI's scheme must be registered
/// in the iOS Info.plist (CFBundleURLSchemes) and Android manifest.
class MusicOAuthConstants {
  static const String callbackScheme = 'sonusauris';
  static const String redirectUri = 'sonusauris://oauth/callback';
  static const String spotifyClientId =
      String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const String soundCloudClientId =
      String.fromEnvironment('SOUNDCLOUD_CLIENT_ID');
}

/// Runs the browser leg of an OAuth flow and returns the redirect URL (with the
/// `code`/`state` query params), or null if the user cancelled or it failed.
abstract class OAuthBrowser {
  Future<Uri?> authorize({required Uri url, required String callbackScheme});
}

class FlutterWebAuthBrowser implements OAuthBrowser {
  const FlutterWebAuthBrowser();

  @override
  Future<Uri?> authorize({
    required Uri url,
    required String callbackScheme,
  }) async {
    try {
      final result = await FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: callbackScheme,
      );
      return Uri.tryParse(result);
    } catch (_) {
      return null;
    }
  }
}
