import 'package:audio_dashcam/src/models/client_telemetry_event.dart';
import 'package:audio_dashcam/src/services/diagnostic_log.dart';
import 'package:audio_dashcam/src/services/ores_telemetry_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'emits redacted next-loggers and OTEL data through Supabase sink',
    () async {
      final batches = <List<ClientTelemetryEvent>>[];
      var sequence = 0;
      final bridge = OresTelemetryBridge(
        sessionId: '12345678-1234-1234-1234-123456789abc',
        platform: 'android',
        appVersion: '1.0.0+1',
        batchSize: 1,
        idFactory: () =>
            '00000000-0000-4000-8000-${(++sequence).toString().padLeft(12, '0')}',
        clock: () => DateTime.utc(2026, 8, 13, 12, 30),
        sendBatch: batches.add,
      );

      await bridge.record(
        DiagnosticEntry(
          occurredAtUtc: DateTime.utc(2026, 8, 13, 12, 30),
          level: 'error',
          event: 'auth.otp_failed',
          message:
              'Request for person@example.com failed with Bearer secret-value',
          details: const <String, Object?>{
            'error_code': 'over_email_send_rate_limit',
            'otp': '123456',
            'note': 'private user text',
            'url': 'https://example.test/?access_token=top-secret',
          },
        ),
      );
      await bridge.flush();

      expect(batches, hasLength(1));
      final event = batches.single.single;
      expect(event.source, 'ores-otel');
      expect(event.transport, contains('otel'));
      expect(event.level, 'error');
      expect(event.event, 'auth.otp_failed');
      expect(event.message, contains('[redacted-email]'));
      expect(event.message, contains('Bearer [redacted]'));
      expect(event.message, isNot(contains('person@example.com')));
      expect(event.traceId, '12345678123412341234123456789abc');
      expect(event.spanId, hasLength(16));
      expect(event.details['schema'], 'next-loggers/v1');
      final fields = event.details['fields']! as Map<String, Object?>;
      expect(fields['error_code'], 'over_email_send_rate_limit');
      expect(fields['otp'], '[redacted]');
      expect(fields['note'], '[omitted]');
      expect(fields['url'], contains('access_token=[redacted]'));
      final otel = event.details['otel_log_record']! as Map<String, Object?>;
      expect(otel['severityText'], 'ERROR');
      expect(otel['severityNumber'], 17);
      final attributes = otel['attributes']! as Map<String, Object?>;
      expect(attributes['service.name'], 'sonus-auris-flutter');
      expect(attributes['next_logger.schema'], 'next-loggers/v1');

      await bridge.close();
    },
  );

  test('omits message content for audio and transcript events', () async {
    final batches = <List<ClientTelemetryEvent>>[];
    final bridge = OresTelemetryBridge(
      sessionId: 'session',
      platform: 'web',
      batchSize: 1,
      sendBatch: batches.add,
    );

    await bridge.record(
      DiagnosticEntry(
        occurredAtUtc: DateTime.utc(2026),
        level: 'info',
        event: 'speech.transcript_received',
        message: 'private spoken words',
      ),
    );

    expect(batches.single.single.message, '[redacted user content]');
    await bridge.close();
  });
}
