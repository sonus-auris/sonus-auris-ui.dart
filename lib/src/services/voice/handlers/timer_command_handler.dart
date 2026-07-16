// ignore_for_file: prefer_initializing_formals

// Voice handler that runs real timers / focus sessions started by voice.
import 'dart:async';

import '../../../models/voice_command.dart';
import '../voice_command_handler.dart';
import '../voice_limits.dart';

/// A timer started by voice. Exposed so the UI can render a countdown and so
/// callers can cancel.
class VoiceTimer {
  // Keep the public named parameter `timer`; an initializing formal would expose
  // the private field name as API.
  VoiceTimer({
    required this.id,
    required this.duration,
    required this.startedAt,
    required Timer timer,
  }) : _timer = timer;

  final String id;
  final Duration duration;
  final DateTime startedAt;
  final Timer _timer;

  DateTime get firesAt => startedAt.add(duration);
  Duration get remaining {
    final left = firesAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void cancel() => _timer.cancel();
}

/// Fully-wired handler for [VoiceIntent.setTimer] and
/// [VoiceIntent.startFocusSession].
///
/// Schedules a real [Timer] from the `durationSeconds` slot and invokes
/// [onElapsed] when it fires. The focus-session intent is the same machinery
/// with a 25-minute default. Self-contained: no platform plugins required, so
/// it runs in tests and on every platform.
class TimerCommandHandler implements VoiceCommandHandler {
  TimerCommandHandler({required this.onElapsed});

  /// Called when a timer completes. Wire this to a notification / TTS chime.
  final void Function(VoiceTimer timer) onElapsed;

  final Map<String, VoiceTimer> _active = {};
  int _seq = 0;

  /// Currently-running timers, newest first.
  List<VoiceTimer> get activeTimers => _active.values.toList(growable: false);

  @override
  Set<VoiceIntent> get intents => {
    VoiceIntent.setTimer,
    VoiceIntent.startFocusSession,
  };

  @override
  Future<VoiceCommandResult> handle(VoiceCommand command) async {
    final raw = command.slot('durationSeconds');
    final seconds = int.tryParse(raw ?? '');
    // Reject non-positive (incl. values that overflowed to negative upstream).
    if (seconds == null || seconds <= 0) {
      return VoiceCommandResult.failure(
        command,
        'I need a duration, like "set a timer for 10 minutes".',
      );
    }
    if (seconds > VoiceLimits.maxTimerSeconds) {
      return VoiceCommandResult.failure(
        command,
        "That's longer than I can set a timer for.",
      );
    }
    if (_active.length >= VoiceLimits.maxActiveTimers) {
      return VoiceCommandResult.failure(
        command,
        'You already have too many timers running.',
      );
    }

    final id = 't${_seq++}';
    final duration = Duration(seconds: seconds);
    late final VoiceTimer voiceTimer;
    final timer = Timer(duration, () {
      _active.remove(id);
      onElapsed(voiceTimer);
    });
    voiceTimer = VoiceTimer(
      id: id,
      duration: duration,
      startedAt: DateTime.now(),
      timer: timer,
    );
    _active[id] = voiceTimer;

    final label = command.intent == VoiceIntent.startFocusSession
        ? 'focus session'
        : 'timer';
    return VoiceCommandResult.ok(
      command,
      '$label set for ${_humanDuration(duration)}.',
      data: {'timerId': id, 'durationSeconds': seconds},
    );
  }

  /// Cancels a running timer by id. Returns true if one was cancelled.
  bool cancel(String id) {
    final t = _active.remove(id);
    t?.cancel();
    return t != null;
  }

  void dispose() {
    for (final t in _active.values) {
      t.cancel();
    }
    _active.clear();
  }

  static String _humanDuration(Duration d) {
    final parts = <String>[];
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) parts.add('$h hour${h == 1 ? '' : 's'}');
    if (m > 0) parts.add('$m minute${m == 1 ? '' : 's'}');
    if (s > 0 && h == 0) parts.add('$s second${s == 1 ? '' : 's'}');
    return parts.isEmpty ? '0 seconds' : parts.join(' and ');
  }
}
