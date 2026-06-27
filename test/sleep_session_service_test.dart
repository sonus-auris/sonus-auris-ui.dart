import 'dart:async';

import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/models/app_config.dart';
import 'package:audio_dashcam/src/models/sleep_sensor_sample.dart';
import 'package:audio_dashcam/src/models/sleep_stage.dart';
import 'package:audio_dashcam/src/services/local_notifications_service.dart';
import 'package:audio_dashcam/src/services/sleep_cycle_profile_store.dart';
import 'package:audio_dashcam/src/services/sleep_sensor_source.dart';
import 'package:audio_dashcam/src/services/sleep_session_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNotifications extends LocalNotificationsService {
  int smartFired = 0;
  int backstopFired = 0;
  int backstopScheduled = 0;
  int backstopCancelled = 0;
  int allCancelled = 0;

  @override
  Future<void> fireSleepAlarm({required bool backstop}) async {
    if (backstop) {
      backstopFired++;
    } else {
      smartFired++;
    }
  }

  @override
  Future<void> scheduleSleepBackstop(DateTime whenUtc) async {
    backstopScheduled++;
  }

  @override
  Future<void> cancelSleepBackstop() async {
    backstopCancelled++;
  }

  @override
  Future<void> cancelSleepAlarms() async {
    allCancelled++;
  }
}

class _FakeSensors implements SleepSensorSource {
  final _controller = StreamController<SleepSensorSample>.broadcast();
  bool started = false;

  @override
  Stream<SleepSensorSample> get samples => _controller.stream;

  @override
  Future<void> start(SleepSensorConsent consent) async => started = true;

  @override
  Future<void> stop() async => started = false;

  @override
  Future<void> dispose() async => _controller.close();

  void emit(SleepSensorSample s) => _controller.add(s);
}

AcousticDetection _epoch(DateTime end, SleepStage stage, {double depth = 0.4}) {
  return AcousticDetection(
    kind: AcousticDetectionKind.sleepEpoch,
    startedAtUtc: end.subtract(const Duration(seconds: 30)),
    endedAtUtc: end,
    confidence: 1,
    details: {
      'depth': depth,
      'stage': stage.name,
      'breathingRegularity': 0.5,
      'snoreFraction': 0.0,
    },
  );
}

AcousticDetection _cycle(int index, DateTime start) {
  return AcousticDetection(
    kind: AcousticDetectionKind.sleepCycle,
    startedAtUtc: start,
    endedAtUtc: start.add(const Duration(minutes: 90)),
    confidence: 1,
    details: {
      'cycleIndex': index,
      'lengthMinutes': 90.0,
      'minDepth': 0.3,
      'maxDepth': 0.8,
      'dominantCycleMinutes': 90.0,
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late _FakeNotifications notifications;
  late _FakeSensors sensors;
  late SleepSessionService service;
  final t0 = DateTime.utc(2026, 1, 1, 23, 0);

  SleepSessionService build() => SleepSessionService(
        notifications: notifications,
        profileStore: SleepCycleProfileStore(),
        sensorSource: sensors,
      );

  setUp(() {
    notifications = _FakeNotifications();
    sensors = _FakeSensors();
    service = build();
  });

  Future<void> feedFourCycles() async {
    for (var i = 1; i <= 4; i++) {
      await service.onAcousticDetection(
        _cycle(i, t0.add(Duration(minutes: 90 * (i - 1)))),
      );
    }
  }

  test('schedules an OS backstop on start', () async {
    await service.start(const AppConfig(deviceId: 't'), now: t0);
    expect(notifications.backstopScheduled, 1);
    await service.stop(now: t0.add(const Duration(hours: 8)));
  });

  test('smart wake fires AND cancels the OS backstop', () async {
    await service.start(const AppConfig(deviceId: 't'), now: t0);
    await feedFourCycles();
    // Light sleep inside the smart window (target ~7.5h).
    await service.onAcousticDetection(
      _epoch(t0.add(const Duration(minutes: 455)), SleepStage.light),
    );
    expect(notifications.smartFired, 1);
    expect(notifications.backstopFired, 0);
    expect(notifications.backstopCancelled, 1);
  });

  test('deep sleep in the window holds, backstop wakes at ~9h', () async {
    await service.start(const AppConfig(deviceId: 't'), now: t0);
    await feedFourCycles();
    // Deep at the 5th-cycle target → no wake.
    await service.onAcousticDetection(
      _epoch(t0.add(const Duration(minutes: 450)), SleepStage.deep, depth: 0.8),
    );
    expect(notifications.smartFired, 0);
    expect(notifications.backstopFired, 0);
    // Still deep at the backstop deadline → hard wake.
    await service.onAcousticDetection(
      _epoch(t0.add(const Duration(minutes: 540)), SleepStage.deep, depth: 0.8),
    );
    expect(notifications.backstopFired, 1);
    expect(notifications.smartFired, 0);
  });

  test('only the first alarm fires (no double-fire)', () async {
    await service.start(const AppConfig(deviceId: 't'), now: t0);
    await feedFourCycles();
    for (var i = 0; i < 5; i++) {
      await service.onAcousticDetection(
        _epoch(t0.add(Duration(minutes: 455 + i)), SleepStage.light),
      );
    }
    expect(notifications.smartFired, 1);
  });

  test('sensor buffer stays bounded if epochs never drain it', () async {
    await service.start(
      const AppConfig(deviceId: 't', sleepMotionConsent: true),
      now: t0,
    );
    expect(sensors.started, isTrue);
    for (var i = 0; i < 5000; i++) {
      sensors.emit(SleepSensorSample(atUtc: t0, accelMagnitude: 0.1));
    }
    await pumpEventQueue();
    expect(service.pendingSensorSampleCount, lessThanOrEqualTo(1200));
  });
}
