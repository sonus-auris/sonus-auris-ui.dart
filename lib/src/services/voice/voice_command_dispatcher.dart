// Routes a resolved VoiceCommand to its handler via an intent->handler registry and speaks the confirmation.
import 'package:rxdart/rxdart.dart';

import '../../models/voice_command.dart';
import 'handlers/note_command_handler.dart';
import 'handlers/recording_command_handler.dart';
import 'handlers/stub_command_handler.dart';
import 'handlers/timer_command_handler.dart';
import 'intent_resolver.dart';
import 'voice_command_handler.dart';
import 'voice_limits.dart';

/// Speaks short confirmation phrases back to the user. The app already has
/// `RecordingFeedback.say` (flutter_tts) — adapt it to this typedef when wiring
/// the dispatcher into [AppController].
typedef SpeakCallback = Future<void> Function(String phrase);

/// The front door for voice commands: transcript in → parse → route to a
/// handler → execute → speak confirmation → emit result.
///
/// The dispatcher owns the intent→handler registry. Three handlers are wired to
/// real behavior today (timer, note/task capture, recording control); the rest
/// of the recognized intents fall through to [StubCommandHandler] so every
/// supported phrase gets a coherent spoken response. Results are also published
/// on [results] for the UI (a command log / toast).
///
/// Nothing here throws: handlers are contractually fail-soft, and the dispatch
/// path catches anything they miss.
class VoiceCommandDispatcher {
  VoiceCommandDispatcher._({
    required IntentResolver resolver,
    required Map<VoiceIntent, VoiceCommandHandler> registry,
    required List<TimerCommandHandler> timerHandlers,
    SpeakCallback? speak,
    double minConfidence = 0.5,
  })  : _resolver = resolver,
        _registry = registry,
        _timerHandlers = timerHandlers,
        _speak = speak,
        _minConfidence = minConfidence;

  /// Builds a dispatcher with the default registry.
  ///
  /// [resolver] maps transcript → [VoiceCommand]; defaults to the on-device
  /// rule-based parser. Pass an [LlmIntentResolver] (or a [FallbackIntentResolver]
  /// wrapping it) to route recognition through Vapi / an LLM instead.
  /// [noteSink] receives captured notes/tasks (defaults to in-memory).
  /// [recorderControl] wires the recording-control intents to the real engine;
  /// when omitted those intents fall back to a stub. [onTimerElapsed] fires when
  /// a voice timer completes. [speak] is the TTS bridge for confirmations.
  factory VoiceCommandDispatcher({
    IntentResolver? resolver,
    NoteSink? noteSink,
    RecorderControl? recorderControl,
    void Function(VoiceTimer timer)? onTimerElapsed,
    SpeakCallback? speak,
    double minConfidence = 0.5,
  }) {
    final timerHandler = TimerCommandHandler(
      onElapsed: onTimerElapsed ?? (_) {},
    );
    final noteHandler = NoteCommandHandler(sink: noteSink ?? InMemoryNoteSink());

    final handlers = <VoiceCommandHandler>[
      timerHandler,
      noteHandler,
      if (recorderControl != null)
        RecordingCommandHandler(control: recorderControl),
    ];

    final registry = <VoiceIntent, VoiceCommandHandler>{};
    for (final handler in handlers) {
      for (final intent in handler.intents) {
        registry[intent] = handler;
      }
    }

    // Every remaining recognized intent gets the stub handler so coverage is
    // complete and the user always gets a sensible spoken reply.
    final stubbed = <VoiceIntent>{
      for (final intent in VoiceIntent.values)
        if (intent != VoiceIntent.unknown && !registry.containsKey(intent))
          intent,
    };
    if (stubbed.isNotEmpty) {
      final stub = StubCommandHandler(stubbed);
      for (final intent in stubbed) {
        registry[intent] = stub;
      }
    }

    return VoiceCommandDispatcher._(
      resolver: resolver ?? const RuleBasedIntentResolver(),
      registry: registry,
      timerHandlers: [timerHandler],
      speak: speak,
      minConfidence: minConfidence,
    );
  }

  final IntentResolver _resolver;
  final Map<VoiceIntent, VoiceCommandHandler> _registry;
  final List<TimerCommandHandler> _timerHandlers;
  final SpeakCallback? _speak;
  final double _minConfidence;

  final BehaviorSubject<VoiceCommandResult> _results =
      BehaviorSubject<VoiceCommandResult>();

  /// Stream of executed command results, for a command log / toast UI.
  ValueStream<VoiceCommandResult> get results => _results.stream;

  /// Live voice timers (across all timer handlers), for a countdown UI.
  List<VoiceTimer> get activeTimers =>
      _timerHandlers.expand((h) => h.activeTimers).toList(growable: false);

  /// Parse + execute a raw transcript end-to-end. The returned result is also
  /// pushed onto [results] and (best-effort) spoken aloud.
  Future<VoiceCommandResult> dispatch(String transcript) async {
    final command = await _resolver.resolve(transcript);
    return dispatchCommand(command);
  }

  /// Execute an already-parsed command (useful when the parser is swapped for
  /// an external NLU service upstream).
  Future<VoiceCommandResult> dispatchCommand(VoiceCommand command) async {
    final result = await _execute(command);
    if (!_results.isClosed) {
      _results.add(result);
    }
    final phrase = result.spokenResponse;
    if (phrase.isNotEmpty && _speak != null) {
      try {
        await _speak(phrase);
      } catch (_) {
        // TTS must never break the command pipeline.
      }
    }
    return result;
  }

  Future<VoiceCommandResult> _execute(VoiceCommand command) async {
    if (!command.isRecognized) {
      return VoiceCommandResult.unrecognized(command);
    }
    // Fail-closed comparison: `>=` is false for NaN, so a NaN/garbage
    // confidence from an untrusted resolver can never clear the gate (unlike
    // `confidence < threshold`, which NaN slips through).
    if (!(VoiceLimits.sanitizeConfidence(command.confidence) >=
        _minConfidence)) {
      return VoiceCommandResult.failure(
        command,
        'I think I misheard — could you repeat that?',
      );
    }
    final handler = _registry[command.intent];
    if (handler == null) {
      return VoiceCommandResult.notImplemented(command);
    }
    try {
      return await handler.handle(command);
    } catch (_) {
      return VoiceCommandResult.failure(
        command,
        'Something went wrong running that command.',
      );
    }
  }

  Future<void> dispose() async {
    for (final h in _timerHandlers) {
      h.dispose();
    }
    await _results.close();
  }
}
