import 'package:audio_dashcam/src/services/background_capture_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only active recording may own a microphone foreground service', () {
    expect(
      BackgroundCaptureMode.scheduleStandby.startsMicrophoneService,
      isFalse,
      reason: 'an armed schedule is notification-only standby',
    );
    expect(
      BackgroundCaptureMode.recording.startsMicrophoneService,
      isTrue,
    );
  });
}
