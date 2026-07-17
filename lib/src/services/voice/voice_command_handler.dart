// VoiceCommandHandler interface plus the VoiceCommandResult returned when executing a command.
import '../../models/voice_command.dart';

/// Result of attempting to execute a [VoiceCommand].
///
/// [spokenResponse] is the short phrase the dispatcher hands to TTS so the user
/// gets hands-free confirmation. [handled] distinguishes a command that reached
/// a real executor from one that was recognized but is unavailable.
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
  }) => VoiceCommandResult(
    command: command,
    handled: true,
    success: true,
    spokenResponse: spokenResponse,
    data: data,
  );

  /// Recognized, but no real executor was registered. This is deliberately not
  /// marked handled: callers must never mistake recognition for side effects.
  factory VoiceCommandResult.notImplemented(VoiceCommand command) =>
      VoiceCommandResult(
        command: command,
        handled: false,
        success: false,
        spokenResponse: "I can't do that yet, but I understood you.",
      );

  /// Handler ran but failed (bad slot, downstream error).
  factory VoiceCommandResult.failure(
    VoiceCommand command,
    String spokenResponse,
  ) => VoiceCommandResult(
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

  /// The command was understood but is missing a required [slot]; the spoken
  /// response asks for it and the dispatcher treats the user's next utterance
  /// as the answer. Not marked handled — nothing has executed yet.
  factory VoiceCommandResult.needsFollowUp(
    VoiceCommand command,
    String spokenResponse, {
    required String slot,
  }) => VoiceCommandResult(
    command: command,
    handled: false,
    success: false,
    spokenResponse: spokenResponse,
    data: {followUpSlotKey: slot},
  );

  /// Data key naming the slot a [needsFollowUp] result is waiting on.
  static const String followUpSlotKey = 'followUpSlot';

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

/// Adapts one or more real application/platform callbacks to the handler
/// registry without requiring every integration to define a wrapper class.
class CallbackCommandHandler implements VoiceCommandHandler {
  CallbackCommandHandler(Map<VoiceIntent, VoiceCommandExecutor> executors)
    : _executors = Map.unmodifiable(executors) {
    if (_executors.isEmpty || _executors.containsKey(VoiceIntent.unknown)) {
      throw ArgumentError('Provide at least one recognized intent executor.');
    }
  }

  final Map<VoiceIntent, VoiceCommandExecutor> _executors;

  @override
  Set<VoiceIntent> get intents => Set.unmodifiable(_executors.keys);

  @override
  Future<VoiceCommandResult> handle(VoiceCommand command) async {
    final executor = _executors[command.intent];
    if (executor == null) {
      return VoiceCommandResult.notImplemented(command);
    }
    try {
      return await executor(command);
    } catch (_) {
      return VoiceCommandResult.failure(
        command,
        'Something went wrong running that command.',
      );
    }
  }
}

typedef VoiceCommandExecutor =
    Future<VoiceCommandResult> Function(VoiceCommand command);
