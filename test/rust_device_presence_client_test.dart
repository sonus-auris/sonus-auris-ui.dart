import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/services/rust_device_presence_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds a secure Rust device presence websocket URL', () {
    final uri = RustDevicePresenceClient.presenceUri(
      const AppConfig(
        deviceId: 'device-a',
        backendBaseUrl: 'https://api.sonusauris.app/base',
      ),
    );

    expect(uri.scheme, 'wss');
    expect(uri.host, 'api.sonusauris.app');
    expect(uri.path, '/base/api/mobile/v1/devices/presence');
    expect(uri.query, isEmpty);
  });

  test('rejects insecure non-loopback Rust presence endpoints', () {
    expect(
      () => RustDevicePresenceClient.presenceUri(
        const AppConfig(
          deviceId: 'device-a',
          backendBaseUrl: 'http://api.example.test',
        ),
      ),
      throwsFormatException,
    );
  });

  test('parses bounded online device IDs from Rust presence frames', () {
    expect(
      rustOnlineDeviceIds({
        'type': 'presence',
        'onlineDeviceIds': ['a', 'b', '', 7, 'a'],
      }),
      {'a', 'b'},
    );
    expect(rustOnlineDeviceIds({'type': 'ready'}), isEmpty);
  });
}
