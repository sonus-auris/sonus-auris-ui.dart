import 'package:audio_dashcam/src/services/ambient_trigger_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ambient trigger parses native epoch payloads', () {
    final trigger = AmbientRecordingTrigger.fromJson({
      'kind': 'bluetooth',
      'label': 'Bluetooth connected',
      'detail': 'External Bluetooth device connected',
      'occurredAtMillis': 1780000000000,
    });

    expect(trigger.kind, 'bluetooth');
    expect(trigger.label, 'Bluetooth connected');
    expect(trigger.detail, 'External Bluetooth device connected');
    expect(
      trigger.occurredAt,
      DateTime.fromMillisecondsSinceEpoch(1780000000000),
    );
  });
}
