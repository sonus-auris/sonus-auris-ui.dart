// Adds songs recognised in saved clips to the user's private Spotify 'memories' playlist.
import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import 'spotify_client.dart';

/// A song recognised in a saved clip (from the on-device Shazam match).
class RecognisedSong {
  const RecognisedSong({required this.title, this.artist});
  final String title;
  final String? artist;
}

class MemoryPublishResult {
  const MemoryPublishResult({
    this.spotifyAddedCount = 0,
    this.notes = const [],
  });

  final int spotifyAddedCount;
  final List<String> notes;

  bool get didAnything => spotifyAddedCount > 0;
}

/// Adds songs the user heard to their private Spotify "memories" playlist — and
/// only when they've clearly opted in (Spotify linked **and** the auto-playlist
/// setting on). Invoked on a permanent save, itself an explicit user action.
/// De-duplicated both within a batch and against the existing playlist, so a
/// song is never added twice. (SoundCloud is handled separately by the
/// `DayOfLifeArchiver` — see "Day of My Life".)
class MemoryPublisher {
  MemoryPublisher({SpotifyClient? spotify})
    : _spotify = spotify ?? SpotifyClient();

  final SpotifyClient _spotify;

  bool wantsSpotify(AppConfig config, CloudSecrets secrets) =>
      config.spotifyAutoPlaylist && secrets.hasSpotifyToken;

  Future<MemoryPublishResult> publishRecognisedSongs({
    required AppConfig config,
    required CloudSecrets secrets,
    required List<RecognisedSong> recognisedSongs,
  }) async {
    if (!wantsSpotify(config, secrets) || recognisedSongs.isEmpty) {
      return const MemoryPublishResult();
    }
    final seen = <String>{};
    var added = 0;
    for (final song in recognisedSongs) {
      final key = '${song.title}|${song.artist ?? ''}'.toLowerCase();
      if (!seen.add(key)) {
        continue; // de-dupe within this batch
      }
      // The client also de-dupes against the playlist's existing tracks.
      final playlistId = await _spotify.addRecognisedSong(
        accessToken: secrets.spotifyAccessToken,
        title: song.title,
        artist: song.artist,
      );
      if (playlistId != null) {
        added += 1;
      }
    }
    return MemoryPublishResult(
      spotifyAddedCount: added,
      notes: added > 0
          ? ['Added $added song(s) to your Spotify memories.']
          : const [],
    );
  }

  void close() => _spotify.close();
}
