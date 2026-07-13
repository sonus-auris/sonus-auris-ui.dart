// Voice handler that persists notes/tasks/voice-memos via a NoteSink.
import '../../../models/voice_command.dart';
import '../voice_command_handler.dart';
import '../voice_limits.dart';

/// A captured note / task created by voice.
class VoiceNote {
  const VoiceNote({
    required this.id,
    required this.text,
    required this.createdAtUtc,
    required this.isTask,
  });

  final String id;
  final String text;
  final DateTime createdAtUtc;

  /// Distinguishes "create a task" from "take a note" so the UI / sync layer
  /// can file them differently while sharing one capture path.
  final bool isTask;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'isTask': isTask,
  };
}

/// Where captured notes go. Kept as a narrow interface so the handler doesn't
/// care whether notes are held in memory, written to local storage, or pushed
/// to Supabase. Production dispatchers must explicitly supply their persistent
/// implementation.
abstract class NoteSink {
  Future<void> save(VoiceNote note);
}

/// Test/demo sink. Production dispatchers do not select it by default.
class InMemoryNoteSink implements NoteSink {
  final List<VoiceNote> _notes = [];

  List<VoiceNote> get notes => List.unmodifiable(_notes);

  @override
  Future<void> save(VoiceNote note) async {
    _notes.insert(0, note);
  }
}

/// Fully-wired handler for [VoiceIntent.takeNote], [VoiceIntent.createTask], and
/// [VoiceIntent.recordVoiceMemo].
///
/// Pulls the `text` slot, persists it through the injected [NoteSink], and
/// confirms verbally. An empty body (e.g. bare "take a note") is rejected with
/// a spoken prompt rather than saving a blank entry.
class NoteCommandHandler implements VoiceCommandHandler {
  NoteCommandHandler({required this.sink});

  final NoteSink sink;
  int _seq = 0;

  @override
  Set<VoiceIntent> get intents => {
    VoiceIntent.takeNote,
    VoiceIntent.createTask,
    VoiceIntent.recordVoiceMemo,
  };

  @override
  Future<VoiceCommandResult> handle(VoiceCommand command) async {
    final text = VoiceLimits.clip(
      command.slot('text'),
      VoiceLimits.maxNoteChars,
    ).trim();
    if (text.isEmpty) {
      return VoiceCommandResult.failure(command, 'What should the note say?');
    }

    final isTask = command.intent == VoiceIntent.createTask;
    final note = VoiceNote(
      id: 'n${_seq++}',
      text: text,
      createdAtUtc: DateTime.now().toUtc(),
      isTask: isTask,
    );

    try {
      await sink.save(note);
    } catch (_) {
      return VoiceCommandResult.failure(command, "I couldn't save that note.");
    }

    final kind = isTask ? 'Task' : 'Note';
    return VoiceCommandResult.ok(
      command,
      '$kind saved.',
      data: {'noteId': note.id},
    );
  }
}
