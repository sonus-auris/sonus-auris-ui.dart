// The transcript -> structured VoiceCommand seam, with rule-based, LLM, and fallback resolver strategies.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/voice_command.dart';
import 'voice_command_parser.dart';
import 'voice_limits.dart';

/// The seam between *transcript* and *structured command*.
///
/// Recognition has two interchangeable strategies behind this one interface, so
/// the dispatcher and handlers never change when we upgrade how intents are
/// understood:
///
///   1. [RuleBasedIntentResolver] — the on-device regex parser. Zero latency,
///      no network, no LLM. Good for the demo and as an offline fallback.
///   2. [LlmIntentResolver] — sends the transcript to a server that runs an LLM
///      (or embedding classifier) with function-calling and returns the chosen
///      intent + typed params. This is the reliable, fuzzy-language path.
///
/// Strategy (2) is how this should work in production: get speech→text rock
/// solid (on-device STT or Vapi's pipeline), then let a model map free-form
/// text onto one of our [VoiceIntent] "functions" and fill its slots — exactly
/// the tool-calling pattern the `dd-rust-vapi-phone` service already uses for
/// its phone tree. The two resolvers can be composed: try the LLM, fall back to
/// rules on timeout/offline (see [FallbackIntentResolver]).
abstract class IntentResolver {
  Future<VoiceCommand> resolve(String transcript);
}

/// On-device, rule-based resolution. Wraps [VoiceCommandParser].
class RuleBasedIntentResolver implements IntentResolver {
  const RuleBasedIntentResolver([this.parser = const VoiceCommandParser()]);

  final VoiceCommandParser parser;

  @override
  Future<VoiceCommand> resolve(String transcript) async =>
      parser.parse(transcript);
}

/// LLM / embedding-backed resolution (scaffolding).
///
/// POSTs the transcript to an intent endpoint and expects back a JSON object
/// describing the chosen function and its arguments:
///
/// ```json
/// { "intent": "setTimer", "slots": { "durationSeconds": "720" },
///   "confidence": 0.97 }
/// ```
///
/// The server side is where the heavy lifting lives and is intentionally *not*
/// implemented here. Two natural homes for it:
///
///   * **Vapi** — register each [VoiceIntent] as a Vapi `function` tool (the
///     enum value is the tool name, the slot schema is the tool's `parameters`;
///     see [toolSchemas]); Vapi's model emits a `tool-call` with filled
///     arguments that map 1:1 onto [VoiceCommand].
///   * **A direct LLM call** — Claude/other with the same tool/function schema,
///     or an embedding nearest-neighbour classifier over canonical phrasings
///     for cheaper, lower-latency intent matching.
///
/// Either way the wire contract above is all the client needs, so this resolver
/// works unchanged regardless of which backend answers. Fails soft to
/// [VoiceIntent.unknown] so a backend error never crashes the pipeline.
class LlmIntentResolver implements IntentResolver {
  /// Throws [ArgumentError] if [endpoint] is not a safe destination for
  /// transcripts. Because the body carries always-on-mic transcript text — the
  /// most sensitive data the app handles — this fails closed: HTTPS only,
  /// except an http loopback for local development. This mirrors the guard in
  /// `SpeechToTextClient` so no plaintext exfiltration path can be configured.
  LlmIntentResolver({
    required this.endpoint,
    this.apiKey,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 6),
  }) : _http = httpClient ?? http.Client() {
    if (!isSafeEndpoint(endpoint)) {
      throw ArgumentError.value(
        endpoint.toString(),
        'endpoint',
        'Intent endpoint must be https (or http loopback for local dev); '
            'transcripts must never leave the device in plaintext.',
      );
    }
  }

  /// HTTPS endpoint that maps transcript → intent JSON. Could be the
  /// `dd-rust-vapi-phone` service (extended with an intent route) or any
  /// LLM-backed function-calling proxy.
  final Uri endpoint;
  final String? apiKey;
  final Duration timeout;
  final http.Client _http;

  /// True when [uri] is an acceptable transcript destination: https with a
  /// host, or http only to loopback (localhost / 127.0.0.1 / ::1).
  static bool isSafeEndpoint(Uri uri) {
    final host = uri.host.trim();
    if (host.isEmpty) {
      return false;
    }
    if (uri.scheme == 'https') {
      return true;
    }
    if (uri.scheme == 'http') {
      return host == 'localhost' || host == '127.0.0.1' || host == '::1';
    }
    return false;
  }

  @override
  Future<VoiceCommand> resolve(String transcript) async {
    // Don't ship more than one utterance's worth of text off-device.
    final clipped = VoiceLimits.clip(
      transcript,
      VoiceLimits.maxTranscriptChars,
    );
    final headers = <String, String>{'content-type': 'application/json'};
    if (apiKey != null && apiKey!.trim().isNotEmpty) {
      headers['authorization'] = 'Bearer ${apiKey!.trim()}';
    }
    try {
      final resp = await _http
          .post(
            endpoint,
            headers: headers,
            body: jsonEncode({
              'transcript': clipped,
              // Hand the model the catalog of callable functions so it can pick
              // one and fill its parameters.
              'tools': toolSchemas(),
            }),
          )
          .timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return _unknown(transcript);
      }
      // Treat the response as untrusted: refuse to parse an oversized body.
      if (resp.bodyBytes.length > VoiceLimits.maxResponseBytes) {
        return _unknown(transcript);
      }
      return _commandFromJson(transcript, resp.body);
    } catch (_) {
      return _unknown(transcript);
    }
  }

  VoiceCommand _commandFromJson(String transcript, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return _unknown(transcript);
      }
      final intent = _intentByName(decoded['intent'] as String?);
      final rawSlots = decoded['slots'];
      final slots = <String, String>{};
      if (rawSlots is Map) {
        for (final entry in rawSlots.entries) {
          if (slots.length >= VoiceLimits.maxSlots) {
            break;
          }
          slots['${entry.key}'] = VoiceLimits.clip(
            '${entry.value}',
            VoiceLimits.maxSlotValueChars,
          );
        }
      }
      final confidence = VoiceLimits.sanitizeConfidence(
        (decoded['confidence'] as num?)?.toDouble() ?? 0.8,
      );
      return VoiceCommand(
        intent: intent,
        transcript: VoiceLimits.clip(
          transcript,
          VoiceLimits.maxTranscriptChars,
        ),
        slots: slots,
        confidence: confidence,
      );
    } catch (_) {
      return _unknown(transcript);
    }
  }

  VoiceCommand _unknown(String transcript) => VoiceCommand(
    intent: VoiceIntent.unknown,
    transcript: transcript,
    confidence: 0,
  );

  static VoiceIntent _intentByName(String? name) {
    if (name == null) return VoiceIntent.unknown;
    for (final i in VoiceIntent.values) {
      if (i.name == name) return i;
    }
    return VoiceIntent.unknown;
  }

  void close() => _http.close();

  /// The catalog of callable "functions", one per recognizable intent, in the
  /// OpenAI/Vapi/Anthropic tool-schema shape. This is what makes an LLM able to
  /// translate text → the right function with the right params. The slot schema
  /// is deliberately minimal scaffolding for the wired intents; extend per
  /// intent as handlers gain real parameters.
  static List<Map<String, dynamic>> toolSchemas() {
    Map<String, dynamic> fn(
      VoiceIntent intent,
      String description,
      Map<String, dynamic> properties,
      List<String> required,
    ) => {
      'type': 'function',
      'function': {
        'name': intent.name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          'required': required,
        },
      },
    };

    return [
      fn(
        VoiceIntent.setTimer,
        'Start a countdown timer for a stated duration.',
        {
          'durationSeconds': {
            'type': 'integer',
            'description': 'Timer length in seconds.',
          },
        },
        ['durationSeconds'],
      ),
      fn(
        VoiceIntent.takeNote,
        'Capture a free-text note for the user.',
        {
          'text': {'type': 'string', 'description': 'The note body.'},
        },
        ['text'],
      ),
      fn(
        VoiceIntent.createTask,
        'Create a to-do task.',
        {
          'text': {'type': 'string', 'description': 'The task description.'},
        },
        ['text'],
      ),
      fn(
        VoiceIntent.startRecording,
        'Start audio recording on the device.',
        const {},
        const [],
      ),
      fn(
        VoiceIntent.stopRecording,
        'Stop audio recording on the device.',
        const {},
        const [],
      ),
    ];
  }
}

/// Tries [primary] (e.g. the LLM/Vapi resolver) and falls back to [fallback]
/// (the on-device parser) whenever the primary can't recognize the phrase or
/// errors — so commands keep working offline and the cloud path only ever
/// improves recognition, never gates it.
class FallbackIntentResolver implements IntentResolver {
  const FallbackIntentResolver({required this.primary, required this.fallback});

  final IntentResolver primary;
  final IntentResolver fallback;

  @override
  Future<VoiceCommand> resolve(String transcript) async {
    final first = await primary.resolve(transcript);
    if (first.isRecognized) {
      return first;
    }
    return fallback.resolve(transcript);
  }
}
