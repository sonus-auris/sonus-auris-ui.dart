import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/sleep_cycle_detector.dart';
import 'package:audio_dashcam/src/services/acoustic/spectral_features.dart';
import 'package:flutter_test/flutter_test.dart';

const _lightSleepFrame = SpectralFrame(
  rms: 0.006,
  db: -48,
  centroidHz: 820,
  flatness: 0.62,
  crest: 4,
  rolloffHz: 1500,
  dominantHz: 220,
  lowBandRatio: 0.12,
  speechBandRatio: 0.22,
  totalPower: 1,
);

const _deepSleepFrame = SpectralFrame(
  rms: 0.01,
  db: -44,
  centroidHz: 520,
  flatness: 0.35,
  crest: 8,
  rolloffHz: 900,
  dominantHz: 160,
  lowBandRatio: 0.34,
  speechBandRatio: 0.16,
  totalPower: 1,
);

const _arousalFrame = SpectralFrame(
  rms: 0.04,
  db: -28,
  centroidHz: 2400,
  flatness: 0.78,
  crest: 2,
  rolloffHz: 4300,
  dominantHz: 1300,
  lowBandRatio: 0.05,
  speechBandRatio: 0.58,
  totalPower: 1,
);

List<AcousticDetection> _driveCycles(
  List<int> cycleMinutes, {
  List<double> seeds = const [],
  bool alarmsEnabled = true,
  Set<int> alarmCycles = const {5, 6},
  Set<int> deepCycles = const {},
  String captureSessionId = '',
}) {
  final detector = SleepCycleDetector(
    frameSeconds: 60,
    captureSessionId: captureSessionId,
    config: SleepCycleConfig(
      cycleMinutesByIndex: seeds,
      alarmsEnabled: alarmsEnabled,
      alarmCycles: alarmCycles,
      sleepOnsetMinutes: 3,
      bucketSeconds: 60,
    ),
  );
  final base = DateTime.utc(2026, 1, 1, 22);
  final boundaries = <int>{};
  var elapsed = 0;
  for (final minutes in cycleMinutes) {
    elapsed += minutes;
    boundaries.add(elapsed);
  }

  final events = <AcousticDetection>[];
  var currentCycle = 1;
  for (var minute = 0; minute <= elapsed + 2; minute++) {
    final isBoundary = boundaries.contains(minute);
    final frame = isBoundary
        ? _arousalFrame
        : deepCycles.contains(currentCycle)
        ? _deepSleepFrame
        : _lightSleepFrame;
    events.addAll(detector.add(frame, base.add(Duration(minutes: minute))));
    if (isBoundary) {
      currentCycle += 1;
    }
  }
  events.addAll(detector.flush());
  return events;
}

void main() {
  test('learns short 75 minute cycles and emits cycle 5 and 6 alarms', () {
    final events = _driveCycles(List<int>.filled(6, 75));
    final alarms = events
        .where((event) => event.kind == AcousticDetectionKind.sleepCycleAlarm)
        .toList();

    expect(alarms.map((event) => event.details['cycleIndex']), [5, 6]);
    expect(alarms.first.details['observedCycleMinutes'], closeTo(75, 2));
    expect(
      alarms.first.details['estimatedCycleMinutes'] as double,
      lessThan(88),
    );
  });

  test('does not preempt 120 minute cycles with the 90 minute baseline', () {
    final events = _driveCycles(List<int>.filled(6, 120));
    final cycleOne = events.firstWhere(
      (event) => event.details['cycleIndex'] == 1,
    );
    final alarms = events
        .where((event) => event.kind == AcousticDetectionKind.sleepCycleAlarm)
        .toList();

    expect(cycleOne.details['observedCycleMinutes'], closeTo(120, 2));
    expect(alarms.map((event) => event.details['cycleIndex']), [5, 6]);
    expect(
      alarms.first.details['estimatedCycleMinutes'] as double,
      greaterThan(95),
    );
  });

  test('tracks different cycle lengths as the night progresses', () {
    final events = _driveCycles([80, 85, 95, 105, 110, 115]);
    final fifthAlarm = events.firstWhere(
      (event) =>
          event.kind == AcousticDetectionKind.sleepCycleAlarm &&
          event.details['cycleIndex'] == 5,
    );
    final vector = fifthAlarm.details['cycleMinutesByIndex'] as List;

    expect(fifthAlarm.details['observedCycleMinutes'], closeTo(110, 2));
    expect(vector[0] as double, lessThan(vector[4] as double));
  });

  test('defers cycle 5 alarm when cycles 4 and 5 are deep sleep', () {
    final events = _driveCycles(
      List<int>.filled(6, 90),
      seeds: const [90, 90, 90, 90, 90, 90],
      deepCycles: const {4, 5},
    );
    final alarms = events
        .where((event) => event.kind == AcousticDetectionKind.sleepCycleAlarm)
        .toList();
    final fifthCycle = events.firstWhere(
      (event) => event.details['cycleIndex'] == 5,
    );

    expect(alarms.map((event) => event.details['cycleIndex']), [6]);
    expect(fifthCycle.details['alarmDeferred'], isTrue);
    expect(fifthCycle.details['deferredToCycle'], 6);
    expect(fifthCycle.details['deepSleepCycle'], isTrue);
  });

  test('custom alarm cycle set only alerts on configured cycles', () {
    final events = _driveCycles(
      List<int>.filled(4, 90),
      seeds: const [90, 90, 90, 90],
      alarmCycles: const {2, 4},
    );
    final alarms = events
        .where((event) => event.kind == AcousticDetectionKind.sleepCycleAlarm)
        .toList();

    expect(alarms.map((event) => event.details['cycleIndex']), [2, 4]);
    expect(
      alarms.every((event) => event.details['alarmCycle'] == true),
      isTrue,
    );
  });

  test('disabled alarms still emit configured cycle boundaries', () {
    final events = _driveCycles(
      List<int>.filled(6, 90),
      seeds: const [90, 90, 90, 90, 90, 90],
      alarmsEnabled: false,
    );
    final fifthAndSixth = events.where((event) {
      final cycleIndex = event.details['cycleIndex'];
      return cycleIndex == 5 || cycleIndex == 6;
    }).toList();

    expect(
      events.where(
        (event) => event.kind == AcousticDetectionKind.sleepCycleAlarm,
      ),
      isEmpty,
    );
    expect(fifthAndSixth.map((event) => event.kind), [
      AcousticDetectionKind.sleepCycle,
      AcousticDetectionKind.sleepCycle,
    ]);
    expect(
      fifthAndSixth.every((event) => event.details['alarmCycle'] == false),
      isTrue,
    );
  });

  test('capture session id is attached to onset, cycle, and alarm events', () {
    final events = _driveCycles(
      List<int>.filled(5, 90),
      seeds: const [90, 90, 90, 90, 90],
      captureSessionId: 'night-session-42',
    );

    expect(events, isNotEmpty);
    expect(
      events.every((event) => event.captureSessionId == 'night-session-42'),
      isTrue,
    );
    expect(
      events.map((event) => event.details['cycleIndex']),
      containsAll(<int>[0, 1, 5]),
    );
    expect(
      events.any(
        (event) => event.kind == AcousticDetectionKind.sleepCycleAlarm,
      ),
      isTrue,
    );
  });
}
