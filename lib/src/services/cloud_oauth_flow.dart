// Shared validation and URI construction for user-owned cloud OAuth links.

const cloudOAuthCallbackScheme = 'sonusauris';
const cloudOAuthCallbackHost = 'oauth';
const cloudOAuthCallbackPath = '/callback';

/// Provider consoles register this hosted HTTPS callback. The backend forwards
/// its one-time code and state into [cloudOAuthCallbackScheme], which the
/// waiting app authentication session consumes.
Uri? hostedCloudOAuthRedirect(String backendBaseUrl) {
  return _hostedCloudOAuthRedirect(backendBaseUrl, '/oauth/callback');
}

/// Hosted callback for desktop platforms that cannot receive a custom-scheme
/// redirect from an in-app authentication session. The backend renders the
/// one-time provider code for the user to paste back into Sonus Auris.
Uri? hostedCloudOAuthManualRedirect(String backendBaseUrl) {
  return _hostedCloudOAuthRedirect(backendBaseUrl, '/oauth/manual-callback');
}

Uri? _hostedCloudOAuthRedirect(String backendBaseUrl, String path) {
  final backend = Uri.tryParse(backendBaseUrl.trim());
  if (backend == null || backend.host.trim().isEmpty) {
    return null;
  }
  final safeScheme =
      backend.scheme == 'https' ||
      (backend.scheme == 'http' && _isLoopbackHost(backend.host));
  if (!safeScheme) {
    return null;
  }
  return Uri(
    scheme: backend.scheme,
    host: backend.host,
    port: backend.hasPort ? backend.port : null,
    path: path,
  );
}

bool isCloudOAuthAppCallback(Uri uri) =>
    uri.scheme == cloudOAuthCallbackScheme &&
    uri.host == cloudOAuthCallbackHost &&
    uri.path == cloudOAuthCallbackPath;

String authorizationCodeFromCloudOAuthCallback(
  Uri callback, {
  required String expectedState,
}) {
  if (!isCloudOAuthAppCallback(callback)) {
    throw const FormatException(
      'The provider returned to an unexpected app URL.',
    );
  }
  if (callback.queryParameters['state'] != expectedState) {
    throw const FormatException(
      'The provider returned an invalid security state.',
    );
  }
  final providerError = callback.queryParameters['error'];
  if (providerError != null && providerError.isNotEmpty) {
    final description = callback.queryParameters['error_description'];
    throw FormatException(
      description == null || description.trim().isEmpty
          ? 'Provider authorization was denied ($providerError).'
          : description,
    );
  }
  final code = callback.queryParameters['code']?.trim();
  if (code == null || code.isEmpty) {
    throw const FormatException('The provider returned no authorization code.');
  }
  return code;
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1' ||
      normalized == '[::1]';
}
