/// Voice-command intent model.
///
/// A spoken phrase is turned into a [VoiceCommand] (intent + extracted slots)
/// by the parser, then routed to a handler by the dispatcher. Most of the
/// surface area here is deliberate *scaffolding*: every intent we want to
/// eventually support has a stable enum value and category so the parser,
/// dispatcher, UI, and analytics can all refer to it. Execution is enabled only
/// after the application registers a real handler for that intent.
///
/// The timer is always wired. Note/task and recording control are wired when
/// their persistent sink and controller are supplied to the dispatcher; other
/// capabilities use registered application/platform handlers.
library;

/// Broad grouping used for UI sectioning and to decide which capability /
/// permission a command needs. Mirrors the product's command taxonomy.
enum VoiceCommandCategory {
  productivity,
  communication,
  navigation,
  information,
  deviceControl,
  smartHome,
  media,
  capture,
  healthFitness,
  assistant,
  unknown,
}

/// Every voice intent the app knows how to *recognize*. Recognition (parsing)
/// and execution (handling) are separate concerns: an intent can be parsed long
/// before its application/platform executor is available.
enum VoiceIntent {
  // --- Productivity ---
  setTimer(VoiceCommandCategory.productivity),
  startFocusSession(VoiceCommandCategory.productivity),
  setReminder(VoiceCommandCategory.productivity),
  addToList(VoiceCommandCategory.productivity),
  createCalendarEvent(VoiceCommandCategory.productivity),
  queryCalendar(VoiceCommandCategory.productivity),

  // --- Communication ---
  callContact(VoiceCommandCategory.communication),
  textContact(VoiceCommandCategory.communication),
  readMessages(VoiceCommandCategory.communication),
  replyMessage(VoiceCommandCategory.communication),

  // --- Navigation ---
  navigateTo(VoiceCommandCategory.navigation),
  etaToDestination(VoiceCommandCategory.navigation),
  findNearby(VoiceCommandCategory.navigation),

  // --- Information retrieval ---
  queryWeather(VoiceCommandCategory.information),
  calculate(VoiceCommandCategory.information),
  unitConversion(VoiceCommandCategory.information),

  // --- Device control ---
  toggleDoNotDisturb(VoiceCommandCategory.deviceControl),
  setBrightness(VoiceCommandCategory.deviceControl),
  toggleFlashlight(VoiceCommandCategory.deviceControl),
  takePhoto(VoiceCommandCategory.deviceControl),

  // --- App-native capture (the dashcam itself) ---
  startRecording(VoiceCommandCategory.capture),
  stopRecording(VoiceCommandCategory.capture),
  takeNote(VoiceCommandCategory.capture),
  recordVoiceMemo(VoiceCommandCategory.capture),
  createTask(VoiceCommandCategory.capture),

  // --- Smart home ---
  smartHomeControl(VoiceCommandCategory.smartHome),

  // --- Media ---
  mediaPlay(VoiceCommandCategory.media),
  mediaPause(VoiceCommandCategory.media),
  mediaSkip(VoiceCommandCategory.media),

  // --- Health & fitness ---
  startWorkout(VoiceCommandCategory.healthFitness),
  querySteps(VoiceCommandCategory.healthFitness),

  // --- AI assistant ---
  summarizeMessages(VoiceCommandCategory.assistant),
  queryPriorities(VoiceCommandCategory.assistant),
  translate(VoiceCommandCategory.assistant),

  /// Nothing matched — the dispatcher will fall back / ask to rephrase.
  unknown(VoiceCommandCategory.unknown);

  const VoiceIntent(this.category);

  final VoiceCommandCategory category;
}

/// A parsed, ready-to-execute command.
///
/// [slots] holds the free-form arguments the parser pulled out of the
/// transcript (e.g. `{'durationSeconds': '720'}` for a timer, `{'text': 'buy
/// milk'}` for a note). Values are stringly-typed on purpose so the model stays
/// trivially serializable and handler-agnostic; handlers parse what they need.
class VoiceCommand {
  const VoiceCommand({
    required this.intent,
    required this.transcript,
    this.slots = const {},
    this.confidence = 1.0,
  });

  final VoiceIntent intent;

  /// The original (normalized) transcript this command was parsed from.
  final String transcript;

  /// Extracted arguments, keyed by slot name. Stringly-typed by design.
  final Map<String, String> slots;

  /// Parser confidence in 0..1. The dispatcher can require a floor before
  /// acting on destructive or ambiguous intents.
  final double confidence;

  bool get isRecognized => intent != VoiceIntent.unknown;

  String? slot(String name) => slots[name];

  VoiceCommand copyWith({
    VoiceIntent? intent,
    String? transcript,
    Map<String, String>? slots,
    double? confidence,
  }) {
    return VoiceCommand(
      intent: intent ?? this.intent,
      transcript: transcript ?? this.transcript,
      slots: slots ?? this.slots,
      confidence: confidence ?? this.confidence,
    );
  }

  Map<String, dynamic> toJson() => {
    'intent': intent.name,
    'category': intent.category.name,
    'transcript': transcript,
    'slots': slots,
    'confidence': confidence,
  };

  @override
  String toString() =>
      'VoiceCommand(${intent.name}, slots: $slots, conf: ${confidence.toStringAsFixed(2)})';
}
