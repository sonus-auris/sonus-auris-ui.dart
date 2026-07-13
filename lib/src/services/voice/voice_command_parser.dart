// Rule-based (regex) recognizer turning a transcript into a structured VoiceCommand.
import '../../models/voice_command.dart';
import 'voice_limits.dart';

/// Turns a free-text transcript (from on-device or cloud STT) into a structured
/// [VoiceCommand].
///
/// This is an intentionally lightweight, **rule-based** recognizer: ordered
/// pattern rules, first match wins. It is good enough to demo and to route the
/// high-value intents hands-free, and it gives a stable contract (intents +
/// slot names) that a future ML/NLU recognizer can slot in behind without
/// touching handlers. The parser never executes anything and never throws — an
/// unrecognized phrase yields [VoiceIntent.unknown].
///
/// Slot conventions used by the wired handlers:
///   * setTimer / startFocusSession → `durationSeconds`
///   * takeNote / createTask / recordVoiceMemo → `text`
class VoiceCommandParser {
  const VoiceCommandParser();

  /// Optional wake words stripped from the front of the transcript before
  /// matching, so "Hey Sonus, set a timer…" parses the same as "set a timer…".
  static const List<String> wakeWords = [
    'hey sonus',
    'sonus',
    'hey auris',
    'auris',
  ];

  VoiceCommand parse(String rawTranscript) {
    final normalized = _normalize(rawTranscript);
    if (normalized.isEmpty) {
      return VoiceCommand(
        intent: VoiceIntent.unknown,
        transcript: rawTranscript.trim(),
        confidence: 0,
      );
    }

    for (final rule in _rules) {
      final match = rule.pattern.firstMatch(normalized);
      if (match != null) {
        final slots = rule.extract(match, normalized);
        return VoiceCommand(
          intent: rule.intent,
          transcript: normalized,
          slots: slots,
          confidence: rule.confidence,
        );
      }
    }

    return VoiceCommand(
      intent: VoiceIntent.unknown,
      transcript: normalized,
      confidence: 0,
    );
  }

  /// Lowercases, collapses whitespace, and strips a leading wake word and
  /// trailing punctuation so patterns can stay simple.
  String _normalize(String input) {
    // Bound the work the rule regexes do: an utterance is never this long, so
    // truncating only ever clips a pathological/abusive transcript (ReDoS / CPU
    // guard) before any matching runs.
    var text = VoiceLimits.clip(input, VoiceLimits.maxTranscriptChars)
        .trim()
        .toLowerCase();
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    for (final wake in wakeWords) {
      if (text.startsWith(wake)) {
        text = text.substring(wake.length).replaceFirst(RegExp(r'^[,\s]+'), '');
        break;
      }
    }
    return text.replaceAll(RegExp(r'[.!?]+$'), '').trim();
  }

  // --- Rule table (ordered; first match wins) -----------------------------

  static final List<_Rule> _rules = [
    // Timer: "set a timer for 12 minutes", "timer 90 seconds".
    _Rule(
      VoiceIntent.setTimer,
      RegExp(r'\b(?:set (?:a )?)?timer\b.*?(\d+)\s*(second|minute|hour)s?'),
      (m, _) => {'durationSeconds': _toSeconds(m.group(1)!, m.group(2)!)},
    ),
    // Focus session: "start a 25-minute focus session".
    _Rule(
      VoiceIntent.startFocusSession,
      RegExp(r'\bfocus session\b'),
      (m, text) => {
        'durationSeconds': _firstDurationSeconds(text) ?? '1500',
      },
    ),
    // Note: "take a note: ...", "note that ...", "save this idea ...".
    _Rule(
      VoiceIntent.takeNote,
      RegExp(r'\b(?:take|make|write|jot|save) (?:a |this |an )?'
          r'(?:note|idea)s?\b[:\s]*(.*)'),
      (m, _) => {'text': (m.group(1) ?? '').trim()},
    ),
    _Rule(
      VoiceIntent.takeNote,
      RegExp(r'\bnote that\b[:\s]*(.*)'),
      (m, _) => {'text': (m.group(1) ?? '').trim()},
    ),
    // Task: "create a task: renew passport", "add a task to ...".
    _Rule(
      VoiceIntent.createTask,
      RegExp(r'\b(?:create|add|make) (?:a |an )?task\b\s*:?\s*(?:to\s+)?(.*)'),
      (m, _) => {'text': (m.group(1) ?? '').trim()},
    ),
    // Voice memo.
    _Rule(
      VoiceIntent.recordVoiceMemo,
      RegExp(r'\b(?:record|capture) (?:a )?voice memo\b[:\s]*(.*)'),
      (m, _) => {'text': (m.group(1) ?? '').trim()},
    ),
    // App-native recording control.
    _Rule(
      VoiceIntent.startRecording,
      RegExp(r'\b(?:start|begin|resume) (?:the )?recording\b'),
      (_, _) => const {},
    ),
    _Rule(
      VoiceIntent.stopRecording,
      RegExp(r'\b(?:stop|end|pause) (?:the )?recording\b'),
      (_, _) => const {},
    ),
    // Reminder: "remind me to call John tomorrow at 9am".
    _Rule(
      VoiceIntent.setReminder,
      RegExp(r'\bremind me\b\s*(?:to)?\s*(.*)'),
      (m, _) => {'text': (m.group(1) ?? '').trim()},
    ),
    // Shopping / list: "add milk to my shopping list".
    _Rule(
      VoiceIntent.addToList,
      RegExp(r'\badd\b\s+(.*?)\s+to (?:my )?(.*?) ?list\b'),
      (m, _) => {
        'item': (m.group(1) ?? '').trim(),
        'list': (m.group(2) ?? '').trim(),
      },
    ),
    // Calendar.
    _Rule(
      VoiceIntent.queryCalendar,
      RegExp(r"\bwhat'?s on my calendar\b|\bmy schedule\b"),
      (_, _) => const {},
    ),
    _Rule(
      VoiceIntent.createCalendarEvent,
      RegExp(r'\b(?:create|add|schedule) (?:a )?(?:calendar )?event\b\s*(.*)'),
      (m, _) => {'text': (m.group(1) ?? '').trim()},
    ),
    // Communication.
    _Rule(
      VoiceIntent.callContact,
      RegExp(r'\bcall\b\s+(.+)'),
      (m, _) => {'contact': (m.group(1) ?? '').trim()},
    ),
    _Rule(
      VoiceIntent.textContact,
      RegExp(r'\b(?:text|message)\b\s+(\S+)\s*[:,]?\s*(.*)'),
      (m, _) => {
        'contact': (m.group(1) ?? '').trim(),
        'text': (m.group(2) ?? '').trim(),
      },
    ),
    _Rule(
      VoiceIntent.readMessages,
      RegExp(r'\bread (?:my )?(?:latest |new |unread )?messages\b'),
      (_, _) => const {},
    ),
    _Rule(
      VoiceIntent.replyMessage,
      RegExp(r'\breply\b[:\s]+(.*)'),
      (m, _) => {'text': (m.group(1) ?? '').trim()},
    ),
    // Navigation.
    _Rule(
      VoiceIntent.navigateTo,
      RegExp(r'\b(?:navigate|directions|drive) to\b\s+(.+)'),
      (m, _) => {'destination': (m.group(1) ?? '').trim()},
    ),
    _Rule(
      VoiceIntent.findNearby,
      RegExp(r'\bfind\b\s+(.+?)\s+(?:near ?by|near me|around me)\b'),
      (m, _) => {'query': (m.group(1) ?? '').trim()},
    ),
    _Rule(
      VoiceIntent.etaToDestination,
      RegExp(r'\bhow long\b.*\bto\b\s+(.+)'),
      (m, _) => {'destination': (m.group(1) ?? '').trim()},
    ),
    // Information.
    _Rule(
      VoiceIntent.queryWeather,
      RegExp(r"\bweather\b"),
      (_, text) => {'when': text.contains('tomorrow') ? 'tomorrow' : 'today'},
    ),
    _Rule(
      VoiceIntent.calculate,
      RegExp(r"\bwhat'?s\b.*\b\d+\s*%|\bcalculate\b"),
      (_, text) => {'expression': text},
      // Broad pattern over free-form math phrasing — flag as lower confidence so
      // the dispatcher can require confirmation before acting on it.
      confidence: 0.6,
    ),
    // Device control.
    _Rule(
      VoiceIntent.toggleDoNotDisturb,
      RegExp(r'\bdo not disturb\b'),
      (_, text) => {'state': text.contains('off') ? 'off' : 'on'},
    ),
    _Rule(
      VoiceIntent.setBrightness,
      RegExp(r'\bbrightness\b.*?(\d+)\s*%?'),
      (m, _) => {'percent': m.group(1) ?? ''},
    ),
    _Rule(
      VoiceIntent.toggleFlashlight,
      RegExp(r'\bflashlight\b|\btorch\b'),
      (_, text) => {'state': text.contains('off') ? 'off' : 'on'},
    ),
    _Rule(
      VoiceIntent.takePhoto,
      RegExp(r'\btake (?:a )?photo\b|\btake (?:a )?picture\b'),
      (_, _) => const {},
    ),
    // Smart home.
    _Rule(
      VoiceIntent.smartHomeControl,
      RegExp(r'\b(?:turn (?:on|off)|lock|unlock|open|close|set)\b.*'
          r'\b(lights?|thermostat|door|garage|lock)\b'),
      (m, text) => {'device': m.group(1) ?? '', 'utterance': text},
    ),
    // Media.
    _Rule(
      VoiceIntent.mediaPause,
      RegExp(r'^\s*pause\s*$'),
      (_, _) => const {},
    ),
    _Rule(
      VoiceIntent.mediaSkip,
      RegExp(r'\bskip\b|\bnext (?:song|track)\b'),
      (_, _) => const {},
    ),
    _Rule(
      VoiceIntent.mediaPlay,
      RegExp(r'\bplay\b\s*(.*)'),
      (m, _) => {'query': (m.group(1) ?? '').trim()},
    ),
    // Health & fitness.
    _Rule(
      VoiceIntent.startWorkout,
      RegExp(r'\b(?:start (?:a )?workout|track a run)\b'),
      (_, text) => {'utterance': text},
    ),
    _Rule(
      VoiceIntent.querySteps,
      RegExp(r'\bhow many steps\b'),
      (_, _) => const {},
    ),
    // Assistant.
    _Rule(
      VoiceIntent.summarizeMessages,
      RegExp(r'\bsummar(?:ize|ise)\b.*\b(emails?|messages?|inbox)\b'),
      (_, _) => const {},
    ),
    _Rule(
      VoiceIntent.queryPriorities,
      RegExp(r'\b(?:top priorities|what should i (?:do|focus))\b'),
      (_, _) => const {},
    ),
    _Rule(
      VoiceIntent.translate,
      RegExp(r'\btranslate\b.*\binto\b\s+(\w+)'),
      (m, _) => {'language': (m.group(1) ?? '').trim()},
    ),
  ];

  // --- Helpers ------------------------------------------------------------

  static String _toSeconds(String value, String unit) {
    // Clamp the raw count before multiplying so a huge spoken number can't
    // overflow 64-bit math into a wrong (possibly in-range) duration. The
    // handler enforces the real cap; this just keeps the arithmetic sane.
    final parsed = int.tryParse(value) ?? 0;
    final n = parsed < 0
        ? 0
        : (parsed > VoiceLimits.maxTimerSeconds
            ? VoiceLimits.maxTimerSeconds
            : parsed);
    switch (unit) {
      case 'hour':
        return (n * 3600).toString();
      case 'minute':
        return (n * 60).toString();
      default:
        return n.toString();
    }
  }

  static String? _firstDurationSeconds(String text) {
    final m =
        RegExp(r'(\d+)\s*(second|minute|hour)s?').firstMatch(text);
    if (m == null) {
      return null;
    }
    return _toSeconds(m.group(1)!, m.group(2)!);
  }
}

typedef _SlotExtractor = Map<String, String> Function(
  RegExpMatch match,
  String text,
);

class _Rule {
  _Rule(this.intent, this.pattern, this.extract, {this.confidence = 0.9});

  final VoiceIntent intent;
  final RegExp pattern;
  final _SlotExtractor extract;
  final double confidence;
}
