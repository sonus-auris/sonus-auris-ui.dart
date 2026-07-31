// Provider-agnostic chat-completion interface over plain HTTP. Implementations:
// AnthropicLlmClient (Claude Fable/Opus), OpenAiLlmClient, GeminiLlmClient.
import 'dart:async';

/// One conversation turn sent to an LLM provider.
class LlmMessage {
  const LlmMessage.user(this.text) : role = LlmRole.user;
  const LlmMessage.assistant(this.text) : role = LlmRole.assistant;

  final LlmRole role;
  final String text;
}

enum LlmRole { user, assistant }

/// A completed LLM response, normalized across providers.
class LlmResponse {
  const LlmResponse({
    required this.text,
    required this.model,
    this.inputTokens,
    this.outputTokens,
    this.refused = false,
  });

  final String text;

  /// The model that actually served the response (may differ from the
  /// requested model, e.g. Anthropic server-side fallbacks).
  final String model;

  final int? inputTokens;
  final int? outputTokens;

  /// True when the provider declined the request for safety/policy reasons
  /// (e.g. Anthropic `stop_reason: "refusal"`). [text] may be empty.
  final bool refused;
}

/// Thrown when a provider returns a non-2xx response or an unparseable body.
class LlmException implements Exception {
  const LlmException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// 429 and 5xx responses are transient; callers may retry with backoff.
  bool get isRetryable =>
      statusCode == 429 || (statusCode != null && statusCode! >= 500);

  @override
  String toString() => 'LlmException(${statusCode ?? 'network'}): $message';
}

/// A chat-completion client for one LLM provider. All implementations use the
/// plain HTTP APIs (no vendor SDKs) so they work anywhere `package:http` does.
abstract class LlmClient {
  /// The model used when [complete] is called without an explicit `model`.
  String get defaultModel;

  /// Sends [messages] (oldest first) and returns the assistant's reply.
  /// [system] is an optional system prompt. Throws [LlmException] on failure.
  Future<LlmResponse> complete({
    required List<LlmMessage> messages,
    String? system,
    String? model,
    int maxTokens = 1024,
  });
}
