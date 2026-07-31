// Adds Shazam-identified songs to a private 'memories' playlist on the user's Spotify.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Adds Shazam-identified songs to a private "memories" playlist on the user's
/// Spotify. Spotify's API does not allow uploading arbitrary user audio, so the
/// memory we create is the *recognised track* — a running playlist of the music
/// you actually lived through. Opt-in: only runs when Spotify is linked and the
/// auto-playlist setting is on.
class SpotifyClient {
  SpotifyClient({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 30),
    this.apiBase = 'https://api.spotify.com/v1',
    this.playlistName = 'Sonus Auris Memories',
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration requestTimeout;
  final String apiBase;
  final String playlistName;

  Map<String, String> _auth(String token) => {
    'authorization': 'Bearer ${token.trim()}',
    'accept': 'application/json',
  };

  /// Builds the Spotify search query for a recognised song. Exposed for testing.
  static String searchQuery({required String title, String? artist}) {
    final t = title.trim();
    final a = (artist ?? '').trim();
    return a.isEmpty ? 'track:"$t"' : 'track:"$t" artist:"$a"';
  }

  /// Finds the best-matching track URI for a recognised song, or null.
  Future<String?> findTrackUri({
    required String accessToken,
    required String title,
    String? artist,
  }) async {
    if (title.trim().isEmpty) {
      return null;
    }
    final uri = Uri.parse('$apiBase/search').replace(
      queryParameters: {
        'q': searchQuery(title: title, artist: artist),
        'type': 'track',
        'limit': '1',
      },
    );
    final res = await _get(uri, accessToken);
    final items = (((res?['tracks']) as Map?)?['items']) as List?;
    if (items == null || items.isEmpty) {
      return null;
    }
    final first = items.first;
    final trackUri = (first is Map) ? first['uri'] as String? : null;
    return (trackUri != null && trackUri.trim().isNotEmpty) ? trackUri : null;
  }

  /// Adds a recognised song to the memories playlist (created on first use).
  /// Skips silently if the track can't be found or is already present. Returns
  /// the playlist id on success, null otherwise.
  Future<String?> addRecognisedSong({
    required String accessToken,
    required String title,
    String? artist,
  }) async {
    try {
      final trackUri = await findTrackUri(
        accessToken: accessToken,
        title: title,
        artist: artist,
      );
      if (trackUri == null) {
        return null;
      }
      final userId = await _currentUserId(accessToken);
      if (userId == null) {
        return null;
      }
      final playlistId = await _findOrCreatePlaylist(
        accessToken: accessToken,
        userId: userId,
      );
      if (playlistId == null) {
        return null;
      }
      if (await _playlistContains(accessToken, playlistId, trackUri)) {
        return playlistId; // de-duped: already a memory.
      }
      final added = await _post(
        Uri.parse('$apiBase/playlists/$playlistId/tracks'),
        accessToken,
        {
          'uris': [trackUri],
        },
      );
      return added != null ? playlistId : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _currentUserId(String accessToken) async {
    final res = await _get(Uri.parse('$apiBase/me'), accessToken);
    return (res?['id'] as String?)?.trim();
  }

  Future<String?> _findOrCreatePlaylist({
    required String accessToken,
    required String userId,
  }) async {
    final list = await _get(
      Uri.parse(
        '$apiBase/me/playlists',
      ).replace(queryParameters: {'limit': '50'}),
      accessToken,
    );
    final items = (list?['items']) as List?;
    if (items != null) {
      for (final item in items) {
        if (item is Map && (item['name'] as String?)?.trim() == playlistName) {
          return item['id'] as String?;
        }
      }
    }
    final created = await _post(
      Uri.parse('$apiBase/users/$userId/playlists'),
      accessToken,
      {
        'name': playlistName,
        'public': false,
        'description': 'Songs Sonus Auris heard around you. Private.',
      },
    );
    return created?['id'] as String?;
  }

  Future<bool> _playlistContains(
    String accessToken,
    String playlistId,
    String trackUri,
  ) async {
    final res = await _get(
      Uri.parse('$apiBase/playlists/$playlistId/tracks').replace(
        queryParameters: {'fields': 'items(track(uri))', 'limit': '100'},
      ),
      accessToken,
    );
    final items = (res?['items']) as List?;
    if (items == null) {
      return false;
    }
    for (final item in items) {
      final track = item is Map ? item['track'] : null;
      final uri = track is Map ? track['uri'] : null;
      if (uri == trackUri) {
        return true;
      }
    }
    return false;
  }

  Future<Map<String, dynamic>?> _get(Uri uri, String accessToken) async {
    final res = await _httpClient
        .get(uri, headers: _auth(accessToken))
        .timeout(requestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return null;
    }
    final body = jsonDecode(res.body);
    return body is Map<String, dynamic> ? body : null;
  }

  Future<Map<String, dynamic>?> _post(
    Uri uri,
    String accessToken,
    Map<String, Object?> json,
  ) async {
    final res = await _httpClient
        .post(
          uri,
          headers: {..._auth(accessToken), 'content-type': 'application/json'},
          body: jsonEncode(json),
        )
        .timeout(requestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return null;
    }
    if (res.body.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final body = jsonDecode(res.body);
    return body is Map<String, dynamic> ? body : <String, dynamic>{};
  }

  void close() => _httpClient.close();
}
