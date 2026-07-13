// Uploads saved clips to the user's own SoundCloud as private tracks.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Result of publishing a clip to SoundCloud.
class SoundCloudUpload {
  const SoundCloudUpload({required this.permalinkUrl, required this.id});

  final String permalinkUrl;
  final String id;
}

/// Uploads saved clips to the user's own SoundCloud as private tracks
/// ("memories"). Only ever called when the user has linked SoundCloud *and*
/// turned auto-publish on, then explicitly saved a clip — clear, opt-in intent.
/// The audio is decrypted on-device by the caller before it gets here.
class SoundCloudClient {
  SoundCloudClient({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 120),
    this.apiBase = 'https://api.soundcloud.com',
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration requestTimeout;
  final String apiBase;

  Uri get _uploadEndpoint => Uri.parse('$apiBase/tracks');

  /// Uploads [audioBytes] (WAV or compressed AAC/M4A — SoundCloud infers the
  /// format from [fileName]) as a track. Defaults to **private** sharing so
  /// nothing becomes public unless the caller explicitly asks. Null on failure.
  Future<SoundCloudUpload?> uploadTrack({
    required String accessToken,
    required Uint8List audioBytes,
    required String title,
    String? description,
    bool isPublic = false,
    String fileName = 'sonus-auris-memory.wav',
  }) async {
    if (accessToken.trim().isEmpty ||
        audioBytes.isEmpty ||
        title.trim().isEmpty) {
      return null;
    }
    try {
      final request = http.MultipartRequest('POST', _uploadEndpoint)
        ..headers['Authorization'] = 'OAuth ${accessToken.trim()}'
        ..fields['track[title]'] = title.trim()
        ..fields['track[sharing]'] = isPublic ? 'public' : 'private'
        ..fields['track[description]'] =
            (description ?? 'Captured with Sonus Auris.').trim()
        ..files.add(
          http.MultipartFile.fromBytes(
            'track[asset_data]',
            audioBytes,
            filename: fileName,
          ),
        );
      final streamed = await _httpClient.send(request).timeout(requestTimeout);
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final body = jsonDecode(response.body);
      if (body is! Map) {
        return null;
      }
      final permalink = (body['permalink_url'] as String?)?.trim() ?? '';
      final id = '${body['id'] ?? ''}'.trim();
      if (permalink.isEmpty) {
        return null;
      }
      return SoundCloudUpload(permalinkUrl: permalink, id: id);
    } catch (_) {
      return null;
    }
  }

  /// Lists the user's own tracks whose title starts with [titlePrefix] (our
  /// "Day of My Life — …" archive tracks). Returns id + title pairs.
  Future<List<({String id, String title})>> listArchiveTracks({
    required String accessToken,
    required String titlePrefix,
    int limit = 200,
  }) async {
    if (accessToken.trim().isEmpty) {
      return const [];
    }
    try {
      final uri = Uri.parse('$apiBase/me/tracks')
          .replace(queryParameters: {'limit': '$limit'});
      final response = await _httpClient
          .get(uri, headers: {'Authorization': 'OAuth ${accessToken.trim()}'})
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      final body = jsonDecode(response.body);
      if (body is! List) {
        return const [];
      }
      final out = <({String id, String title})>[];
      for (final item in body) {
        if (item is! Map) continue;
        final title = (item['title'] as String?)?.trim() ?? '';
        final id = '${item['id'] ?? ''}'.trim();
        if (id.isNotEmpty && title.startsWith(titlePrefix)) {
          out.add((id: id, title: title));
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Deletes a track by id. Returns true on success (or if already gone).
  Future<bool> deleteTrack({
    required String accessToken,
    required String id,
  }) async {
    if (accessToken.trim().isEmpty || id.trim().isEmpty) {
      return false;
    }
    try {
      final response = await _httpClient
          .delete(
            Uri.parse('$apiBase/tracks/$id'),
            headers: {'Authorization': 'OAuth ${accessToken.trim()}'},
          )
          .timeout(requestTimeout);
      return response.statusCode == 200 ||
          response.statusCode == 204 ||
          response.statusCode == 404;
    } catch (_) {
      return false;
    }
  }

  void close() => _httpClient.close();
}
