// Fallback voice handler acknowledging recognized-but-unwired intents so the command surface stays complete.
import '../../../models/voice_command.dart';
import '../voice_command_handler.dart';

/// Scaffolding handler for intents that are recognized but not yet wired to a
/// real capability (reminders, navigation, smart-home, media, etc.).
///
/// It exists so the dispatcher has full intent coverage today: a user can speak
/// any supported phrase and get a coherent, spoken "understood, not yet
/// available" response with the parsed slots echoed in [VoiceCommandResult.data]
/// for debugging — instead of a generic "didn't catch that". Replace entries in
/// the dispatcher's registry with concrete handlers as they land.
class StubCommandHandler implements VoiceCommandHandler {
  StubCommandHandler(this.intents);

  @override
  final Set<VoiceIntent> intents;

  @override
  Future<VoiceCommandResult> handle(VoiceCommand command) async {
    return VoiceCommandResult(
      command: command,
      handled: true,
      success: false,
      spokenResponse: _phraseFor(command.intent),
      data: {'slots': command.slots, 'stub': true},
    );
  }

  String _phraseFor(VoiceIntent intent) {
    switch (intent.category) {
      case VoiceCommandCategory.communication:
        return 'Calling and messaging are coming soon.';
      case VoiceCommandCategory.navigation:
        return 'Navigation is coming soon.';
      case VoiceCommandCategory.smartHome:
        return 'Smart-home control is coming soon.';
      case VoiceCommandCategory.media:
        return 'Media control is coming soon.';
      case VoiceCommandCategory.information:
        return 'I will be able to answer that soon.';
      default:
        return "I understood you, but that's not available yet.";
    }
  }
}
