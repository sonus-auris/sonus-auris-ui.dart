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
}
