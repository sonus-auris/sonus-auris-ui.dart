import 'dart:convert';

import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/cloud_secrets.dart';
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

  final detection = AcousticDetection(
    kind: AcousticDetectionKind.snore,
    startedAtUtc: DateTime.utc(2026, 1, 1, 2, 0, 0),
    endedAtUtc: DateTime.utc(2026, 1, 1, 2, 0, 1),
    confidence: 0.9,
    details: const {'peakDb': -12.0},
  );

  test('posts detections to PostgREST with auth + apikey headers', () async {
    late http.Request captured;
    final client = SupabaseRestClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('', 201);
      }),
    );
    final error = await client.insertDetections(
      config: config,
      secrets: secrets,
      detections: [detection],
    );
    expect(error, isNull);
    expect(
      captured.url.toString(),
      'https://proj.supabase.co/rest/v1/acoustic_events',
    );
    expect(captured.headers['apikey'], 'anon-key');
    expect(captured.headers['authorization'], 'Bearer user-jwt');
    expect(captured.headers['prefer'], 'return=minimal');
    final body = jsonDecode(captured.body) as List;
    expect(body, hasLength(1));
    final row = body.first as Map<String, dynamic>;
    expect(row['device_id'], 'device-xyz');
    expect(row['kind'], 'snore');
    expect(row['confidence'], 0.9);
    expect((row['details'] as Map)['peakDb'], -12.0);
  });

  test('returns an error string on a non-2xx response', () async {
    final client = SupabaseRestClient(
      httpClient: MockClient((_) async => http.Response('denied', 401)),
    );
    final error = await client.insertDetections(
      config: config,
      secrets: secrets,
      detections: [detection],
    );
    expect(error, contains('401'));
  });

  test('no-ops with an empty list and refuses without a session', () async {
    var called = false;
    final client = SupabaseRestClient(
      httpClient: MockClient((_) async {
        called = true;
        return http.Response('', 201);
      }),
    );
    expect(
      await client.insertDetections(
        config: config,
        secrets: secrets,
        detections: const [],
      ),
      isNull,
    );
    expect(
      await client.insertDetections(
        config: config,
        secrets: const CloudSecrets(),
        detections: [detection],
      ),
      isNotNull,
    );
    expect(called, isFalse);
  });

  test('refuses a service-role key without sending it', () async {
    var called = false;
    final client = SupabaseRestClient(
      httpClient: MockClient((_) async {
        called = true;
        return http.Response('', 201);
      }),
    );
    const unsafe = AppConfig(
      deviceId: 'device-xyz',
      supabaseUrl: 'https://proj.supabase.co',
      supabaseAnonKey: 'sb_secret_never-ship',
    );

    final error = await client.insertDetections(
      config: unsafe,
      secrets: secrets,
      detections: [detection],
    );

    expect(error, contains('never a secret or service-role key'));
    expect(error, isNot(contains('sb_secret_never-ship')));
    expect(called, isFalse);
  });

  test('reads and upserts typed portable account settings', () async {
    late http.Request updateRequest;
    final seedClient = SupabaseRestClient();
    final row = seedClient.userSettingsForUpsert(config).toJson()
      ..['user_id'] = '11111111-1111-1111-1111-111111111111';
    final client = SupabaseRestClient(
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(jsonEncode([row]), 200);
        }
        updateRequest = request;
        return http.Response('', 201);
      }),
    );

    final loaded = await client.fetchUserSettings(
      config: config,
      secrets: secrets,
    );
    expect(loaded.error, isNull);
    expect(loaded.settings?.preferredUseCase, 'security');
    expect(loaded.settings?.userId, '11111111-1111-1111-1111-111111111111');

    final error = await client.upsertUserSettings(
      config: config,
      secrets: secrets,
    );
    expect(error, isNull);
    expect(updateRequest.url.queryParameters['on_conflict'], 'user_id');
    expect(updateRequest.headers['authorization'], 'Bearer user-jwt');
    expect(updateRequest.headers['prefer'], contains('merge-duplicates'));
    final body = jsonDecode(updateRequest.body) as List;
    final payload = body.single as Map<String, dynamic>;
    expect(payload, isNot(contains('user_id')));
    expect(payload, isNot(contains('device_id')));
    expect(payload, isNot(contains('supabase_anon_key')));
    expect(payload['device_retention_hours'], 50);
  });

  test('merges account settings without touching device-only controls', () {
    const local = AppConfig(
      deviceId: 'device-local',
      supabaseUrl: 'https://proj.supabase.co',
      supabaseAnonKey: 'anon-key',
      s3Bucket: 'device-bucket',
      locationTaggingEnabled: true,
      autoStartCaptureEnabled: true,
      pauseUploadsOnLowBattery: false,
    );
    final client = SupabaseRestClient();
    final remote = client.userSettingsForUpsert(
      local.copyWith(
        useCase: 'music',
        deviceRetentionHours: 72,
        cloudRetentionHours: 720,
        micSensitivity: 1.5,
      ),
    );

    final merged = client.mergeUserSettings(local, remote);
    expect(merged.useCase, 'music');
    expect(merged.deviceRetentionHours, 72);
    expect(merged.cloudRetentionHours, 720);
    expect(merged.micSensitivity, 1.5);
    expect(merged.deviceId, 'device-local');
    expect(merged.s3Bucket, 'device-bucket');
    expect(merged.locationTaggingEnabled, isTrue);
    expect(merged.autoStartCaptureEnabled, isTrue);
    expect(merged.pauseUploadsOnLowBattery, isFalse);
  });
}
