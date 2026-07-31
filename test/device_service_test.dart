import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sonus_auris_console/src/config/console_config.dart';
import 'package:sonus_auris_console/src/services/device_service.dart';

void main() {
  test(
    'revocation invalidates Rust token before marking Supabase row',
    () async {
      final requests = <http.Request>[];
      final service = DeviceService(
        config: const ConsoleConfig(
          supabaseUrl: 'https://project.supabase.co',
          supabaseAnonKey: 'sb_publishable_test',
          backendBaseUrl: 'https://api.sonus.example',
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'api.sonus.example') {
            return http.Response(
              '{"ok":true,"installId":"phone-1","backendTokensRevoked":1}',
              200,
            );
          }
          return http.Response('', 204);
        }),
      );

      final error = await service.revoke(
        accessToken: 'identity-token',
        deviceId: 'phone-1',
        nowUtc: DateTime.utc(2026, 7, 25, 12),
      );

      expect(error, isNull);
      expect(requests, hasLength(2));
      expect(requests.first.url.path, '/api/mobile/v1/devices/phone-1/revoke');
      expect(
        requests.first.headers['x-supabase-auth'],
        'Bearer identity-token',
      );
      expect(requests.last.method, 'PATCH');
      expect(jsonDecode(requests.last.body), {
        'revoked_at': '2026-07-25T12:00:00.000Z',
      });
      service.close();
    },
  );

  test('a Rust revocation failure leaves the Supabase row active', () async {
    var requests = 0;
    final service = DeviceService(
      config: const ConsoleConfig(
        supabaseUrl: 'https://project.supabase.co',
        supabaseAnonKey: 'sb_publishable_test',
        backendBaseUrl: 'https://api.sonus.example',
      ),
      httpClient: MockClient((request) async {
        requests += 1;
        return http.Response('unavailable', 503);
      }),
    );

    final error = await service.revoke(
      accessToken: 'identity-token',
      deviceId: 'phone-1',
    );

    expect(error, contains('server token failed'));
    expect(requests, 1);
    service.close();
  });
}
