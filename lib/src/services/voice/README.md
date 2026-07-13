# Voice commands

Hands-free commands on top of the always-on audio pipeline. The app is already
continuously capturing a rolling buffer and already has on-device STT, so it's a
natural host for voice commands — we listen for a wake word in the buffer,
transcribe the utterance, map it to a function, and run it.

## Pipeline

```
mic / rolling buffer ──► STT (text) ──► IntentResolver ──► VoiceCommand ──► Dispatcher ──► Handler ──► spoken confirmation (TTS)
   (always-on)         on-device or       text → intent      intent + slots    routes by intent   executes      RecordingFeedback.say
                         Vapi                + params
```

Two concerns are kept separate so each can be upgraded independently:

- **Recognition** — `IntentResolver` ([intent_resolver.dart](intent_resolver.dart)):
  text → `VoiceCommand` (intent + typed slots). Strategies:
  - `RuleBasedIntentResolver` — on-device regex parser
    ([voice_command_parser.dart](voice_command_parser.dart)). Zero latency,
    offline, no LLM. Ships today; good as the offline fallback.
  - `LlmIntentResolver` — POSTs the transcript to a server that runs an LLM /
    embedding classifier with **function-calling** and returns the chosen
    function + filled params. This is the reliable, fuzzy-language path.
  - `FallbackIntentResolver` — LLM first, rules on timeout/offline.
- **Execution** — `VoiceCommandHandler` + `VoiceCommandDispatcher`
  ([voice_command_dispatcher.dart](voice_command_dispatcher.dart)). The
  dispatcher owns an intent→handler registry and never changes when the resolver
  is swapped.

## What's wired today

The dispatcher registers only real executors. Unsupported intents remain
recognized, but return `handled: false`; recognition is never presented as a
completed side effect. Application/platform integrations can be added through
`additionalHandlers` (or `CallbackCommandHandler` for direct callbacks):

| Intent | Handler | Behavior |
| --- | --- | --- |
| `setTimer`, `startFocusSession` | `TimerCommandHandler` | real `Timer`, fires `onElapsed` |
| `takeNote`, `createTask`, `recordVoiceMemo` | `NoteCommandHandler` | persists via the explicitly supplied `NoteSink` |
| `startRecording`, `stopRecording` | `RecordingCommandHandler` | drives the explicitly supplied recorder controller |

Tests: [voice_command_parser_test.dart](../../../../test/voice_command_parser_test.dart),
[voice_command_dispatcher_test.dart](../../../../test/voice_command_dispatcher_test.dart).

## Vapi integration (the production recognition + async path)

We already run a Rust Vapi service in the cluster
(`k8s-cluster/remote/deployments/rust-vapi-phone-rs`) that does exactly the hard
part: **reliable STT → LLM → function-call-with-params**. Its phone assistant is
configured with `function` tools (name + JSON-schema `parameters`); the model
emits a `tool-call` with filled arguments that the server executes. Our
`VoiceIntent` + slots map 1:1 onto that shape — `LlmIntentResolver.toolSchemas()`
already emits the wired intents in tool-schema form.

Two ways to plug in:

1. **Client-side Vapi SDK (ideal for live, low-latency commands).** Vapi ships
   an official Flutter SDK (`vapi` on pub.dev, web/iOS/Android). Embed it for a
   real-time voice session, register our intents as tools, and translate Vapi
   `onMessage` tool-calls into `VoiceCommand`s handed to
   `dispatcher.dispatchCommand(...)`. Best for interactive, in-the-moment
   commands ("set a timer", "stop recording").

2. **Server-side, for long-running / persistent / future / async jobs.** The
   Vapi service runs continuously on k8s with RDS Postgres + Redis (and an
   `AGENT_TASKS` DB context) — the right home for anything that outlives the app
   session: scheduled reminders, future calendar events, outbound calls
   ("remind me to call John tomorrow at 9am" → a persisted job that later places
   a Vapi outbound call or push), and batch work like "summarize my unread
   messages." The client recognizes the intent, then hands it to the server to
   own the durable timer/queue; the phone doesn't have to be awake when it
   fires. `LlmIntentResolver`'s endpoint is the natural front door for this.

So: client SDK for immediate commands, the cluster service for durable/deferred
ones — same intent/tool vocabulary across both.
