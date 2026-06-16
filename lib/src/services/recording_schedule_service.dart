// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/services.dart';

import '../models/app_config.dart';
import 'diagnostic_log.dart';

class RecordingScheduleService {
  RecordingScheduleService({
    MethodChannel? channel,
    DateTime Function()? now,
    DiagnosticLog? diagnostics,
  }) : _channel =
           channel ?? const MethodChannel('audio_dashcam/recording_schedule'),
       _now = now ?? DateTime.now,
       _diagnostics = diagnostics {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;
  final DateTime Function() _now;
  final DiagnosticLog? _diagnostics;

  WeeklyRecordingSchedule _schedule = const WeeklyRecordingSchedule();
  Future<void> Function()? _onStart;
  Future<void> Function()? _onStop;
  bool Function()? _isRecording;
  Timer? _barrierTimer;
  bool _isEvaluating = false;

  Future<void> configure({
    required WeeklyRecordingSchedule schedule,
    required Future<void> Function() onStart,
    required Future<void> Function() onStop,
    required bool Function() isRecording,
  }) async {
    _schedule = schedule;
    _onStart = onStart;
    _onStop = onStop;
    _isRecording = isRecording;
    await _syncNativeSchedule();
    await evaluateNow();
  }

  Future<void> evaluateNow() async {
    if (_isEvaluating) {
      return;
    }
    _isEvaluating = true;
    try {
      _barrierTimer?.cancel();
      if (!_schedule.hasAnyWindows) {
        return;
      }
      final now = _now();
      final shouldRecord = _schedule.isActiveAt(now);
      final isRecording = _isRecording?.call() ?? false;
      if (shouldRecord && !isRecording) {
        _diagnostics?.add('Recording schedule entered an allowed window.');
        await _onStart?.call();
      } else if (!shouldRecord && isRecording) {
        _diagnostics?.add('Recording schedule left an allowed window.');
        await _onStop?.call();
      }
      _armNextBarrier(now);
    } finally {
      _isEvaluating = false;
    }
  }

  Future<void> clear() async {
    _schedule = const WeeklyRecordingSchedule();
    _barrierTimer?.cancel();
    _barrierTimer = null;
    try {
      await _channel.invokeMethod<void>('clearSchedule');
    } on MissingPluginException {
      _diagnostics?.add('Native recording schedule bridge is unavailable.');
    } on PlatformException catch (error) {
      _diagnostics?.add('Native recording schedule clear failed: $error');
    }
  }

  void dispose() {
    _barrierTimer?.cancel();
    _channel.setMethodCallHandler(null);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'barrier':
        _diagnostics?.add('Recording schedule barrier received from OS.');
        await evaluateNow();
        return true;
      default:
        throw PlatformException(
          code: 'not_implemented',
          message: 'Unknown recording schedule call ${call.method}.',
        );
    }
  }

  Future<void> _syncNativeSchedule() async {
    try {
      if (!_schedule.hasAnyWindows) {
        await _channel.invokeMethod<void>('clearSchedule');
        return;
      }
      final now = _now();
      final barrier = _schedule.nextBarrierAfter(now);
      await _channel.invokeMethod<void>('replaceSchedule', {
        'schedule': _schedule.toJson(),
        'nextBarrierAt': barrier?.toIso8601String(),
        'nextBarrierEpochMillis': barrier?.millisecondsSinceEpoch,
      });
    } on MissingPluginException {
      _diagnostics?.add('Native recording schedule bridge is unavailable.');
    } on PlatformException catch (error) {
      _diagnostics?.add('Native recording schedule sync failed: $error');
    }
  }

  void _armNextBarrier(DateTime now) {
    final barrier = _schedule.nextBarrierAfter(now);
    if (barrier == null) {
      return;
    }
    final delay = barrier.difference(now);
    _diagnostics?.add(
      'Next recording schedule barrier at ${barrier.toIso8601String()}.',
    );
    _barrierTimer = Timer(delay, () => unawaited(evaluateNow()));
  }
}
