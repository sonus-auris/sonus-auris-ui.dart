import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/services/memory_publisher.dart';
import 'package:audio_dashcam/src/services/spotify_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final publisher = MemoryPublisher();

  AppConfig cfg({bool spotify = false}) =>
      AppConfig(deviceId: 'd', spotifyAutoPlaylist: spotify);

  const linked = CloudSecrets(spotifyAccessToken: 'sp-token');

  group('spotify intent gating', () {
    test('off unless the setting is on AND the account is linked', () {
      expect(publisher.wantsSpotify(cfg(), const CloudSecrets()), isFalse);
      expect(
        publisher.wantsSpotify(cfg(spotify: true), const CloudSecrets()),
        isFalse,
      );
      expect(publisher.wantsSpotify(cfg(), linked), isFalse);
      expect(publisher.wantsSpotify(cfg(spotify: true), linked), isTrue);
    });

    test(
      'publishing nothing when not opted in returns an empty result',
      () async {
        final result = await publisher.publishRecognisedSongs(
          config: cfg(),
          secrets: linked,
          recognisedSongs: const [RecognisedSong(title: 'x')],
        );
        expect(result.didAnything, isFalse);
      },
    );
  });

  group('spotify search query', () {
    test('includes artist when present', () {
      expect(
        SpotifyClient.searchQuery(title: 'Teardrop', artist: 'Massive Attack'),
        'track:"Teardrop" artist:"Massive Attack"',
      );
    });

    test('omits artist when blank', () {
      expect(SpotifyClient.searchQuery(title: 'Untitled'), 'track:"Untitled"');
    });
  });
}
