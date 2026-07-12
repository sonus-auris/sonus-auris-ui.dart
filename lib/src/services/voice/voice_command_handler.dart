// VoiceCommandHandler interface plus the VoiceCommandResult returned when executing a command.
import '../../models/voice_command.dart';

/// Result of attempting to execute a [VoiceCommand].
///
/// [spokenResponse] is the short phrase the dispatcher hands to TTS so the user
/// gets hands-free confirmation. [handled] distinguishes "I ran this" from
/// "I recognized it but the capability isn't wired yet" (a stub), which the UI
/// can surface differently from an outright parse failure.
class VoiceCommandResult {
  const VoiceCommandResult({
    required this.command,
    required this.handled,
    required this.success,
    required this.spokenResponse,
    this.data = const {},
  });

  /// A successfully executed command.
  factory VoiceCommandResult.ok(
    VoiceCommand command,
    String spokenResponse, {
    Map<String, Object?> data = const {},
  }) =>
      VoiceCommandResult(
        command: command,
        handled: true,
        success: true,
        spokenResponse: spokenResponse,
        data: data,
      );

  /// Recognized, but the handler is still scaffolding. Counts as handled
  /// (we routed it) but not successful (nothing happened).
  factory VoiceCommandResult.notImplemented(VoiceCommand command) =>
      VoiceCommandResult(
        command: command,
        handled: true,
        success: false,
        spokenResponse: "I can't do that yet, but I understood you.",
      );

  /// Handler ran but failed (bad slot, downstream error).
  factory VoiceCommandResult.failure(
    VoiceCommand command,
    String spokenResponse,
  ) =>
      VoiceCommandResult(
        command: command,
        handled: true,
        success: false,
        spokenResponse: spokenResponse,
      );

  /// Nothing matched the transcript.
  factory VoiceCommandResult.unrecognized(VoiceCommand command) =>
      VoiceCommandResult(
        command: command,
        handled: false,
        success: false,
        spokenResponse: "Sorry, I didn't catch that.",
      );

  final VoiceCommand command;
  final bool handled;
  final bool success;
  final String spokenResponse;
  final Map<String, Object?> data;
}

/// A unit of voice-command execution. Each handler declares which [intents] it
/// services; the dispatcher builds an intent→handler map from these.
///
/// Handlers must never throw — return [VoiceCommandResult.failure] instead — so
/// a bad command can't crash the speech pipeline.
abstract class VoiceCommandHandler {
  Set<VoiceIntent> get intents;

  Future<VoiceCommandResult> handle(VoiceCommand command);
}
