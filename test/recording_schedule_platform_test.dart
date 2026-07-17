import 'dart:async';

import 'package:audio_dashcam/src/models/recording_schedule.dart';
import 'package:audio_dashcam/src/services/local_notifications_service.dart';
import 'package:audio_dashcam/src/services/recording_schedule_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAndroidAlarms implements AndroidScheduleAlarmClient {
  _FakeAndroidAlarms({this.initializeResult = true});

  bool initializeResult;
  Completer<bool>? initializeBlock;
  int initializeCalls = 0;
  final List<int> cancelledIds = [];
  final List<({DateTime at, int id})> scheduled = [];

  @override
  Future<bool> initialize() {
    initializeCalls += 1;
    return initializeBlock?.future ?? Future<bool>.value(initializeResult);
  }

  @override
  Future<bool> cancel(int id) async {
    cancelledIds.add(id);
    return true;
  }

  @override
  Future<bool> schedule(DateTime at, int id) async {
    scheduled.add((at: at, id: id));
    return true;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'schedule operations wait for one shared Android initialization',
    () async {
      final alarms = _FakeAndroidAlarms()..initializeBlock = Completer<bool>();
      final platform = PluginSchedulePlatform(
        notifications: LocalNotificationsService(),
        androidAlarmClient: alarms,
        hostPlatform: ScheduleHostPlatform.android,
        exactAlarmPermissionRequester: () async => true,
        alarmInitializationTimeout: const Duration(minutes: 1),
      );
      final transition = ScheduleTransition(
        at: DateTime(2026, 6, 15, 9),
        startsRecording: true,
      );

      final registration = platform.register([transition]);
      final cancellation = platform.cancelAll();
      await Future<void>.delayed(Duration.zero);

      expect(alarms.initializeCalls, 1);
      expect(alarms.cancelledIds, isEmpty);
      expect(alarms.scheduled, isEmpty);

      alarms.initializeBlock!.complete(true);
      await Future.wait([registration, cancellation]);

      // Cancellation was the latest desired state, so the older registration is
      // discarded rather than racing native alarm operations after readiness.
      expect(alarms.scheduled, isEmpty);
      expect(alarms.cancelledIds, hasLength(64));
      expect(alarms.initializeCalls, 1);
    },
  );

  test(
    'an explicit initialization failure is retried on the next sync',
    () async {
      final alarms = _FakeAndroidAlarms(initializeResult: false);
      final platform = PluginSchedulePlatform(
        notifications: LocalNotificationsService(),
        androidAlarmClient: alarms,
        hostPlatform: ScheduleHostPlatform.android,
        exactAlarmPermissionRequester: () async => true,
      );
      final transition = ScheduleTransition(
        at: DateTime(2026, 6, 15, 9),
        startsRecording: true,
      );

      await platform.register([transition]);
      expect(alarms.initializeCalls, 1);
      expect(alarms.scheduled, isEmpty);

      alarms.initializeResult = true;
      await platform.register([transition]);
      expect(alarms.initializeCalls, 2);
      expect(alarms.scheduled, hasLength(1));
    },
  );

  test(
    'denied exact-alarm access leaves the native alarm queue untouched',
    () async {
      final alarms = _FakeAndroidAlarms();
      final platform = PluginSchedulePlatform(
        notifications: LocalNotificationsService(),
        androidAlarmClient: alarms,
        hostPlatform: ScheduleHostPlatform.android,
        exactAlarmPermissionRequester: () async => false,
      );

      await platform.register([
        ScheduleTransition(at: DateTime(2026, 6, 15, 9), startsRecording: true),
      ]);

      expect(alarms.initializeCalls, 0);
      expect(alarms.scheduled, isEmpty);
    },
  );
}
