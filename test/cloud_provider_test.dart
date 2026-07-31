import 'package:audio_dashcam/src/models/cloud_provider.dart';
import 'package:audio_dashcam/src/services/sound_recorder_backend_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dropbox persists locally and uses the backend canonical name', () {
    expect(CloudProvider.fromName('dropbox'), CloudProvider.dropbox);
    expect(CloudProvider.dropbox.requiresBackend, isTrue);
    expect(
      SoundRecorderBackendClient.canonicalProviderName(CloudProvider.dropbox),
      'dropbox',
    );
  });
}
