import 'package:audio_dashcam/src/platform/offline_development_mode.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('offline override requires an explicit non-release build', () {
    expect(
      isOfflineDevelopmentModeEnabled(releaseMode: false, requested: true),
      isTrue,
    );
    expect(
      isOfflineDevelopmentModeEnabled(releaseMode: false, requested: false),
      isFalse,
    );
    expect(
      isOfflineDevelopmentModeEnabled(releaseMode: true, requested: true),
      isFalse,
    );
  });

  test('release compilation ignores an explicitly requested override', () {
    if (!kReleaseMode) {
      return;
    }
    expect(offlineDevelopmentModeRequested, isTrue);
    expect(isOfflineDevelopmentModeEnabled(), isFalse);
  });
}
