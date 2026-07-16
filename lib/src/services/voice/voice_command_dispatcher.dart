// Routes a resolved VoiceCommand to its handler via an intent->handler registry and speaks the confirmation.
import 'package:rxdart/rxdart.dart';

import '../../models/voice_command.dart';
import 'handlers/note_command_handler.dart';
import 'handlers/recording_command_handler.dart';
import 'handlers/timer_command_handler.dart';
import 'intent_resolver.dart';
import 'voice_command_handler.dart';
import 'voice_command_parser.dart';
import 'voice_limits.dart';

/// Speaks short confirmation phrases back to the user. The app already has
/// `RecordingFeedback.say` (flutter_tts) — adapt it to this typedef when wiring
/// the dispatcher into [AppController].
typedef SpeakCallback = Future<void> Function(String phrase);

/// The front door for voice commands: transcript in → parse → route to a
/// handler → execute → speak confirmation → emit result.
///
/// The dispatcher owns the intent→handler registry. Three handlers are wired to
/// real behavior today (timer, note/task capture, recording control). Additional
/// application/platform capabilities are supplied as real handlers. Recognized
/// intents without an executor are reported as unavailable and never as handled.
///
/// Nothing here throws: handlers are contractually fail-soft, and the dispatch
/// path catches anything they miss.
class VoiceCommandDispatcher {
  VoiceCommandDispatcher._({
    required this._resolver,
    required this._registry,
    required this._timerHandlers,
    this._speak,
    this._minConfidence = 0.5,
  });

  /// Builds a dispatcher with the default registry.
  ///
  /// [resolver] maps transcript → [VoiceCommand]; defaults to the on-device
  /// rule-based parser. Pass an [LlmIntentResolver] (or a [FallbackIntentResolver]
  /// wrapping it) to route recognition through Vapi / an LLM instead.
  /// [noteSink] receives captured notes/tasks. Notes are enabled only when a
  /// persistent sink is supplied; the dispatcher never silently stores them in
  /// process memory.
  /// [recorderControl] wires the recording-control intents to the real engine;
  /// when omitted those intents remain unavailable. [additionalHandlers] wires
  /// real platform/app executors for the other recognized intents.
  factory VoiceCommandDispatcher({
    IntentResolver? resolver,
    NoteSink? noteSink,
    RecorderControl? recorderControl,
    Iterable<VoiceCommandHandler> additionalHandlers = const [],
    void Function(VoiceTimer timer)? onTimerElapsed,
    SpeakCallback? speak,
    double minConfidence = 0.5,
  }) {
    final timerHandler = TimerCommandHandler(
      onElapsed: onTimerElapsed ?? (_) {},
    );

    final handlers = <VoiceCommandHandler>[
      timerHandler,
      if (noteSink != null) NoteCommandHandler(sink: noteSink),
      if (recorderControl != null)
        RecordingCommandHandler(control: recorderControl),
      ...additionalHandlers,
    ];

    final registry = <VoiceIntent, VoiceCommandHandler>{};
    for (final handler in handlers) {
      for (final intent in handler.intents) {
        if (intent == VoiceIntent.unknown) {
          throw ArgumentError('Handlers cannot execute the unknown intent.');
        }
        if (registry.containsKey(intent)) {
          throw ArgumentError(
            'Multiple handlers registered for ${intent.name}.',
          );
        }
        registry[intent] = handler;
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

  /// A short-lived dialogue turn: the previous command is waiting on one slot
  /// (e.g. pause duration) and the next utterance is treated as the answer.
  VoiceCommand? _pendingCommand;
  String? _pendingSlot;
  DateTime? _pendingExpiresAt;

  /// How long a "for how long?"-style question stays answerable.
  static const Duration followUpWindow = Duration(seconds: 30);

  /// True while the previous command's follow-up question ("for how long?")
  /// is still answerable. Callers that gate dispatch on a wake word should
  /// let a bare answer through while this is set.
  bool get hasPendingFollowUp =>
      _pendingCommand != null &&
      _pendingExpiresAt != null &&
      DateTime.now().isBefore(_pendingExpiresAt!);

  /// Stream of executed command results, for a command log / toast UI.
  ValueStream<VoiceCommandResult> get results => _results.stream;

  /// Live voice timers (across all timer handlers), for a countdown UI.
  List<VoiceTimer> get activeTimers =>
      _timerHandlers.expand((h) => h.activeTimers).toList(growable: false);

  /// Parse + execute a raw transcript end-to-end. The returned result is also
  /// pushed onto [results] and (best-effort) spoken aloud.
  ///
  /// When the previous result asked a follow-up question (missing slot), this
  /// first tries to read the utterance as that answer — "pause recording" →
  /// "for how long?" → "ten minutes" completes the original command. A reply
  /// that doesn't answer falls through to normal parsing, so "never mind, stop
  /// recording" still works mid-dialogue.
  Future<VoiceCommandResult> dispatch(String transcript) async {
    final pending = _takePendingFollowUp();
    if (pending != null) {
      final seconds = VoiceCommandParser.spokenDurationSeconds(transcript);
      if (seconds != null) {
        return dispatchCommand(
          pending.command.copyWith(
            slots: {...pending.command.slots, pending.slot: '$seconds'},
          ),
        );
      }
    }
    final command = await _resolver.resolve(transcript);
    return dispatchCommand(command);
  }

  ({VoiceCommand command, String slot})? _takePendingFollowUp() {
    final command = _pendingCommand;
    final slot = _pendingSlot;
    final expires = _pendingExpiresAt;
    _pendingCommand = null;
    _pendingSlot = null;
    _pendingExpiresAt = null;
    if (command == null || slot == null || expires == null) {
      return null;
    }
    if (DateTime.now().isAfter(expires)) {
      return null;
    }
    return (command: command, slot: slot);
  }

  /// Execute an already-parsed command (useful when the parser is swapped for
  /// an external NLU service upstream).
  Future<VoiceCommandResult> dispatchCommand(VoiceCommand command) async {
    final result = await _execute(command);
    if (result.data[VoiceCommandResult.followUpSlotKey] case final String slot
        when slot.isNotEmpty) {
      _pendingCommand = result.command;
      _pendingSlot = slot;
      _pendingExpiresAt = DateTime.now().add(followUpWindow);
    }
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
