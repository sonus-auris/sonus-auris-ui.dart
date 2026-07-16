// Voice handler that starts/stops/pauses recording through a thin RecorderControl seam over AppController.
import '../../../models/voice_command.dart';
import '../voice_command_handler.dart';
import '../voice_limits.dart';

/// Minimal control surface this handler needs from the recording engine.
/// [AppController] already exposes `startRecording`, `stopRecording`, and a
/// recording flag — wire those in at construction so the handler stays
/// decoupled from the controller and trivially testable with a fake.
/// [pauseFor] and [isPaused] are optional: without them the pause intent is
/// recognized but reported as unavailable.
class RecorderControl {
  const RecorderControl({
    required this.start,
    required this.stop,
    required this.isRecording,
    this.pauseFor,
    this.isPaused,
  });

  final Future<void> Function() start;
  final Future<void> Function() stop;
  final bool Function() isRecording;

  /// Pause capture and auto-resume after the given duration.
  final Future<void> Function(Duration duration)? pauseFor;

  /// True while capture is paused awaiting an auto-resume.
  final bool Function()? isPaused;
}

/// Fully-wired handler for [VoiceIntent.startRecording] /
/// [VoiceIntent.stopRecording] / [VoiceIntent.confirmRecording] /
/// [VoiceIntent.pauseRecording].
///
/// These are the highest-value, genuinely hands-free commands for an audio
/// dashcam: transport control with no screen. All are idempotent — asking to
/// start while already recording (or stop while idle) confirms the state
/// rather than erroring. "Pause recording" without a duration answers with a
/// question and [VoiceCommandResult.needsFollowUp], so the dispatcher treats
/// the user's next utterance ("ten minutes") as the missing duration.
class RecordingCommandHandler implements VoiceCommandHandler {
  RecordingCommandHandler({required this.control});

  final RecorderControl control;

  @override
  Set<VoiceIntent> get intents => {
    VoiceIntent.startRecording,
    VoiceIntent.stopRecording,
    VoiceIntent.confirmRecording,
    VoiceIntent.pauseRecording,
  };

  @override
  Future<VoiceCommandResult> handle(VoiceCommand command) async {
    switch (command.intent) {
      case VoiceIntent.confirmRecording:
        return _confirm(command);
      case VoiceIntent.pauseRecording:
        return _pause(command);
      default:
        return _startOrStop(command);
    }
  }

  VoiceCommandResult _confirm(VoiceCommand command) {
    final paused = control.isPaused?.call() ?? false;
    final recording = control.isRecording();
    final String phrase;
    if (paused) {
      phrase =
          'Recording is paused and will resume automatically. '
          'Say "resume recording" to resume now.';
    } else if (recording) {
      phrase = 'Yes — Sonus Auris is recording.';
    } else {
      phrase = 'No — recording is stopped.';
    }
    return VoiceCommandResult.ok(
      command,
      phrase,
      data: {'recording': recording, 'paused': paused},
    );
  }

  Future<VoiceCommandResult> _pause(VoiceCommand command) async {
    final pauseFor = control.pauseFor;
    if (pauseFor == null) {
      return VoiceCommandResult.notImplemented(command);
    }
    if (!control.isRecording() && !(control.isPaused?.call() ?? false)) {
      return VoiceCommandResult.ok(
        command,
        'Recording is already stopped.',
        data: {'recording': false},
      );
    }
    final rawSeconds = int.tryParse(command.slot('durationSeconds') ?? '');
    if (rawSeconds == null || rawSeconds <= 0) {
      return VoiceCommandResult.needsFollowUp(
        command,
        'For how long should I pause recording?',
        slot: 'durationSeconds',
      );
    }
    final seconds = rawSeconds > VoiceLimits.maxTimerSeconds
        ? VoiceLimits.maxTimerSeconds
        : rawSeconds;
    try {
      await pauseFor(Duration(seconds: seconds));
    } catch (_) {
      return VoiceCommandResult.failure(command, "I couldn't pause recording.");
    }
    return VoiceCommandResult.ok(
      command,
      'Recording paused for ${describeSpokenDuration(seconds)}. '
      "I'll resume automatically.",
      data: {'recording': false, 'paused': true, 'pauseSeconds': seconds},
    );
  }

  Future<VoiceCommandResult> _startOrStop(VoiceCommand command) async {
    final wantStart = command.intent == VoiceIntent.startRecording;
    final alreadyInDesiredState = control.isRecording() == wantStart;
    if (alreadyInDesiredState) {
      return VoiceCommandResult.ok(
        command,
        wantStart ? 'Already recording.' : 'Recording is already stopped.',
        data: {'recording': control.isRecording()},
      );
    }

    try {
      if (wantStart) {
        await control.start();
      } else {
        await control.stop();
      }
    } catch (_) {
      return VoiceCommandResult.failure(
        command,
        wantStart
            ? "I couldn't start recording."
            : "I couldn't stop recording.",
      );
    }

    return VoiceCommandResult.ok(
      command,
      wantStart ? 'Recording started.' : 'Recording stopped.',
      data: {'recording': control.isRecording()},
    );
  }
}

/// "600" → "10 minutes"; keeps TTS confirmations natural.
String describeSpokenDuration(int seconds) {
  if (seconds % 3600 == 0) {
    final hours = seconds ~/ 3600;
    return hours == 1 ? '1 hour' : '$hours hours';
  }
  if (seconds % 60 == 0) {
    final minutes = seconds ~/ 60;
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }
  return seconds == 1 ? '1 second' : '$seconds seconds';
}
