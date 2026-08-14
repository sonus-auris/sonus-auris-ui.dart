import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/supabase_mfa.dart';
import 'package:audio_dashcam/src/models/supabase_session.dart';
import 'package:audio_dashcam/src/services/supabase_auth_client.dart';

/// Integration-test-only email + MFA client.
///
/// The Flutter process never receives the Shared Auth bearer secret. It talks
/// to a loopback bridge started by CI or the trusted Mac host; that bridge adds
/// the secret server-side and forwards to the isolated Shared Auth test realm.
/// Each returned object is a genuine, signature-verified Supabase session. The
/// UI-facing factor ids are synthetic: entering the fixed test code asks the
/// isolated server to complete Supabase's real enroll/challenge/verify ceremony
/// and return the resulting AAL2 token.
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
  static const String testCode = '424242';
  static const String _totpSecret = 'JBSWY3DPEHPK3PXP';

  final http.Client _client;
  final Uri _bridgeEndpoint;
  final Map<String, _TestFactor> _factors = {};
  final Map<String, String> _challenges = {};
  int _nextFactor = 0;
  int _nextChallenge = 0;

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
    return _requestSession(
      config: config,
      email: normalizedEmail,
      code: normalizedCode,
      assurance: 'aal1',
    );
  }

  @override
  Future<List<MfaFactor>> listFactors({
    required AppConfig config,
    required String accessToken,
  }) async {
    _validateAccessToken(config, accessToken);
    return [for (final factor in _factors.values) factor.publicValue];
  }

  @override
  Future<TotpEnrollment> enrollTotp({
    required AppConfig config,
    required String accessToken,
    String? friendlyName,
    String? issuer,
  }) async {
    final email = _aal1Email(config, accessToken);
    final factor = _newFactor(factorType: 'totp', friendlyName: friendlyName);
    final resolvedIssuer = issuer ?? 'sonus-auris:localhost';
    return TotpEnrollment(
      factorId: factor.id,
      secret: _totpSecret,
      uri: Uri(
        scheme: 'otpauth',
        host: 'totp',
        path: '$resolvedIssuer:$email',
        queryParameters: {'secret': _totpSecret, 'issuer': resolvedIssuer},
      ).toString(),
    );
  }

  @override
  Future<PhoneEnrollment> enrollPhone({
    required AppConfig config,
    required String accessToken,
    required String phone,
    String? friendlyName,
  }) async {
    _aal1Email(config, accessToken);
    final normalizedPhone = phone.trim();
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(normalizedPhone)) {
      throw const FormatException(
        'Enter a phone number in E.164 form, such as +15551234567.',
      );
    }
    final factor = _newFactor(
      factorType: 'phone',
      friendlyName: friendlyName,
      phone: normalizedPhone,
    );
    return PhoneEnrollment(factorId: factor.id, phone: normalizedPhone);
  }

  @override
  Future<String> challengeFactor({
    required AppConfig config,
    required String accessToken,
    required String factorId,
  }) async {
    _aal1Email(config, accessToken);
    final factor = _factors[factorId.trim()];
    if (factor == null) {
      throw const FormatException('The MFA factor id is missing.');
    }
    final challengeId = 'shared-auth-test-challenge-${++_nextChallenge}';
    _challenges[challengeId] = factor.id;
    return challengeId;
  }

  @override
  Future<SupabaseSession> verifyFactor({
    required AppConfig config,
    required String accessToken,
    required String factorId,
    required String challengeId,
    required String code,
  }) async {
    final email = _aal1Email(config, accessToken);
    final factor = _factors[factorId.trim()];
    if (factor == null || _challenges[challengeId.trim()] != factor.id) {
      throw const FormatException('The verification challenge is missing.');
    }
    if (code.trim() != testCode) {
      throw StateError('That code was not accepted.');
    }
    final session = await _requestSession(
      config: config,
      email: email,
      code: testCode,
      assurance: factor.factorType == 'totp' ? 'aal2_totp' : 'aal2_phone',
      phone: factor.phone.isEmpty ? null : factor.phone,
    );
    _challenges.remove(challengeId.trim());
    factor.verified = true;
    return session;
  }

  @override
  Future<void> unenrollFactor({
    required AppConfig config,
    required String accessToken,
    required String factorId,
  }) async {
    _validateAccessToken(config, accessToken);
    if (_factors.remove(factorId.trim()) == null) {
      throw const FormatException('The MFA factor id is missing.');
    }
    _challenges.removeWhere((_, value) => value == factorId.trim());
  }

  _TestFactor _newFactor({
    required String factorType,
    String? friendlyName,
    String phone = '',
  }) {
    _factors.clear();
    _challenges.clear();
    final factor = _TestFactor(
      id: 'shared-auth-test-$factorType-${++_nextFactor}',
      factorType: factorType,
      friendlyName: friendlyName?.trim() ?? '',
      phone: phone,
    );
    _factors[factor.id] = factor;
    return factor;
  }

  String _aal1Email(AppConfig config, String accessToken) {
    final claims = _validateAccessToken(config, accessToken);
    if (claims['aal'] != 'aal1' ||
        !supabaseJwtHasPasswordlessFirstFactor(accessToken)) {
      throw const FormatException(
        'The test MFA ceremony requires passwordless AAL1.',
      );
    }
    final email = claims['email'];
    if (email is! String) {
      throw const FormatException('The test session has no email identity.');
    }
    return _validateInvocation(config, email);
  }

  Map<String, dynamic> _validateAccessToken(
    AppConfig config,
    String accessToken,
  ) {
    final claims = decodeSupabaseJwtPayload(accessToken);
    if (claims == null ||
        claims['iss'] != _expectedSupabaseIssuer(config.supabaseUrl)) {
      throw const FormatException(
        'The isolated test session came from an unexpected issuer.',
      );
    }
    final audience = claims['aud'];
    if (audience != 'authenticated' &&
        !(audience is List && audience.contains('authenticated'))) {
      throw const FormatException(
        'The isolated test session had an unexpected audience.',
      );
    }
    return claims;
  }

  Future<SupabaseSession> _requestSession({
    required AppConfig config,
    required String email,
    required String code,
    required String assurance,
    String? phone,
  }) async {
    final normalizedEmail = _validateInvocation(config, email);

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
              'code': code,
              'assurance': assurance,
              'phone': ?phone,
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
    if (!session.hasPasswordlessFirstFactor ||
        session.aal != _assuranceAal(assurance)) {
      throw const FormatException(
        'The isolated test session returned the wrong assurance level.',
      );
    }

    final claims = _validateAccessToken(config, session.accessToken);
    final methods = _amrMethods(claims);
    final requiredMethod = switch (assurance) {
      'aal2_totp' => 'totp',
      'aal2_phone' => 'mfa/phone',
      _ => null,
    };
    if (requiredMethod != null && !methods.contains(requiredMethod)) {
      throw const FormatException(
        'The isolated test session returned the wrong verification method.',
      );
    }
    return session;
  }

  static String _assuranceAal(String assurance) =>
      assurance == 'aal1' ? 'aal1' : 'aal2';

  static Set<String> _amrMethods(Map<String, dynamic> claims) {
    final amr = claims['amr'];
    if (amr is! List) return const {};
    return amr
        .whereType<Map>()
        .map((entry) => entry['method'])
        .whereType<String>()
        .map((method) => method.trim().toLowerCase())
        .toSet();
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

final class _TestFactor {
  _TestFactor({
    required this.id,
    required this.factorType,
    required this.friendlyName,
    required this.phone,
  });

  final String id;
  final String factorType;
  final String friendlyName;
  final String phone;
  bool verified = false;

  MfaFactor get publicValue => MfaFactor(
    id: id,
    factorType: factorType,
    status: verified ? 'verified' : 'unverified',
    friendlyName: friendlyName,
    phone: phone,
  );
}
