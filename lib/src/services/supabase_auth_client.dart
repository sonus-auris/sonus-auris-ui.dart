// Thin passwordless Supabase GoTrue client (anon key only): magic links, OTP verification, and token refresh.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../models/supabase_mfa.dart';
import '../models/supabase_session.dart';
import 'supabase_key_policy.dart';

const String kSupabaseAuthRedirectUrl = String.fromEnvironment(
  'SONUS_AUTH_REDIRECT_URL',
  defaultValue: 'sonusauris://auth/callback',
);

/// Thin client for Supabase's GoTrue REST auth API. Implemented over plain
/// `http` (no native plugin) so it is fully testable and adds no dependency.
///
/// Only ever uses the project's anon/publishable key (sent as `apikey`); the
/// service_role / secret key must never reach the device.
class SupabaseAuthClient {
  SupabaseAuthClient({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration requestTimeout;

  /// Creates an RFC 7636 verifier with enough entropy for a public client.
  static String createPkceVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(56, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Derives the S256 challenge sent to Supabase. Public for deterministic
  /// contract tests and for callers that persist the verifier themselves.
  static String pkceChallengeForVerifier(String codeVerifier) {
    _validatePkceVerifier(codeVerifier);
    return base64UrlEncode(
      sha256.convert(ascii.encode(codeVerifier)).bytes,
    ).replaceAll('=', '');
  }

  /// Emails a one-time sign-in code (and, with the default template, a magic
  /// link). `create_user: true` makes this the sign-up path too: an unknown
  /// address gets an account the moment its first code is verified.
  Future<void> sendEmailOtp({
    required AppConfig config,
    required String email,
    required String codeVerifier,
    String redirectTo = kSupabaseAuthRedirectUrl,
  }) async {
    _validateEmail(email);
    final normalizedRedirect = _validateAuthRedirect(redirectTo);
    if (normalizedRedirect.isEmpty) {
      throw const FormatException(
        'A magic-link callback URL is required for secure sign-in.',
      );
    }
    final codeChallenge = pkceChallengeForVerifier(codeVerifier);
    final uri = _authUri(
      config,
      'otp',
      query: {
        if (normalizedRedirect.isNotEmpty) 'redirect_to': normalizedRedirect,
      },
    );
    await _post(
      config,
      uri,
      {
        'email': email.trim(),
        'create_user': true,
        'code_challenge': codeChallenge,
        'code_challenge_method': 's256',
      },
      'Sending the sign-in code failed.',
      exposeServerError: false,
    );
  }

  /// Redeems an emailed one-time code for a session (passwordless sign-in).
  Future<SupabaseSession> verifyEmailOtp({
    required AppConfig config,
    required String email,
    required String code,
  }) async {
    _validateEmail(email);
    final trimmedCode = _requireSixDigitCode(code);
    final uri = _authUri(config, 'verify');
    return _session(
      config,
      uri,
      {'type': 'email', 'email': email.trim(), 'token': trimmedCode},
      'That code was not accepted. Request a fresh one and try again.',
      exposeServerError: false,
    );
  }

  /// Returns true only for the exact registered callback endpoint. Query
  /// parameters are intentionally ignored here because Supabase adds the code.
  static bool isExpectedMagicLinkCallback({
    required Uri callbackUri,
    required Uri expectedRedirectUri,
  }) {
    return callbackUri.scheme == expectedRedirectUri.scheme &&
        callbackUri.host == expectedRedirectUri.host &&
        callbackUri.path == expectedRedirectUri.path &&
        callbackUri.userInfo.isEmpty &&
        _samePort(callbackUri, expectedRedirectUri);
  }

  static bool sessionMatchesRequestedEmail({
    required SupabaseSession session,
    required String requestedEmail,
  }) {
    final expected = requestedEmail.trim().toLowerCase();
    final verified = session.email.trim().toLowerCase();
    return expected.isNotEmpty && verified == expected;
  }

  /// Extracts a PKCE authorization code from the exact callback endpoint.
  ///
  /// Access/refresh tokens in either the query or fragment are deliberately
  /// rejected: release clients never accept the interceptable implicit flow.
  static String authorizationCodeFromCallback({
    required Uri callbackUri,
    required Uri expectedRedirectUri,
  }) {
    if (!isExpectedMagicLinkCallback(
      callbackUri: callbackUri,
      expectedRedirectUri: expectedRedirectUri,
    )) {
      throw const FormatException(
        'The sign-in link was sent to an unexpected callback.',
      );
    }
    if (callbackUri.fragment.isNotEmpty ||
        callbackUri.queryParameters.containsKey('access_token') ||
        callbackUri.queryParameters.containsKey('refresh_token')) {
      throw const FormatException(
        'This older sign-in link is not accepted. Request a fresh magic link.',
      );
    }
    if (callbackUri.queryParameters.containsKey('error') ||
        callbackUri.queryParameters.containsKey('error_code') ||
        callbackUri.queryParameters.containsKey('error_description')) {
      throw StateError(
        'This sign-in link is invalid or expired. Request a fresh one.',
      );
    }
    final codes = callbackUri.queryParametersAll['code'] ?? const <String>[];
    if (codes.length != 1) {
      throw const FormatException(
        'The sign-in link did not contain one authorization code.',
      );
    }
    final code = codes.single.trim();
    if (code.isEmpty ||
        code.length > 2048 ||
        code.runes.any((rune) => rune <= 0x20 || rune == 0x7f)) {
      throw const FormatException(
        'The sign-in link contained an invalid authorization code.',
      );
    }
    return code;
  }

  /// Redeems a PKCE code. Possession of the callback URL alone is insufficient:
  /// Supabase also requires the verifier held by the requesting installation.
  Future<SupabaseSession> exchangePkceCode({
    required AppConfig config,
    required String authorizationCode,
    required String codeVerifier,
  }) async {
    final code = authorizationCode.trim();
    if (code.isEmpty || code.length > 2048) {
      throw const FormatException(
        'The magic link authorization code is invalid.',
      );
    }
    _validatePkceVerifier(codeVerifier);
    return _session(
      config,
      _authUri(config, 'token', query: {'grant_type': 'pkce'}),
      {'auth_code': code, 'code_verifier': codeVerifier},
      'This sign-in link is invalid or expired. Request a fresh one.',
      exposeServerError: false,
    );
  }

  /// Adopts a Supabase magic-link callback only when it targets this build's
  /// exact application URI. The callback itself must never be logged or stored.
  Future<SupabaseSession> consumeMagicLink({
    required AppConfig config,
    required Uri callback,
  }) async {
    final expected = _authRedirectUri;
    if (callback.scheme != expected.scheme ||
        callback.host != expected.host ||
        callback.port != expected.port ||
        callback.path != expected.path) {
      throw const FormatException('That sign-in link targets another app.');
    }

    final parameters = <String, String>{
      ...callback.queryParameters,
      ...Uri.splitQueryString(
        callback.fragment,
        encoding: const Utf8Codec(allowMalformed: false),
      ),
    };
    final callbackError =
        parameters['error_description'] ?? parameters['error'];
    if ((callbackError ?? '').trim().isNotEmpty) {
      throw StateError(callbackError!.trim());
    }

    final accessToken = (parameters['access_token'] ?? '').trim();
    final tokenHash = (parameters['token_hash'] ?? '').trim();
    if (accessToken.isNotEmpty && tokenHash.isNotEmpty) {
      throw const FormatException(
        'The sign-in callback contained conflicting credentials.',
      );
    }
    if (accessToken.isNotEmpty) {
      final refreshToken = (parameters['refresh_token'] ?? '').trim();
      if (refreshToken.isEmpty) {
        throw const FormatException(
          'The sign-in callback contained no refresh token.',
        );
      }
      final expiresIn = int.tryParse(parameters['expires_in'] ?? '');
      return SupabaseSession.fromJson({
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_in': ?expiresIn,
      });
    }

    if (tokenHash.isNotEmpty) {
      final uri = _authUri(config, 'verify');
      return _session(
        config,
        uri,
        {'type': 'magiclink', 'token_hash': tokenHash},
        'That magic link was not accepted. Request a fresh one and try again.',
      );
    }
    throw const FormatException(
      'The sign-in link contained no usable Supabase session.',
    );
  }

  // --- Multi-factor auth (Bearer = the user's current access token) ---------

  /// Lists the user's enrolled MFA factors via `GET /auth/v1/user`.
  Future<List<MfaFactor>> listFactors({
    required AppConfig config,
    required String accessToken,
  }) async {
    final uri = _authUri(config, 'user');
    final decoded = await _get(
      config,
      uri,
      accessToken,
      'Reading account security settings failed.',
    );
    return MfaFactor.listFromUserJson(decoded);
  }

  /// Starts enrolling an authenticator app (TOTP). The returned secret/URI
  /// must be confirmed with [challengeFactor] + [verifyFactor] before the
  /// factor becomes active.
  Future<TotpEnrollment> enrollTotp({
    required AppConfig config,
    required String accessToken,
    String? friendlyName,
  }) async {
    final uri = _authUri(config, 'factors');
    final decoded = await _post(
      config,
      uri,
      {
        'factor_type': 'totp',
        if ((friendlyName ?? '').trim().isNotEmpty)
          'friendly_name': friendlyName!.trim(),
      },
      'Could not start authenticator enrollment.',
      accessToken: accessToken,
    );
    final factorId = (decoded['id'] as String? ?? '').trim();
    if (factorId.isEmpty) {
      throw StateError('Authenticator enrollment returned no factor id.');
    }
    final totp = decoded['totp'];
    final totpMap = totp is Map
        ? totp.cast<String, Object?>()
        : const <String, Object?>{};
    return TotpEnrollment(
      factorId: factorId,
      secret: (totpMap['secret'] as String? ?? '').trim(),
      uri: (totpMap['uri'] as String? ?? '').trim(),
      qrCodeSvg: (totpMap['qr_code'] as String? ?? '').trim(),
    );
  }

  /// Starts enrolling a phone (SMS) factor. The number must be confirmed with
  /// [challengeFactor] (which sends the text) + [verifyFactor].
  Future<PhoneEnrollment> enrollPhone({
    required AppConfig config,
    required String accessToken,
    required String phone,
    String? friendlyName,
  }) async {
    final trimmedPhone = phone.trim();
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(trimmedPhone)) {
      throw const FormatException(
        'Enter a phone number in E.164 form, such as +15551234567.',
      );
    }
    final uri = _authUri(config, 'factors');
    final decoded = await _post(
      config,
      uri,
      {
        'factor_type': 'phone',
        'phone': trimmedPhone,
        if ((friendlyName ?? '').trim().isNotEmpty)
          'friendly_name': friendlyName!.trim(),
      },
      'Could not start SMS enrollment.',
      accessToken: accessToken,
    );
    final factorId = (decoded['id'] as String? ?? '').trim();
    if (factorId.isEmpty) {
      throw StateError('SMS enrollment returned no factor id.');
    }
    final phoneField = decoded['phone'];
    return PhoneEnrollment(
      factorId: factorId,
      phone: phoneField is String && phoneField.trim().isNotEmpty
          ? phoneField.trim()
          : trimmedPhone,
    );
  }

  /// Creates a challenge for a factor and returns the challenge id. For phone
  /// factors this is what sends the SMS code.
  Future<String> challengeFactor({
    required AppConfig config,
    required String accessToken,
    required String factorId,
  }) async {
    final id = _requireFactorId(factorId);
    final uri = _authUri(config, 'factors/$id/challenge');
    final decoded = await _post(
      config,
      uri,
      const {},
      'Could not start the verification challenge.',
      accessToken: accessToken,
    );
    final challengeId = (decoded['id'] as String? ?? '').trim();
    if (challengeId.isEmpty) {
      throw StateError('The verification challenge returned no id.');
    }
    return challengeId;
  }

  /// Verifies a factor code against a challenge. On success GoTrue issues a
  /// brand-new session whose access token carries `aal2`; callers must adopt
  /// it (the old aal1 tokens are superseded).
  Future<SupabaseSession> verifyFactor({
    required AppConfig config,
    required String accessToken,
    required String factorId,
    required String challengeId,
    required String code,
  }) async {
    final id = _requireFactorId(factorId);
    final trimmedChallenge = challengeId.trim();
    if (trimmedChallenge.isEmpty) {
      throw const FormatException('The verification challenge is missing.');
    }
    final trimmedCode = _requireSixDigitCode(code);
    final uri = _authUri(config, 'factors/$id/verify');
    return _session(
      config,
      uri,
      {'challenge_id': trimmedChallenge, 'code': trimmedCode},
      'That code was not accepted.',
      accessToken: accessToken,
    );
  }

  /// Removes an enrolled factor.
  Future<void> unenrollFactor({
    required AppConfig config,
    required String accessToken,
    required String factorId,
  }) async {
    final id = _requireFactorId(factorId);
    final uri = _authUri(config, 'factors/$id');
    late final http.Response response;
    try {
      response = await _httpClient
          .delete(uri, headers: _headers(config, accessToken: accessToken))
          .timeout(requestTimeout);
    } on TimeoutException {
      throw StateError('Supabase did not respond in time. Try again.');
    } on http.ClientException {
      throw StateError(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _errorMessage(_decode(response), 'Removing the factor failed.'),
      );
    }
  }

  String _requireFactorId(String factorId) {
    final id = factorId.trim();
    if (id.isEmpty) {
      throw const FormatException('The MFA factor id is missing.');
    }
    if (id.contains('/') || id.contains('?') || id.contains('#')) {
      throw const FormatException('The MFA factor id is malformed.');
    }
    return id;
  }

  /// Redeems a (rotating) refresh token for a fresh access token.
  Future<SupabaseSession> refreshSession({
    required AppConfig config,
    required String refreshToken,
  }) async {
    if (refreshToken.trim().isEmpty) {
      throw const FormatException('Supabase refresh token is missing.');
    }
    final uri = _authUri(
      config,
      'token',
      query: {'grant_type': 'refresh_token'},
    );
    return _session(config, uri, {
      'refresh_token': refreshToken.trim(),
    }, 'Supabase token refresh failed.');
  }

  /// Best-effort server-side session revocation. Local secrets are cleared by
  /// the caller regardless of the outcome.
  Future<void> signOut({
    required AppConfig config,
    required String accessToken,
  }) async {
    if (accessToken.trim().isEmpty) {
      return;
    }
    final uri = _authUri(config, 'logout');
    try {
      await _httpClient
          .post(uri, headers: _headers(config, accessToken: accessToken))
          .timeout(requestTimeout);
    } catch (_) {
      // Sign-out must always succeed locally; ignore network/server errors.
    }
  }

  Future<SupabaseSession> _session(
    AppConfig config,
    Uri uri,
    Map<String, Object?> body,
    String fallbackError, {
    String? accessToken,
    bool exposeServerError = true,
  }) async {
    final decoded = await _post(
      config,
      uri,
      body,
      fallbackError,
      accessToken: accessToken,
      exposeServerError: exposeServerError,
    );
    try {
      return SupabaseSession.fromJson(decoded);
    } on FormatException catch (error) {
      throw StateError(error.message);
    }
  }

  Future<Map<String, dynamic>> _post(
    AppConfig config,
    Uri uri,
    Map<String, Object?> body,
    String fallbackError, {
    String? accessToken,
    bool exposeServerError = true,
  }) async {
    late final http.Response response;
    try {
      response = await _httpClient
          .post(
            uri,
            headers: _headers(config, accessToken: accessToken),
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw StateError('Supabase did not respond in time. Try again.');
    } on http.ClientException {
      throw StateError(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    final decoded = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        exposeServerError
            ? _errorMessage(decoded, fallbackError)
            : fallbackError,
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _get(
    AppConfig config,
    Uri uri,
    String accessToken,
    String fallbackError,
  ) async {
    late final http.Response response;
    try {
      response = await _httpClient
          .get(uri, headers: _headers(config, accessToken: accessToken))
          .timeout(requestTimeout);
    } on TimeoutException {
      throw StateError('Supabase did not respond in time. Try again.');
    } on http.ClientException {
      throw StateError(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    final decoded = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_errorMessage(decoded, fallbackError));
    }
    return decoded;
  }

  Uri _authUri(AppConfig config, String path, {Map<String, String>? query}) {
    final raw = config.supabaseUrl.trim();
    if (raw.isEmpty) {
      throw const FormatException('Supabase URL is not configured.');
    }
    if (config.supabaseAnonKey.trim().isEmpty) {
      throw const FormatException('Supabase anon key is not configured.');
    }
    requireSafeSupabaseClientKey(config.supabaseAnonKey);
    final base = Uri.parse(raw);
    if (base.host.trim().isEmpty) {
      throw const FormatException('Supabase URL must include a host.');
    }
    if (base.scheme != 'https' &&
        base.host != 'localhost' &&
        base.host != '127.0.0.1') {
      throw const FormatException(
        'Supabase URL must use HTTPS except localhost development.',
      );
    }
    if (base.userInfo.isNotEmpty ||
        base.query.isNotEmpty ||
        base.fragment.isNotEmpty) {
      throw const FormatException(
        'Supabase URL must not contain credentials, a query, or a fragment.',
      );
    }
    if (base.hasQuery || base.hasFragment) {
      throw const FormatException(
        'Supabase URL must not contain a query or fragment.',
      );
    }
    final baseSegments = base.pathSegments.where((part) => part.isNotEmpty);
    return base.replace(
      pathSegments: [
        ...baseSegments,
        'auth',
        'v1',
        // Split nested paths (e.g. factors/{id}/challenge) into real segments
        // so they are not percent-encoded into one.
        ...path.split('/').where((part) => part.isNotEmpty),
      ],
      queryParameters: query,
      fragment: '',
    );
  }

  Uri get _authRedirectUri {
    final uri = Uri.parse(kSupabaseAuthRedirectUrl.trim());
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException(
        'The auth redirect URL must include a scheme and host.',
      );
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const FormatException(
        'The auth redirect URL must not contain credentials, a query, or a fragment.',
      );
    }
    return uri;
  }

  Map<String, String> _headers(AppConfig config, {String? accessToken}) {
    final anonKey = config.supabaseAnonKey.trim();
    return {
      'apikey': anonKey,
      'authorization': 'Bearer ${(accessToken ?? anonKey).trim()}',
      'content-type': 'application/json',
      'accept': 'application/json',
    };
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.body.trim().isEmpty) {
      return const {};
    }
    try {
      final value = jsonDecode(response.body);
      return value is Map<String, dynamic> ? value : const {};
    } on FormatException {
      return const {};
    }
  }

  String _errorMessage(Map<String, dynamic> body, String fallback) {
    final message =
        body['error_description'] ??
        body['msg'] ??
        body['message'] ??
        body['error'];
    return message?.toString() ?? fallback;
  }

  void _validateEmail(String email) {
    final normalized = email.trim();
    final at = normalized.indexOf('@');
    if (at <= 0 ||
        at != normalized.lastIndexOf('@') ||
        at == normalized.length - 1 ||
        normalized.length > 320 ||
        normalized.runes.any((rune) => rune <= 0x20 || rune == 0x7f)) {
      throw const FormatException('Enter a valid email address.');
    }
  }

  String _validateAuthRedirect(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException('Magic-link redirect URL is invalid.');
    }
    final isLocalWeb =
        uri.scheme == 'http' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1');
    final isNativeCallback =
        uri.scheme == 'sonusauris' &&
        uri.host == 'auth' &&
        uri.path == '/callback';
    if (uri.scheme != 'https' && !isLocalWeb && !isNativeCallback) {
      throw const FormatException(
        'Magic-link redirect URL must use HTTPS or the Sonus Auris app callback.',
      );
    }
    return uri.toString();
  }

  String _requireSixDigitCode(String code) {
    final normalized = code.trim();
    if (!RegExp(r'^[0-9]{6}$').hasMatch(normalized)) {
      throw const FormatException('Enter the 6-digit verification code.');
    }
    return normalized;
  }

  void close() {
    _httpClient.close();
  }
}

void _validatePkceVerifier(String codeVerifier) {
  final verifier = codeVerifier.trim();
  if (verifier.length < 43 ||
      verifier.length > 128 ||
      !RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(verifier)) {
    throw const FormatException('The PKCE code verifier is invalid.');
  }
}

bool _samePort(Uri first, Uri second) {
  if (first.hasPort != second.hasPort) {
    return false;
  }
  return !first.hasPort || first.port == second.port;
}
