import 'dart:async';

import 'package:audio_dashcam/src/services/alarm_manager_initialization.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shares one initialization attempt across concurrent callers', () async {
    var initializeCalls = 0;
    final nativeAttempt = Completer<bool>();
    final gate = AlarmManagerInitializationGate(
      initializer: () {
        initializeCalls += 1;
        return nativeAttempt.future;
      },
    );

    final first = gate.ensureInitialized();
    final second = gate.ensureInitialized();

    expect(initializeCalls, 1);
    nativeAttempt.complete(true);
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(await gate.ensureInitialized(), isTrue);
    expect(initializeCalls, 1);
  });

  test('bounds each wait but recovers from a late native completion', () {
    fakeAsync((async) {
      var initializeCalls = 0;
      final nativeAttempt = Completer<bool>();
      final gate = AlarmManagerInitializationGate(
        initializer: () {
          initializeCalls += 1;
          return nativeAttempt.future;
        },
        waitTimeout: const Duration(seconds: 3),
      );
      bool? firstResult;
      bool? secondResult;

      gate.ensureInitialized().then((value) => firstResult = value);
      async.flushMicrotasks();
      expect(initializeCalls, 1);

      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(firstResult, isFalse);

      // A second caller reuses the still-running native invocation instead of
      // racing it with another AlarmService.start call.
      gate.ensureInitialized().then((value) => secondResult = value);
      async.flushMicrotasks();
      expect(initializeCalls, 1);

      nativeAttempt.complete(true);
      async.flushMicrotasks();
      expect(secondResult, isTrue);
      expect(gate.isInitialized, isTrue);
    });
  });

  test('retries after an explicit initialization failure', () async {
    var initializeCalls = 0;
    final gate = AlarmManagerInitializationGate(
      initializer: () async {
        initializeCalls += 1;
        return initializeCalls > 1;
      },
    );

    expect(await gate.ensureInitialized(), isFalse);
    expect(await gate.ensureInitialized(), isTrue);
    expect(initializeCalls, 2);
  });
}
