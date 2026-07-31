// Passwordless + MFA GoTrue (Supabase Auth) REST client for the console.
//
// There is no password anywhere: sign-in and sign-up are the same email
// one-time-code / magic-link flow. Only the anon/publishable key is ever sent
// (enforced by [requireSafeSupabaseClientKey]); the server revalidates every
// token, so nothing here is a trust boundary.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../config/console_config.dart';
import '../models/mfa.dart';
import '../models/supabase_session.dart';
import 'key_policy.dart';

class AuthClient {
  AuthClient({
    required this.config,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client();

  final ConsoleConfig config;
  final http.Client _http;
  final Duration requestTimeout;

  static String createPkceVerifier() {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(56, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  static String pkceChallengeForVerifier(String codeVerifier) {
    _validatePkceVerifier(codeVerifier);
    return base64UrlEncode(
      sha256.convert(ascii.encode(codeVerifier)).bytes,
    ).replaceAll('=', '');
  }

  /// Emails a six-digit sign-in code plus a PKCE-bound link fallback. Same
  /// call for sign-in and sign-up; unknown users are created on verification.
  Future<void> sendEmailOtp(
    String email, {
    required String codeVerifier,
  }) async {
    _requireEmail(email);
    final redirect = _magicLinkRedirect();
    if (redirect == null) {
      throw const FormatException(
        'Configure an HTTPS magic-link callback before signing in.',
      );
    }
    await _post(
      'otp',
      {
        'email': email.trim(),
        'create_user': true,
        'code_challenge': pkceChallengeForVerifier(codeVerifier),
        'code_challenge_method': 's256',
      },
      'Sending the sign-in code failed.',
      query: {'redirect_to': redirect},
      exposeServerError: false,
    );
  }

  String? _magicLinkRedirect() {
    final configured = config.authRedirectUrl.trim();
    final candidate = configured.isNotEmpty
        ? Uri.tryParse(configured)
        : kIsWeb
        ? Uri.base
        : Uri.parse(kNativeConsoleAuthRedirect);
    if (candidate == null ||
        candidate.host.isEmpty ||
        candidate.userInfo.isNotEmpty ||
        !_isAllowedRedirect(candidate)) {
      return null;
    }
    return _withoutQueryOrFragment(candidate).toString();
  }

  static bool _isAllowedRedirect(Uri candidate) {
    if (candidate.scheme == 'sonusauris-console') {
      return candidate.host == 'auth' &&
          candidate.path == '/callback' &&
          !candidate.hasPort &&
          candidate.query.isEmpty &&
          candidate.fragment.isEmpty;
    }
    return candidate.scheme == 'https' ||
        (candidate.scheme == 'http' &&
            (candidate.host == 'localhost' || candidate.host == '127.0.0.1'));
  }

  Uri? get magicLinkRedirectUri {
    final redirect = _magicLinkRedirect();
    return redirect == null ? null : Uri.parse(redirect);
  }

  bool isExpectedMagicLinkCallback(Uri callback) {
    final expected = magicLinkRedirectUri;
    if (expected == null) {
      return false;
    }
    return callback.scheme == expected.scheme &&
        callback.host == expected.host &&
        callback.path == expected.path &&
        callback.userInfo.isEmpty &&
        _samePort(callback, expected);
  }

  String authorizationCodeFromCallback(Uri callback) {
    if (!isExpectedMagicLinkCallback(callback)) {
      throw const FormatException(
        'The sign-in link was sent to an unexpected callback.',
      );
    }
    if (callback.fragment.isNotEmpty ||
        callback.queryParameters.containsKey('access_token') ||
        callback.queryParameters.containsKey('refresh_token')) {
      throw const FormatException(
        'This older sign-in link is not accepted. Request a fresh magic link.',
      );
    }
    if (callback.queryParameters.containsKey('error') ||
        callback.queryParameters.containsKey('error_code') ||
        callback.queryParameters.containsKey('error_description')) {
      throw StateError(
        'This sign-in link is invalid or expired. Request a fresh one.',
      );
    }
    final codes = callback.queryParametersAll['code'] ?? const <String>[];
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

  Future<SupabaseSession> exchangePkceCode({
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
    final json = await _post(
      'token',
      {'auth_code': code, 'code_verifier': codeVerifier},
      'This sign-in link is invalid or expired. Request a fresh one.',
      query: {'grant_type': 'pkce'},
      exposeServerError: false,
    );
    return SupabaseSession.fromJson(json);
  }

  /// Redeems an emailed code for a session.
  Future<SupabaseSession> verifyEmailOtp({
    required String email,
    required String code,
  }) async {
    _requireEmail(email);
    final normalizedCode = _requireSixDigitCode(code);
    final json = await _post(
      'verify',
      {'type': 'email', 'email': email.trim(), 'token': normalizedCode},
      'That code was not accepted. Request a fresh one and try again.',
      exposeServerError: false,
    );
    return SupabaseSession.fromJson(json);
  }

  /// Adopts a Supabase magic-link callback after verifying that it targets the
  /// exact application URI configured for this build. Supabase may return an
  /// implicit session in the fragment or a token hash in the query string.
  Future<SupabaseSession> consumeMagicLink(Uri callback) async {
    final expected = magicLinkRedirectUri ?? config.authRedirectUri;
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
      final json = await _post(
        'verify',
        {'type': 'magiclink', 'token_hash': tokenHash},
        'That magic link was not accepted. Request a fresh one and try again.',
      );
      return SupabaseSession.fromJson(json);
    }
    throw const FormatException(
      'The sign-in link contained no usable Supabase session.',
    );
  }

  /// Exchanges a refresh token for a new session.
  Future<SupabaseSession> refreshSession(String refreshToken) async {
    if (refreshToken.trim().isEmpty) {
      throw const FormatException('No refresh token available; sign in again.');
    }
    final json = await _post(
      'token',
      {'refresh_token': refreshToken.trim()},
      'Your session could not be refreshed. Sign in again.',
      query: {'grant_type': 'refresh_token'},
    );
    return SupabaseSession.fromJson(json);
  }

  /// Best-effort server-side sign-out; ignores transport errors.
  Future<void> signOut(String accessToken) async {
    try {
      await _post(
        'logout',
        const {},
        'Sign-out failed.',
        accessToken: accessToken,
        query: {'scope': 'local'},
        allowEmptyBody: true,
      );
    } catch (_) {
      // Local session is cleared regardless.
    }
  }

  // --- MFA ------------------------------------------------------------------

  Future<List<MfaFactor>> listFactors(String accessToken) async {
    final json = await _get(
      'user',
      accessToken,
      'Reading MFA settings failed.',
    );
    return MfaFactor.listFromUserJson(json);
  }

  Future<TotpEnrollment> enrollTotp(
    String accessToken, {
    String? friendlyName,
  }) async {
    final json = await _post(
      'factors',
      {
        'factor_type': 'totp',
        if ((friendlyName ?? '').trim().isNotEmpty)
          'friendly_name': friendlyName!.trim(),
      },
      'Could not start authenticator enrollment.',
      accessToken: accessToken,
    );
    final id = (json['id'] as String? ?? '').trim();
    if (id.isEmpty) {
      throw const FormatException('Authenticator enrollment returned no id.');
    }
    final totp = json['totp'];
    final totpMap = totp is Map ? totp.cast<String, Object?>() : const {};
    return TotpEnrollment(
      factorId: id,
      secret: (totpMap['secret'] as String? ?? '').trim(),
      uri: (totpMap['uri'] as String? ?? '').trim(),
      qrCodeSvg: (totpMap['qr_code'] as String? ?? '').trim(),
    );
  }

  Future<PhoneEnrollment> enrollPhone(
    String accessToken, {
    required String phone,
    String? friendlyName,
  }) async {
    final normalizedPhone = phone.trim();
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(normalizedPhone)) {
      throw const FormatException(
        'Enter a phone number in E.164 form, such as +15551234567.',
      );
    }
    final json = await _post(
      'factors',
      {
        'factor_type': 'phone',
        'phone': normalizedPhone,
        if ((friendlyName ?? '').trim().isNotEmpty)
          'friendly_name': friendlyName!.trim(),
      },
      'Could not start SMS enrollment.',
      accessToken: accessToken,
    );
    final id = (json['id'] as String? ?? '').trim();
    if (id.isEmpty) {
      throw const FormatException('SMS enrollment returned no id.');
    }
    return PhoneEnrollment(factorId: id, phone: normalizedPhone);
  }

  /// Starts a challenge (sends the SMS for phone factors); returns its id.
  Future<String> challengeFactor(String accessToken, String factorId) async {
    final json = await _post(
      'factors/${_requireId(factorId)}/challenge',
      const {},
      'Could not start the verification challenge.',
      accessToken: accessToken,
    );
    final id = (json['id'] as String? ?? '').trim();
    if (id.isEmpty) {
      throw const FormatException('The challenge returned no id.');
    }
    return id;
  }

  /// Verifies a factor code; GoTrue returns a fresh aal2 session to adopt.
  Future<SupabaseSession> verifyFactor(
    String accessToken, {
    required String factorId,
    required String challengeId,
    required String code,
  }) async {
    final normalizedChallenge = _requireId(challengeId);
    final normalizedCode = _requireSixDigitCode(code);
    final json = await _post(
      'factors/${_requireId(factorId)}/verify',
      {'challenge_id': normalizedChallenge, 'code': normalizedCode},
      'That code was not accepted.',
      accessToken: accessToken,
    );
    return SupabaseSession.fromJson(json);
  }

  Future<void> unenrollFactor(String accessToken, String factorId) async {
    final uri = _authUri('factors/${_requireId(factorId)}');
    final response = await _http
        .delete(uri, headers: _headers(accessToken: accessToken))
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_describe(response, 'Removing the factor failed.'));
    }
  }

  // --- transport ------------------------------------------------------------

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body,
    String failureMessage, {
    String? accessToken,
    Map<String, String>? query,
    bool allowEmptyBody = false,
    bool exposeServerError = true,
  }) async {
    final uri = _authUri(path, query: query);
    final http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: _headers(accessToken: accessToken),
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw StateError('Supabase did not respond in time. Try again.');
    } on http.ClientException {
      throw StateError('Could not reach Supabase. Check your connection.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        exposeServerError
            ? _describe(response, failureMessage)
            : failureMessage,
      );
    }
    return _decode(response.body, allowEmpty: allowEmptyBody);
  }

  Future<Map<String, Object?>> _get(
    String path,
    String accessToken,
    String failureMessage,
  ) async {
    final uri = _authUri(path);
    final http.Response response;
    try {
      response = await _http
          .get(uri, headers: _headers(accessToken: accessToken))
          .timeout(requestTimeout);
    } on TimeoutException {
      throw StateError('Supabase did not respond in time. Try again.');
    } on http.ClientException {
      throw StateError('Could not reach Supabase. Check your connection.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_describe(response, failureMessage));
    }
    return _decode(response.body);
  }

  Map<String, Object?> _decode(String body, {bool allowEmpty = false}) {
    if (body.trim().isEmpty) {
      if (allowEmpty) {
        return const {};
      }
      return const {};
    }
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      return decoded.cast<String, Object?>();
    }
    throw const FormatException('Unexpected response from Supabase.');
  }

  Uri _authUri(String path, {Map<String, String>? query}) {
    requireSafeSupabaseClientKey(config.supabaseAnonKey);
    final base = Uri.parse(config.supabaseUrl.trim());
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
    if (base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment) {
      throw const FormatException(
        'Supabase URL must not contain credentials, a query, or a fragment.',
      );
    }
    final baseSegments = base.pathSegments.where((p) => p.isNotEmpty);
    return base.replace(
      pathSegments: [...baseSegments, 'auth', 'v1', ...path.split('/')],
      queryParameters: query,
    );
  }

  Map<String, String> _headers({String? accessToken}) {
    return {
      'apikey': config.supabaseAnonKey.trim(),
      'content-type': 'application/json',
      'accept': 'application/json',
      if ((accessToken ?? '').trim().isNotEmpty)
        'authorization': 'Bearer ${accessToken!.trim()}',
    };
  }

  void _requireEmail(String email) {
    final trimmed = email.trim();
    final at = trimmed.indexOf('@');
    if (at <= 0 ||
        at != trimmed.lastIndexOf('@') ||
        at == trimmed.length - 1 ||
        trimmed.length > 320 ||
        trimmed.runes.any((rune) => rune <= 0x20 || rune == 0x7f)) {
      throw const FormatException('Enter a valid email address.');
    }
  }

  String _requireId(String factorId) {
    final trimmed = factorId.trim();
    if (trimmed.isEmpty ||
        trimmed.contains('/') ||
        trimmed.contains('?') ||
        trimmed.contains('#')) {
      throw const FormatException('A factor id is required.');
    }
    return trimmed;
  }

  String _requireSixDigitCode(String code) {
    final normalized = code.trim();
    if (!RegExp(r'^[0-9]{6}$').hasMatch(normalized)) {
      throw const FormatException('Enter the 6-digit verification code.');
    }
    return normalized;
  }

  String _describe(http.Response response, String fallback) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final msg =
            decoded['msg'] ??
            decoded['error_description'] ??
            decoded['error'] ??
            decoded['message'];
        if (msg is String && msg.trim().isNotEmpty) {
          return msg.trim();
        }
      }
    } catch (_) {
      // fall through to the generic message
    }
    return '$fallback (${response.statusCode})';
  }

  void close() {
    _http.close();
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

Uri _withoutQueryOrFragment(Uri uri) {
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  );
}
