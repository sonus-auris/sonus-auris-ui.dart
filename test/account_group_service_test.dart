import 'dart:convert';
import 'dart:math';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/services/account_group_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const config = AppConfig(
  deviceId: 'device-a',
  supabaseUrl: 'https://project.supabase.co',
  supabaseAnonKey: 'publishable-client-key',
);
const secrets = CloudSecrets(
  supabaseAccessToken: 'user-jwt',
  supabaseUserId: '11111111-1111-4111-8111-111111111111',
);

void main() {
  test(
    'creates an expiring email invite without sending the raw address',
    () async {
      late Map<String, Object?> payload;
      final client = MockClient((request) async {
        expect(request.url.path, '/rest/v1/rpc/create_account_invite');
        expect(request.headers['authorization'], 'Bearer user-jwt');
        payload = (jsonDecode(request.body) as Map).cast<String, Object?>();
        return http.Response(
          jsonEncode([
            {
              'invite_id': '22222222-2222-4222-8222-222222222222',
              'group_id': '11111111-1111-4111-8111-111111111111',
              'expires_at': '2026-07-26T12:00:00Z',
            },
          ]),
          200,
        );
      });
      final service = AccountGroupService(
        httpClient: client,
        secureRandom: Random(7),
      );

      final invite = await service.createInvite(
        config: config,
        secrets: secrets,
        delivery: AccountInviteDelivery.email,
        destination: 'secondary@example.com',
      );

      expect(payload['p_delivery_kind'], 'email');
      expect(payload['p_destination_hint'], 'se***@example.com');
      expect(jsonEncode(payload), isNot(contains('secondary@example.com')));
      expect((payload['p_token'] as String).length, greaterThanOrEqualTo(32));
      expect(invite.link.scheme, 'sonusauris');
      expect(invite.link.host, 'invite');
      expect(invite.link.path, '/join');
      expect(invite.link.queryParameters['token'], invite.token);
    },
  );

  test('accepts a single-use invite through the owner-scoped RPC', () async {
    final token = List.filled(40, 'x').join();
    final client = MockClient((request) async {
      expect(request.url.path, '/rest/v1/rpc/accept_account_invite');
      expect(jsonDecode(request.body), {'p_token': token});
      return http.Response(
        jsonEncode('11111111-1111-4111-8111-111111111111'),
        200,
      );
    });
    final service = AccountGroupService(httpClient: client);

    final groupId = await service.acceptInvite(
      config: config,
      secrets: secrets,
      token: token,
    );

    expect(groupId, '11111111-1111-4111-8111-111111111111');
  });
}
