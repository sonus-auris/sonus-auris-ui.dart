// PKCE OAuth helper for the music integrations (Spotify/SoundCloud): builds verifier/challenge pairs and exchanges auth codes for tokens.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A PKCE verifier/challenge pair (RFC 7636).
class PkcePair {
  const PkcePair({required this.verifier, required this.challenge});
  final String verifier;
  final String challenge;
}

/// Static config for one OAuth provider (authorize/token URLs + this app's
/// registered client id, redirect, scopes).
class OAuthProviderConfig {
  const OAuthProviderConfig({
    required this.name,
    required this.authorizeUrl,
    required this.tokenUrl,
    required this.clientId,
    required this.redirectUri,
    required this.scopes,
  });

  final String name;
  final String authorizeUrl;
  final String tokenUrl;
  final String clientId;
  final String redirectUri;
  final List<String> scopes;

  bool get isConfigured => clientId.trim().isNotEmpty;
}

class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresAtUtc,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAtUtc;
}

/// Builds OAuth Authorization-Code-with-PKCE flows for the music integrations
/// and exchanges the returned code for tokens. The browser round-trip itself is
/// handled by an [OAuthBrowser]; this service is pure request/crypto logic and
/// is fully unit-testable.
class MusicOAuthService {
  MusicOAuthService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Random _random = Random.secure();

  /// Spotify needs playlist-modify-private to build the private memories list.
  static OAuthProviderConfig spotify({
    required String clientId,
    required String redirectUri,
  }) => OAuthProviderConfig(
    name: 'spotify',
    authorizeUrl: 'https://accounts.spotify.com/authorize',
    tokenUrl: 'https://accounts.spotify.com/api/token',
    clientId: clientId,
    redirectUri: redirectUri,
    scopes: const ['playlist-modify-private', 'playlist-read-private'],
  );

  static OAuthProviderConfig soundCloud({
    required String clientId,
    required String redirectUri,
  }) => OAuthProviderConfig(
    name: 'soundcloud',
    authorizeUrl: 'https://secure.soundcloud.com/authorize',
    tokenUrl: 'https://secure.soundcloud.com/oauth/token',
    clientId: clientId,
    redirectUri: redirectUri,
    scopes: const [],
  );

  PkcePair generatePkce() {
    final verifier = _randomUrlSafe(64);
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    return PkcePair(verifier: verifier, challenge: challenge);
  }

  String randomState() => _randomUrlSafe(24);

  Uri buildAuthorizeUrl({
    required OAuthProviderConfig config,
    required String state,
    required String codeChallenge,
  }) {
    return Uri.parse(config.authorizeUrl).replace(
      queryParameters: {
        'client_id': config.clientId,
        'response_type': 'code',
        'redirect_uri': config.redirectUri,
        if (config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
        'state': state,
        'code_challenge_method': 'S256',
        'code_challenge': codeChallenge,
      },
    );
  }

  /// Exchanges an authorization [code] for tokens. Returns null on failure.
  Future<OAuthTokens?> exchangeCode({
    required OAuthProviderConfig config,
    required String code,
    required String codeVerifier,
  }) {
    return _token(config, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': config.redirectUri,
      'client_id': config.clientId,
      'code_verifier': codeVerifier,
    });
  }

  /// Redeems a refresh token for a fresh access token. Returns null on failure.
  Future<OAuthTokens?> refresh({
    required OAuthProviderConfig config,
    required String refreshToken,
  }) {
    return _token(config, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': config.clientId,
    });
  }

  Future<OAuthTokens?> _token(
    OAuthProviderConfig config,
    Map<String, String> form,
  ) async {
    try {
      final res = await _httpClient.post(
        Uri.parse(config.tokenUrl),
        headers: {
          'content-type': 'application/x-www-form-urlencoded',
          'accept': 'application/json',
        },
        body: form,
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return null;
      }
      final body = jsonDecode(res.body);
      if (body is! Map) {
        return null;
      }
      final access = (body['access_token'] as String?)?.trim();
      if (access == null || access.isEmpty) {
        return null;
      }
      final expiresIn = body['expires_in'];
      final expiresAt = expiresIn is num
          ? DateTime.now().toUtc().add(Duration(seconds: expiresIn.round()))
          : null;
      return OAuthTokens(
        accessToken: access,
        refreshToken: (body['refresh_token'] as String?)?.trim(),
        expiresAtUtc: expiresAt,
      );
    } catch (_) {
      return null;
    }
  }

  String _randomUrlSafe(int bytes) {
    final raw = List<int>.generate(bytes, (_) => _random.nextInt(256));
    return base64UrlEncode(raw).replaceAll('=', '');
  }

  void close() => _httpClient.close();
}
