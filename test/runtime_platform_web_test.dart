import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_dashcam/src/platform/runtime_platform.dart';

void main() {
  test(
    'browser platform probes never touch dart:io Platform',
    () {
      expect(RuntimePlatform.isWeb, isTrue);
      expect(RuntimePlatform.isAndroid, isFalse);
      expect(RuntimePlatform.isIOS, isFalse);
      expect(RuntimePlatform.isMacOS, isFalse);
      expect(RuntimePlatform.isWindows, isFalse);
      expect(RuntimePlatform.isLinux, isFalse);
      expect(RuntimePlatform.operatingSystem, 'web');
      expect(RuntimePlatform.resolvedExecutable, isEmpty);
    },
    skip: !kIsWeb ? 'Runs in the Chrome test target.' : false,
  );
}
