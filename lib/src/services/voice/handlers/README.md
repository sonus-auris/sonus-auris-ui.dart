# lib/src/services/voice/handlers

Concrete `VoiceCommandHandler` implementations — the *execution* half of the
voice pipeline (see [../README.md](../README.md) for the full picture). The
dispatcher routes a resolved intent to one of these; swapping the recognizer
never touches them.

- **[timer_command_handler.dart](timer_command_handler.dart)** — real timers /
  focus sessions (`setTimer`, `startFocusSession`).
- **[note_command_handler.dart](note_command_handler.dart)** — persists notes /
  tasks / voice memos via a `NoteSink` (`takeNote`, `createTask`, `recordVoiceMemo`).
- **[recording_command_handler.dart](recording_command_handler.dart)** — starts/
  stops capture through a thin `RecorderControl` seam over `AppController`.
- **[stub_command_handler.dart](stub_command_handler.dart)** — fallback for
  intents recognized but not yet wired, so the command surface stays complete.
