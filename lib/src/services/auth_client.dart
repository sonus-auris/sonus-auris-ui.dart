// Passwordless + MFA GoTrue (Supabase Auth) REST client for the console.
//
// There is no password anywhere: sign-in and sign-up are the same email
// one-time-code / magic-link flow. Only the anon/publishable key is ever sent
// (enforced by [requireSafeSupabaseClientKey]); the server revalidates every
// token, so nothing here is a trust boundary.
import 'dart:async';
import 'dart:convert';

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

  /// Emails a one-time sign-in code + magic link. Same call for sign-in and
  /// sign-up (`create_user: true` creates the account on first verified code).
  Future<void> sendEmailOtp(String email) async {
    _requireEmail(email);
    await _post(
      'otp',
      {'email': email.trim(), 'create_user': true},
      'Sending the sign-in code failed.',
    );
  }

  /// Redeems an emailed code for a session.
  Future<SupabaseSession> verifyEmailOtp({
    required String email,
    required String code,
  }) async {
    _requireEmail(email);
    if (code.trim().isEmpty) {
      throw const FormatException('Enter the code from the email.');
    }
    final json = await _post(
      'verify',
      {'type': 'email', 'email': email.trim(), 'token': code.trim()},
      'That code was not accepted. Request a fresh one and try again.',
    );
    return SupabaseSession.fromJson(json);
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
    final json = await _get('user', accessToken, 'Reading MFA settings failed.');
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
    if (phone.trim().isEmpty) {
      throw const FormatException('Enter the phone number to enroll.');
    }
    final json = await _post(
      'factors',
      {
        'factor_type': 'phone',
        'phone': phone.trim(),
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
    return PhoneEnrollment(factorId: id, phone: phone.trim());
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
    if (code.trim().isEmpty) {
      throw const FormatException('Enter the 6-digit code.');
    }
    final json = await _post(
      'factors/${_requireId(factorId)}/verify',
      {'challenge_id': challengeId.trim(), 'code': code.trim()},
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
  }) async {
    final uri = _authUri(path, query: query);
    final http.Response response;
    try {
      response = await _http
          .post(uri, headers: _headers(accessToken: accessToken), body: jsonEncode(body))
          .timeout(requestTimeout);
    } on TimeoutException {
      throw StateError('Supabase did not respond in time. Try again.');
    } on http.ClientException {
      throw StateError('Could not reach Supabase. Check your connection.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_describe(response, failureMessage));
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
    if (trimmed.isEmpty || !trimmed.contains('@')) {
      throw const FormatException('Enter a valid email address.');
    }
  }

  String _requireId(String factorId) {
    final trimmed = factorId.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('A factor id is required.');
    }
    return trimmed;
  }

  String _describe(http.Response response, String fallback) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final msg = decoded['msg'] ??
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
