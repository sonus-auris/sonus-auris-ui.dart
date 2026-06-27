import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/acoustic_detection.dart';
import '../models/app_config.dart';
import '../models/sleep_cycle.dart';
import '../models/sleep_cycle_profile.dart';
import '../models/sleep_sensor_sample.dart';
import '../models/sleep_session.dart';
import '../models/sleep_stage.dart';
import 'diagnostic_log.dart';
import 'local_notifications_service.dart';
import 'sleep_alarm_planner.dart';
import 'sleep_cycle_profile_store.dart';
import 'sleep_probability_model.dart';
import 'sleep_sensor_source.dart';

/// Live, observable status of the current sleep session (for the UI).
@immutable
class SleepSessionStatus {
  const SleepSessionStatus({
    this.active = false,
    this.startedAtUtc,
    this.stage = SleepStage.unknown,
    this.depth = 0,
    this.sleepProbability = 0,
    this.cyclesCompleted = 0,
    this.dominantCycleMinutes = 0,
    this.targetTimeUtc,
    this.backstopTimeUtc,
    this.alarmFired = false,
    this.depthEnvelope = const [],
  });

  final bool active;
  final DateTime? startedAtUtc;
  final SleepStage stage;
  final double depth;
  final double sleepProbability;
  final int cyclesCompleted;

  /// Latest FFT-estimated cycle length for the night (minutes).
  final double dominantCycleMinutes;

  final DateTime? targetTimeUtc;
  final DateTime? backstopTimeUtc;
  final bool alarmFired;

  /// Coarse depth samples so far tonight (one per ~5 min), for a live hypnogram.
  final List<double> depthEnvelope;
}

/// Orchestrates a sleep session on the main isolate.
///
/// It consumes the acoustic sleep epochs/cycles produced by the in-isolate
/// [SleepCycleDetector], fuses them with the consent-gated motion/light sensors
/// and lightweight context via [SleepProbabilityModel], detects/learns cycle
/// length over the last 35 nights via [SleepCycleProfileStore], and arms the
/// cycle-aware alarms via [SleepAlarmPlanner] + [LocalNotificationsService].
///
/// Lifecycle: [start] (after the recorder is in sleep mode) → feed detections
/// with [onAcousticDetection] → [stop] on wake. Recorder start/stop is owned by
/// the controller.
class SleepSessionService {
  SleepSessionService({
    required LocalNotificationsService notifications,
    required SleepCycleProfileStore profileStore,
    required SleepSensorSource sensorSource,
    SleepProbabilityModel fusionModel = const SleepProbabilityModel(),
    SleepAlarmPlanner planner = const SleepAlarmPlanner(),
    SleepFusionContext Function()? contextProvider,
    DiagnosticLog? diagnostics,
    Uuid? uuid,
  })  : _notifications = notifications,
        _profileStore = profileStore,
        _sensors = sensorSource,
        _fusion = fusionModel,
        _planner = planner,
        contextProviderOverride = contextProvider,
        _diagnostics = diagnostics,
        _uuid = uuid ?? const Uuid();

  final LocalNotificationsService _notifications;
  final SleepCycleProfileStore _profileStore;
  final SleepSensorSource _sensors;
  final SleepProbabilityModel _fusion;
  final SleepAlarmPlanner _planner;

  /// Supplies non-acoustic context (charging, usual-bedtime, phone use) each
  /// epoch. Settable so the owning controller can wire it after construction.
  SleepFusionContext Function()? contextProviderOverride;
  final DiagnosticLog? _diagnostics;
  final Uuid _uuid;

  final ValueNotifier<SleepSessionStatus> status =
      ValueNotifier(const SleepSessionStatus());

  // Per-session state.
  String? _sessionId;
  AppConfig? _config;
  SleepCycleProfile _profile = const SleepCycleProfile.initial();
  DateTime? _sessionStartUtc;
  DateTime? _onsetUtc; // anchored at first detected cycle start
  SleepAlarmPlan? _plan;
  bool _alarmFired = false;

  final List<SleepCycle> _cycles = [];
  final List<double> _measuredLengths = [];
  final List<double> _depthEnvelope = []; // downsampled (every Nth epoch)
  int _epochCounter = 0;
  double _dominantCycleMinutes = 0;
  static const int _envelopeEveryEpochs = 10; // ~5 min at 30 s epochs

  // Rolling sensor buffer since the last acoustic epoch. Bounded so a stall in
  // the acoustic epoch stream (which drains it) can't grow memory unbounded over
  // a whole night — we keep only the most recent samples.
  final List<SleepSensorSample> _sensorBuffer = [];
  static const int _maxSensorBuffer = 1200; // ~20 min at ~1 Hz
  StreamSubscription<SleepSensorSample>? _sensorSub;

  bool get isActive => _sessionId != null;

  /// Number of sensor samples buffered but not yet folded into an epoch. Exposed
  /// for tests to assert the buffer stays bounded.
  @visibleForTesting
  int get pendingSensorSampleCount => _sensorBuffer.length;

  /// Begin a session. Loads the learned profile, schedules the backstop alarm,
  /// and starts the consented sensors. [config] supplies alarm prefs + consent.
  Future<void> start(AppConfig config, {DateTime? now}) async {
    if (isActive) {
      return;
    }
    final startedAt = (now ?? DateTime.now()).toUtc();
    _config = config;
    _sessionId = _uuid.v4();
    _sessionStartUtc = startedAt;
    _onsetUtc = null;
    _alarmFired = false;
    _cycles.clear();
    _measuredLengths.clear();
    _depthEnvelope.clear();
    _epochCounter = 0;
    _dominantCycleMinutes = 0;
    _sensorBuffer.clear();

    _profile = await _profileStore.loadProfile(
      defaultCycleMinutes: config.sleepDefaultCycleMinutes,
    );

    // Provisional plan anchored at session start until sleep onset is detected.
    _replan(startedAt);

    // OS-level backstop so the sleeper still wakes even if the app is killed.
    final plan = _plan;
    if (plan != null && config.sleepSmartAlarmEnabled) {
      await _notifications.scheduleSleepBackstop(plan.backstopTimeUtc);
    }

    // Start consented sensors.
    final consent = SleepSensorConsent(
      motion: config.sleepMotionConsent,
      light: config.sleepLightConsent,
    );
    if (consent.any) {
      try {
        await _sensors.start(consent);
        _sensorSub = _sensors.samples.listen(_addSensorSample);
      } catch (e) {
        _diagnostics?.add('Sleep sensors unavailable: $e');
      }
    }

    _emitStatus();
    _diagnostics?.add(
      'Sleep session started (profile: '
      '${_profile.overallMeanMinutes.toStringAsFixed(0)} min/cycle, '
      '${_profile.sampleNights} nights).',
    );
  }

  /// Route an acoustic detection here (the controller forwards sleep kinds).
  Future<void> onAcousticDetection(AcousticDetection detection) async {
    if (!isActive) {
      return;
    }
    switch (detection.kind) {
      case AcousticDetectionKind.sleepEpoch:
        await _onEpoch(detection);
        break;
      case AcousticDetectionKind.sleepCycle:
        _onCycle(detection);
        break;
      default:
        break;
    }
  }

  Future<void> _onEpoch(AcousticDetection d) async {
    final config = _config;
    if (config == null) {
      return;
    }
    final acousticDepth = _num(d.details['depth']);
    final acousticStage = SleepStage.fromName(d.details['stage'] as String?);
    final breathingRegularity = _num(d.details['breathingRegularity']);
    final snoreFraction = _num(d.details['snoreFraction']);

    // Aggregate sensors collected since the previous epoch, then fuse.
    final sensorEpoch = _drainSensorBuffer();
    final estimate = _fusion.fuse(
      acousticDepth: acousticDepth,
      acousticStage: acousticStage,
      breathingRegularity: breathingRegularity,
      snoreFraction: snoreFraction,
      sensors: sensorEpoch,
      context: contextProviderOverride?.call() ?? const SleepFusionContext(),
    );

    _epochCounter += 1;
    if (_epochCounter % _envelopeEveryEpochs == 1 || _depthEnvelope.isEmpty) {
      _depthEnvelope.add(estimate.fusedDepth);
    }

    final nowUtc = d.endedAtUtc;
    // Evaluate the alarm against the *fused* stage (motion/light improve the
    // light-vs-deep call that gates the smart wake).
    await _evaluateAlarm(nowUtc, estimate.fusedStage);

    _emitStatus(
      stage: estimate.fusedStage,
      depth: estimate.fusedDepth,
      sleepProbability: estimate.sleepProbability,
    );
  }

  void _emitStatus({
    SleepStage stage = SleepStage.unknown,
    double depth = 0,
    double sleepProbability = 0,
  }) {
    status.value = SleepSessionStatus(
      active: true,
      startedAtUtc: _sessionStartUtc,
      stage: stage,
      depth: depth,
      sleepProbability: sleepProbability,
      cyclesCompleted: _cycles.length,
      dominantCycleMinutes: _dominantCycleMinutes,
      targetTimeUtc: _plan?.targetTimeUtc,
      backstopTimeUtc: _plan?.backstopTimeUtc,
      alarmFired: _alarmFired,
      depthEnvelope: List.of(_depthEnvelope),
    );
  }

  /// Past nights, newest first, for the history view.
  Future<List<SleepSession>> loadHistory() async {
    final sessions = await _profileStore.loadSessions();
    sessions.sort((a, b) => b.startedAtUtc.compareTo(a.startedAtUtc));
    return sessions;
  }

  void _onCycle(AcousticDetection d) {
    final index = (d.details['cycleIndex'] as num?)?.toInt() ?? _cycles.length + 1;
    final length = _num(d.details['lengthMinutes']);
    _dominantCycleMinutes = _num(d.details['dominantCycleMinutes']);
    _cycles.add(SleepCycle(
      index: index,
      startedAtUtc: d.startedAtUtc,
      endedAtUtc: d.endedAtUtc,
      minDepth: _num(d.details['minDepth']),
      maxDepth: _num(d.details['maxDepth']),
    ));
    if (length > 0) {
      _measuredLengths.add(length);
    }
    // Anchor onset at the first cycle's start and re-plan with measured lengths.
    _onsetUtc ??= _cycles.first.startedAtUtc;
    _replan(_onsetUtc!);
    _diagnostics?.add(
      'Sleep cycle $index complete (${length.toStringAsFixed(0)} min); '
      'next target ${_plan?.targetTimeUtc.toLocal()}.',
    );
  }

  Future<void> _evaluateAlarm(DateTime nowUtc, SleepStage stage) async {
    final config = _config;
    final plan = _plan;
    if (config == null || plan == null || _alarmFired) {
      return;
    }
    final decision = _planner.evaluate(
      plan: plan,
      nowUtc: nowUtc,
      smartAlarmEnabled: config.sleepSmartAlarmEnabled,
      stage: stage,
      cyclesCompleted: _cycles.length,
      targetCycle: config.sleepTargetCycle,
      backstopCycle: config.sleepBackstopCycle,
    );
    if (decision == SleepAlarmDecision.hold) {
      return;
    }
    final backstop = decision == SleepAlarmDecision.backstopWake;
    _alarmFired = true;
    // The smart wake fired before the backstop deadline: cancel the scheduled OS
    // backstop so a second alarm doesn't also go off later at ~9 h.
    if (!backstop) {
      await _notifications.cancelSleepBackstop();
    }
    await _notifications.fireSleepAlarm(backstop: backstop);
    _diagnostics?.add(
      backstop
          ? 'Sleep backstop alarm fired at ${nowUtc.toLocal()}.'
          : 'Smart wake fired at ${nowUtc.toLocal()} (stage ${stage.label}).',
    );
  }

  void _replan(DateTime onsetUtc) {
    final config = _config;
    if (config == null) {
      return;
    }
    _plan = _planner.plan(
      onsetUtc: onsetUtc,
      measuredCycleMinutes: _measuredLengths,
      profile: _profile,
      targetCycle: config.sleepTargetCycle,
      backstopCycle: config.sleepBackstopCycle,
      smartWindowMinutes: config.sleepSmartWindowMinutes,
    );
  }

  void _addSensorSample(SleepSensorSample sample) {
    _sensorBuffer.add(sample);
    if (_sensorBuffer.length > _maxSensorBuffer) {
      // Drop the oldest overflow in one shot (cheap, keeps the recent window).
      _sensorBuffer.removeRange(0, _sensorBuffer.length - _maxSensorBuffer);
    }
  }

  SleepSensorEpoch _drainSensorBuffer() {
    if (_sensorBuffer.isEmpty) {
      return const SleepSensorEpoch.empty();
    }
    var motionSamples = 0;
    var movementSum = 0.0;
    var luxSum = 0.0;
    var luxSamples = 0;
    for (final s in _sensorBuffer) {
      if (s.accelMagnitude != null) {
        motionSamples += 1;
        // Map magnitude (m/s²) to 0..1; ~1.5 m/s² counts as full movement.
        movementSum += (s.accelMagnitude! / 1.5).clamp(0.0, 1.0);
      }
      if (s.lux != null) {
        luxSamples += 1;
        luxSum += s.lux!;
      }
    }
    final epoch = SleepSensorEpoch(
      movement: motionSamples > 0 ? movementSum / motionSamples : 0.0,
      meanLux: luxSamples > 0 ? luxSum / luxSamples : null,
      hasMotion: motionSamples > 0,
      hasLight: luxSamples > 0,
      sampleCount: _sensorBuffer.length,
    );
    _sensorBuffer.clear();
    return epoch;
  }

  /// End the session: persist the night's summary (35-day retention → learning),
  /// stop sensors and cancel pending alarms.
  Future<SleepSession?> stop({DateTime? now}) async {
    if (!isActive) {
      return null;
    }
    final endedAt = (now ?? DateTime.now()).toUtc();
    final session = SleepSession(
      id: _sessionId!,
      startedAtUtc: _onsetUtc ?? _sessionStartUtc ?? endedAt,
      endedAtUtc: endedAt,
      cycles: List.of(_cycles),
      dominantCycleMinutes: _dominantCycleMinutes,
      depthEnvelope: List.of(_depthEnvelope),
    );

    await _sensorSub?.cancel();
    _sensorSub = null;
    await _sensors.stop();
    // Cancel the scheduled backstop and clear any alarm notification. If the user
    // reached here by tapping a firing alarm, the tap already dismissed it.
    await _notifications.cancelSleepAlarms();

    try {
      if (session.cycles.isNotEmpty) {
        await _profileStore.saveSession(session);
      }
    } catch (e) {
      _diagnostics?.add('Failed to persist sleep session: $e');
    }

    _sessionId = null;
    _config = null;
    _sessionStartUtc = null;
    _onsetUtc = null;
    _plan = null;
    status.value = const SleepSessionStatus();
    _diagnostics?.add(
      'Sleep session ended: ${session.cycles.length} cycles, '
      '${session.totalMinutes.toStringAsFixed(0)} min.',
    );
    return session;
  }

  Future<void> dispose() async {
    await _sensorSub?.cancel();
    await _sensors.dispose();
    status.dispose();
  }

  static double _num(Object? v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;
}
