// Thin http client for Supabase GoTrue auth (anon key only): sign-in/up and token refresh.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_config.dart';
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
    String redirectTo = '',
  }) async {
    _validateEmail(email);
    final uri = _authUri(config, 'recover');
    final normalizedRedirect = _validateRedirectTo(redirectTo);
    await _post(config, uri, {
      'email': email.trim(),
      if (normalizedRedirect.isNotEmpty) 'redirect_to': normalizedRedirect,
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
    String fallbackError,
  ) async {
    final decoded = await _post(config, uri, body, fallbackError);
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
    String fallbackError,
  ) async {
    late final http.Response response;
    try {
      response = await _httpClient
          .post(uri, headers: _headers(config), body: jsonEncode(body))
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
      pathSegments: [...baseSegments, 'auth', 'v1', path],
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

  String _validateRedirectTo(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Password-reset redirect URL is invalid.');
    }
    if (uri.scheme != 'https' &&
        uri.host != 'localhost' &&
        uri.host != '127.0.0.1') {
      throw const FormatException(
        'Password-reset redirect URL must use HTTPS except localhost development.',
      );
    }
    return uri.toString();
  }

  void close() {
    _httpClient.close();
  }
}
