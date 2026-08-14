import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/supabase_session.dart';
import 'package:audio_dashcam/src/services/supabase_auth_client.dart';

/// Integration-test-only first-factor client.
///
/// The Flutter process never receives the Shared Auth bearer secret. It talks
/// to a loopback bridge started by CI or the trusted Mac host; that bridge adds
/// the secret server-side and forwards to the isolated Shared Auth test realm.
/// The returned object is still a genuine Supabase session and all inherited
/// MFA operations continue directly against Supabase with the public anon key.
final class SharedAuthTestClient extends SupabaseAuthClient {
  factory SharedAuthTestClient({
    required String bridgeUrl,
    http.Client? httpClient,
    Duration requestTimeout = const Duration(seconds: 30),
  }) {
    final client = httpClient ?? http.Client();
    return SharedAuthTestClient._(
      client,
      bridgeUrl: bridgeUrl,
      requestTimeout: requestTimeout,
    );
  }

  SharedAuthTestClient._(
    http.Client client, {
    required String bridgeUrl,
    required super.requestTimeout,
  }) : _client = client,
       _bridgeEndpoint = _normalizeBridgeEndpoint(bridgeUrl),
       super(httpClient: client);

  static const int _maximumResponseBytes = 256 * 1024;

  final http.Client _client;
  final Uri _bridgeEndpoint;

  @override
  Future<void> sendEmailOtp({
    required AppConfig config,
    required String email,
    required String codeVerifier,
    String redirectTo = kSupabaseAuthRedirectUrl,
  }) async {
    _validateInvocation(config, email);
    // Deliberately no network call: deterministic automation must not generate
    // a real email. The following verification step requests a genuine session
    // through the loopback bridge and isolated Shared Auth test realm.
  }

  @override
  Future<SupabaseSession> verifyEmailOtp({
    required AppConfig config,
    required String email,
    required String code,
  }) async {
    final normalizedEmail = _validateInvocation(config, email);
    final normalizedCode = code.trim();
    if (!RegExp(r'^[0-9]{6}$').hasMatch(normalizedCode)) {
      throw const FormatException('Enter the 6-digit verification code.');
    }

    late final http.Response response;
    try {
      response = await _client
          .post(
            _bridgeEndpoint,
            headers: const {
              'accept': 'application/json',
              'content-type': 'application/json',
            },
            body: jsonEncode({
              'email': normalizedEmail,
              'code': normalizedCode,
            }),
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw StateError('The local authentication bridge did not respond.');
    } on http.ClientException {
      throw StateError('Could not reach the local authentication bridge.');
    }

    if (response.bodyBytes.length > _maximumResponseBytes) {
      throw StateError(
        'The local authentication bridge returned too much data.',
      );
    }
    if (response.statusCode != 200) {
      throw StateError('The isolated test sign-in was not accepted.');
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw StateError(
        'The local authentication bridge returned invalid JSON.',
      );
    }
    if (decoded is! Map) {
      throw StateError(
        'The local authentication bridge returned invalid JSON.',
      );
    }

    final session = SupabaseSession.fromJson(decoded.cast<String, dynamic>());
    if (session.email.trim().toLowerCase() != normalizedEmail) {
      throw const FormatException(
        'The isolated test session belonged to another identity.',
      );
    }
    if (session.refreshToken.trim().isEmpty) {
      throw const FormatException(
        'The isolated test session had no rotating refresh token.',
      );
    }
    if (!session.hasPasswordlessFirstFactor || session.aal != 'aal1') {
      throw const FormatException(
        'The isolated test session must stop at passwordless AAL1.',
      );
    }

    final claims = decodeSupabaseJwtPayload(session.accessToken);
    final expectedIssuer = _expectedSupabaseIssuer(config.supabaseUrl);
    if (claims == null || claims['iss'] != expectedIssuer) {
      throw const FormatException(
        'The isolated test session came from an unexpected issuer.',
      );
    }
    final audience = claims['aud'];
    final authenticated =
        audience == 'authenticated' ||
        (audience is List && audience.contains('authenticated'));
    if (!authenticated) {
      throw const FormatException(
        'The isolated test session had an unexpected audience.',
      );
    }
    return session;
  }

  String _validateInvocation(AppConfig config, String email) {
    if (!config.hasSupabaseAuthConfig) {
      throw const FormatException(
        'The test Supabase URL and public anon key are required.',
      );
    }
    _expectedSupabaseIssuer(config.supabaseUrl);
    final normalized = email.trim().toLowerCase();
    final separator = normalized.lastIndexOf('@');
    if (separator <= 0 || separator == normalized.length - 1) {
      throw const FormatException('Enter a valid synthetic test email.');
    }
    final domain = normalized.substring(separator + 1);
    if (!_reservedTestDomain(domain)) {
      throw const FormatException(
        'Automation identities must use a reserved test namespace.',
      );
    }
    return normalized;
  }

  static Uri _normalizeBridgeEndpoint(String value) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.userInfo.isNotEmpty ||
        parsed.query.isNotEmpty ||
        parsed.fragment.isNotEmpty) {
      throw const FormatException('The test bridge URL is invalid.');
    }
    final loopbackHttp = parsed.scheme == 'http' && _isLoopback(parsed.host);
    if (parsed.scheme != 'https' && !loopbackHttp) {
      throw const FormatException(
        'The test bridge must use HTTPS or an exact loopback HTTP host.',
      );
    }
    final normalizedPath = parsed.path.replaceFirst(RegExp(r'/+$'), '');
    if (normalizedPath != '/session') {
      throw const FormatException(
        'The test bridge URL must end with the exact /session path.',
      );
    }
    return parsed.replace(path: '/session');
  }

  static String _expectedSupabaseIssuer(String value) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.userInfo.isNotEmpty ||
        parsed.query.isNotEmpty ||
        parsed.fragment.isNotEmpty ||
        (parsed.path.isNotEmpty && parsed.path != '/')) {
      throw const FormatException('The test Supabase URL is invalid.');
    }
    final loopbackHttp = parsed.scheme == 'http' && _isLoopback(parsed.host);
    if (parsed.scheme != 'https' && !loopbackHttp) {
      throw const FormatException(
        'The test Supabase URL must use HTTPS or exact loopback HTTP.',
      );
    }
    return parsed.replace(path: '/auth/v1').toString();
  }

  static bool _reservedTestDomain(String domain) =>
      domain == 'example.com' ||
      domain == 'example.net' ||
      domain == 'example.org' ||
      domain.endsWith('.test') ||
      domain.endsWith('.example') ||
      domain.endsWith('.invalid');

  static bool _isLoopback(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1';
}
