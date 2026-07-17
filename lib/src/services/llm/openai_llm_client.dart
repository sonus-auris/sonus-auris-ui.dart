// OpenAI Chat Completions API over raw HTTP (POST /v1/chat/completions).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_client.dart';

/// Calls the OpenAI Chat Completions API
/// (`POST https://api.openai.com/v1/chat/completions`).
class OpenAiLlmClient implements LlmClient {
  OpenAiLlmClient({
    required this.apiKey,
    http.Client? httpClient,
    this.baseUrl = 'https://api.openai.com',
    this.defaultModel = 'gpt-5.1',
    this.timeout = const Duration(minutes: 5),
  }) : _http = httpClient ?? http.Client();

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final http.Client _http;

  @override
  final String defaultModel;

  @override
  Future<LlmResponse> complete({
    required List<LlmMessage> messages,
    String? system,
    String? model,
    int maxTokens = 1024,
  }) async {
    final resolvedModel = model ?? defaultModel;
    final body = <String, Object?>{
      'model': resolvedModel,
      'max_completion_tokens': maxTokens,
      'messages': [
        if (system != null && system.isNotEmpty)
          {'role': 'system', 'content': system},
        for (final m in messages)
          {
            'role': m.role == LlmRole.user ? 'user' : 'assistant',
            'content': m.text,
          },
      ],
    };

    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse('$baseUrl/v1/chat/completions'),
            headers: {
              'content-type': 'application/json',
              'authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on Exception catch (e) {
      throw LlmException('OpenAI request failed: $e');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmException(
        _errorMessage(response.body),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = (json['choices'] as List?) ?? const [];
    final first = choices.isEmpty
        ? null
        : choices.first as Map<String, dynamic>;
    final message = first?['message'] as Map<String, dynamic>?;
    final usage = json['usage'] as Map<String, dynamic>?;
    return LlmResponse(
      text: message?['content'] as String? ?? '',
      model: json['model'] as String? ?? resolvedModel,
      inputTokens: (usage?['prompt_tokens'] as num?)?.toInt(),
      outputTokens: (usage?['completion_tokens'] as num?)?.toInt(),
      refused:
          message?['refusal'] != null ||
          first?['finish_reason'] == 'content_filter',
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
