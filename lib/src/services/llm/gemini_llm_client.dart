// Google Gemini API over raw HTTP (POST /v1beta/models/{model}:generateContent).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_client.dart';

/// Calls the Google Gemini `generateContent` REST API
/// (`POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`).
class GeminiLlmClient implements LlmClient {
  GeminiLlmClient({
    required this.apiKey,
    http.Client? httpClient,
    this.baseUrl = 'https://generativelanguage.googleapis.com',
    this.defaultModel = 'gemini-2.5-flash',
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
      if (system != null && system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
      'contents': [
        for (final m in messages)
          {
            'role': m.role == LlmRole.user ? 'user' : 'model',
            'parts': [
              {'text': m.text},
            ],
          },
      ],
      'generationConfig': {'maxOutputTokens': maxTokens},
    };

    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse('$baseUrl/v1beta/models/$resolvedModel:generateContent'),
            headers: {
              'content-type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on Exception catch (e) {
      throw LlmException('Gemini request failed: $e');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmException(
        _errorMessage(response.body),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = (json['candidates'] as List?) ?? const [];
    final first = candidates.isEmpty
        ? null
        : candidates.first as Map<String, dynamic>;
    final parts =
        ((first?['content'] as Map<String, dynamic>?)?['parts'] as List?) ??
        const [];
    final text = parts
        .whereType<Map<String, dynamic>>()
        .map((part) => part['text'] as String? ?? '')
        .join();
    final usage = json['usageMetadata'] as Map<String, dynamic>?;
    return LlmResponse(
      text: text,
      model: json['modelVersion'] as String? ?? resolvedModel,
      inputTokens: (usage?['promptTokenCount'] as num?)?.toInt(),
      outputTokens: (usage?['candidatesTokenCount'] as num?)?.toInt(),
      refused:
          first?['finishReason'] == 'SAFETY' ||
          json['promptFeedback']?['blockReason'] != null,
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
