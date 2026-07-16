// Anthropic Messages API over raw HTTP (POST /v1/messages). Supports the
// Claude Fable 5 and Opus 4.8 model families.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_client.dart';

/// Calls the Anthropic Messages API (`POST https://api.anthropic.com/v1/messages`).
///
/// Defaults to Claude Opus 4.8; pass `model: AnthropicLlmClient.fable` for
/// Claude Fable 5. Fable requests automatically opt into Anthropic's
/// server-side refusal fallbacks (a safety-classifier decline is re-served by
/// Opus 4.8 inside the same call), so callers still get an answer when the
/// classifiers false-positive.
class AnthropicLlmClient implements LlmClient {
  AnthropicLlmClient({
    required this.apiKey,
    http.Client? httpClient,
    this.baseUrl = 'https://api.anthropic.com',
    this.timeout = const Duration(minutes: 5),
  }) : _http = httpClient ?? http.Client();

  static const String opus = 'claude-opus-4-8';
  static const String fable = 'claude-fable-5';

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final http.Client _http;

  @override
  String get defaultModel => opus;

  @override
  Future<LlmResponse> complete({
    required List<LlmMessage> messages,
    String? system,
    String? model,
    int maxTokens = 1024,
  }) async {
    final resolvedModel = model ?? defaultModel;
    final isFable = resolvedModel.startsWith('claude-fable');
    final body = <String, Object?>{
      'model': resolvedModel,
      'max_tokens': maxTokens,
      if (system != null && system.isNotEmpty) 'system': system,
      'messages': [
        for (final m in messages)
          {
            'role': m.role == LlmRole.user ? 'user' : 'assistant',
            'content': m.text,
          },
      ],
      // On Fable, a safety-classifier decline is re-run on Opus 4.8 within the
      // same request instead of returning an empty refusal.
      if (isFable)
        'fallbacks': [
          {'model': opus},
        ],
    };
    final headers = <String, String>{
      'content-type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      if (isFable) 'anthropic-beta': 'server-side-fallback-2026-06-01',
    };

    final http.Response response;
    try {
      response = await _http
          .post(Uri.parse('$baseUrl/v1/messages'),
              headers: headers, body: jsonEncode(body))
          .timeout(timeout);
    } on Exception catch (e) {
      throw LlmException('Anthropic request failed: $e');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmException(
        _errorMessage(response.body),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final content = (json['content'] as List?) ?? const [];
    final text = content
        .whereType<Map<String, dynamic>>()
        .where((block) => block['type'] == 'text')
        .map((block) => block['text'] as String? ?? '')
        .join();
    final usage = json['usage'] as Map<String, dynamic>?;
    return LlmResponse(
      text: text,
      model: json['model'] as String? ?? resolvedModel,
      inputTokens: (usage?['input_tokens'] as num?)?.toInt(),
      outputTokens: (usage?['output_tokens'] as num?)?.toInt(),
      refused: json['stop_reason'] == 'refusal',
    );
  }

  static String _errorMessage(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'] as Map<String, dynamic>?;
      return error?['message'] as String? ?? body;
    } catch (_) {
      return body;
    }
  }

  void dispose() => _http.close();
}
