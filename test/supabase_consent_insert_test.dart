import 'dart:convert';

import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
import 'package:audio_dashcam/src/models/consent.dart';
import 'package:audio_dashcam/src/services/supabase_rest_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const config = AppConfig(
    deviceId: 'device-xyz',
    supabaseUrl: 'https://proj.supabase.co',
    supabaseAnonKey: 'anon-key',
  );
  const secrets = CloudSecrets(supabaseAccessToken: 'user-jwt');

  final record = ConsentRecord(
    consentVersion: 'audio-dashcam-consent-v1',
    acceptedAtUtc: DateTime.utc(2026, 6, 28, 7),
    platform: 'ios',
    grants: const {'microphone': true, 'location': false},
  );

  test('posts the consent row to user_consents with auth headers', () async {
    late http.Request captured;
    final client = SupabaseRestClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('', 201);
      }),
    );
    final error = await client.insertConsent(
      config: config,
      secrets: secrets,
      record: record,
    );
    expect(error, isNull);
    expect(
      captured.url.toString(),
      'https://proj.supabase.co/rest/v1/user_consents',
    );
    expect(captured.headers['apikey'], 'anon-key');
    expect(captured.headers['authorization'], 'Bearer user-jwt');
    final body = jsonDecode(captured.body) as List;
    final row = body.single as Map<String, dynamic>;
    expect(row['device_id'], 'device-xyz');
    expect(row['consent_version'], 'audio-dashcam-consent-v1');
    expect((row['granted'] as Map)['microphone'], isTrue);
  });

  test('refuses to insert without a signed-in session', () async {
    var called = false;
    final client = SupabaseRestClient(
      httpClient: MockClient((_) async {
        called = true;
        return http.Response('', 201);
      }),
    );
    final error = await client.insertConsent(
      config: config,
      secrets: const CloudSecrets(),
      record: record,
    );
    expect(error, isNotNull);
    expect(called, isFalse);
  });

  test('returns an error string on a non-2xx response', () async {
    final client = SupabaseRestClient(
      httpClient: MockClient((_) async => http.Response('nope', 403)),
    );
    final error = await client.insertConsent(
      config: config,
      secrets: secrets,
      record: record,
    );
    expect(error, contains('403'));
  });
}
