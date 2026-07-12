// Voice handler that starts/stops recording through a thin RecorderControl seam over AppController.
import '../../../models/voice_command.dart';
import '../voice_command_handler.dart';

/// Minimal control surface this handler needs from the recording engine.
/// [AppController] already exposes `startRecording`, `stopRecording`, and a
/// recording flag — wire those in at construction so the handler stays
/// decoupled from the controller and trivially testable with a fake.
class RecorderControl {
  const RecorderControl({
    required this.start,
    required this.stop,
    required this.isRecording,
  });

  final Future<void> Function() start;
  final Future<void> Function() stop;
  final bool Function() isRecording;
}

/// Fully-wired handler for [VoiceIntent.startRecording] /
/// [VoiceIntent.stopRecording].
///
/// This is the highest-value, genuinely hands-free command for an audio
/// dashcam: "start recording" / "stop recording" with no screen. It's
/// idempotent — asking to start while already recording (or stop while idle)
/// confirms the state rather than erroring.
class RecordingCommandHandler implements VoiceCommandHandler {
  RecordingCommandHandler({required this.control});

  final RecorderControl control;

  @override
  Set<VoiceIntent> get intents =>
      {VoiceIntent.startRecording, VoiceIntent.stopRecording};

  @override
  Future<VoiceCommandResult> handle(VoiceCommand command) async {
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
        wantStart ? "I couldn't start recording." : "I couldn't stop recording.",
      );
    }

    return VoiceCommandResult.ok(
      command,
      wantStart ? 'Recording started.' : 'Recording stopped.',
      data: {'recording': control.isRecording()},
    );
  }
}
