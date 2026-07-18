// Thin http client for Supabase GoTrue auth (anon key only): sign-in/up and token refresh.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../models/supabase_mfa.dart';
import '../models/supabase_session.dart';
import 'supabase_key_policy.dart';

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

  Future<SupabaseSession> signInWithPassword({
    required AppConfig config,
    required String email,
    required String password,
  }) async {
    _validateEmail(email);
    _validatePassword(password);
    final uri = _authUri(config, 'token', query: {'grant_type': 'password'});
    return _session(config, uri, {
      'email': email.trim(),
      'password': password,
    }, 'Supabase sign-in failed.');
  }

  /// Creates an account. Returns null when the project requires email
  /// confirmation (the response carries a user but no session yet).
  Future<SupabaseSession?> signUp({
    required AppConfig config,
    required String email,
    required String password,
  }) async {
    _validateEmail(email);
    _validatePassword(password, creatingAccount: true);
    final uri = _authUri(config, 'signup');
    final decoded = await _post(config, uri, {
      'email': email.trim(),
      'password': password,
    }, 'Supabase sign-up failed.');
    if ((decoded['access_token'] as String? ?? '').trim().isEmpty) {
      return null;
    }
    return SupabaseSession.fromJson(decoded);
  }

  /// Emails a one-time sign-in code (and, with the default template, a magic
  /// link). `create_user: true` makes this the sign-up path too: an unknown
  /// address gets an account the moment its first code is verified.
  Future<void> sendEmailOtp({
    required AppConfig config,
    required String email,
  }) async {
    _validateEmail(email);
    final uri = _authUri(config, 'otp');
    await _post(config, uri, {
      'email': email.trim(),
      'create_user': true,
    }, 'Sending the sign-in code failed.');
  }

  /// Redeems an emailed one-time code for a session (passwordless sign-in).
  Future<SupabaseSession> verifyEmailOtp({
    required AppConfig config,
    required String email,
    required String code,
  }) async {
    _validateEmail(email);
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) {
      throw const FormatException('Enter the code from the email.');
    }
    final uri = _authUri(config, 'verify');
    return _session(config, uri, {
      'type': 'email',
      'email': email.trim(),
      'token': trimmedCode,
    }, 'That code was not accepted. Request a fresh one and try again.');
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
    final decoded = await _post(config, uri, {
      'factor_type': 'totp',
      if ((friendlyName ?? '').trim().isNotEmpty)
        'friendly_name': friendlyName!.trim(),
    }, 'Could not start authenticator enrollment.', accessToken: accessToken);
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
    if (trimmedPhone.isEmpty) {
      throw const FormatException('Enter the phone number to enroll.');
    }
    final uri = _authUri(config, 'factors');
    final decoded = await _post(config, uri, {
      'factor_type': 'phone',
      'phone': trimmedPhone,
      if ((friendlyName ?? '').trim().isNotEmpty)
        'friendly_name': friendlyName!.trim(),
    }, 'Could not start SMS enrollment.', accessToken: accessToken);
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
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) {
      throw const FormatException('Enter the 6-digit code.');
    }
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

  /// Sends Supabase's hosted password-reset email. The reset link is generated
  /// by the project Auth settings; the app never sees the user's new password.
  Future<void> sendPasswordResetEmail({
    required AppConfig config,
    required String email,
  }) async {
    _validateEmail(email);
    final uri = _authUri(config, 'recover');
    await _post(config, uri, {
      'email': email.trim(),
    }, 'Supabase password reset failed.');
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
  }) async {
    final decoded = await _post(
      config,
      uri,
      body,
      fallbackError,
      accessToken: accessToken,
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
      throw StateError(_errorMessage(decoded, fallbackError));
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
    if (base.userInfo.isNotEmpty) {
      throw const FormatException(
        'Supabase URL must not contain embedded credentials.',
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
        normalized.contains(' ')) {
      throw const FormatException('Enter a valid email address.');
    }
  }

  void _validatePassword(String password, {bool creatingAccount = false}) {
    if (password.isEmpty) {
      throw const FormatException('Enter your password.');
    }
    if (creatingAccount && password.length < 6) {
      throw const FormatException(
        'Use at least 6 characters when creating an account.',
      );
    }
  }

  void close() {
    _httpClient.close();
  }
}
