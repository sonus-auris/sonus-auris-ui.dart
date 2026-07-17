import 'dart:convert';

import 'package:audio_dashcam/src/services/llm/anthropic_llm_client.dart';
import 'package:audio_dashcam/src/services/llm/gemini_llm_client.dart';
import 'package:audio_dashcam/src/services/llm/llm_client.dart';
import 'package:audio_dashcam/src/services/llm/openai_llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('AnthropicLlmClient', () {
    test('sends Messages API shape and parses text + usage', () async {
      late http.Request captured;
      final client = AnthropicLlmClient(
        apiKey: 'sk-test',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'model': 'claude-opus-4-8',
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': 'Hello '},
                {'type': 'text', 'text': 'there'},
              ],
              'usage': {'input_tokens': 12, 'output_tokens': 5},
            }),
            200,
          );
        }),
      );

      final response = await client.complete(
        system: 'Be brief.',
        messages: const [LlmMessage.user('Hi')],
      );

      expect(captured.url.path, '/v1/messages');
      expect(captured.headers['x-api-key'], 'sk-test');
      expect(captured.headers['anthropic-version'], '2023-06-01');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['model'], 'claude-opus-4-8');
      expect(body['system'], 'Be brief.');
      expect(body.containsKey('fallbacks'), isFalse);
      expect(response.text, 'Hello there');
      expect(response.inputTokens, 12);
      expect(response.outputTokens, 5);
      expect(response.refused, isFalse);
    });

    test('Fable requests opt into server-side fallbacks', () async {
      late http.Request captured;
      final client = AnthropicLlmClient(
        apiKey: 'sk-test',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'model': 'claude-fable-5',
              'stop_reason': 'end_turn',
              'content': <Object>[],
            }),
            200,
          );
        }),
      );

      await client.complete(
        model: AnthropicLlmClient.fable,
        messages: const [LlmMessage.user('Hi')],
      );

      expect(
        captured.headers['anthropic-beta'],
        'server-side-fallback-2026-06-01',
      );
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['fallbacks'], [
        {'model': 'claude-opus-4-8'},
      ]);
    });

    test('flags refusals and surfaces API errors', () async {
      final refusing = AnthropicLlmClient(
        apiKey: 'k',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'model': 'claude-fable-5',
              'stop_reason': 'refusal',
              'content': <Object>[],
            }),
            200,
          );
        }),
      );
      final refusal = await refusing
          .complete(messages: const [LlmMessage.user('x')]);
      expect(refusal.refused, isTrue);

      final erroring = AnthropicLlmClient(
        apiKey: 'k',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'error': {'type': 'rate_limit_error', 'message': 'slow down'},
            }),
            429,
          );
        }),
      );
      await expectLater(
        erroring.complete(messages: const [LlmMessage.user('x')]),
        throwsA(
          isA<LlmException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.message, 'message', 'slow down'),
        ),
      );
    });
  });

  group('OpenAiLlmClient', () {
    test('sends chat/completions shape and parses the first choice', () async {
      late http.Request captured;
      final client = OpenAiLlmClient(
        apiKey: 'sk-oai',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'model': 'gpt-5.1',
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {'role': 'assistant', 'content': 'Bonjour'},
                },
              ],
              'usage': {'prompt_tokens': 8, 'completion_tokens': 2},
            }),
            200,
          );
        }),
      );

      final response = await client.complete(
        system: 'Answer in French.',
        messages: const [LlmMessage.user('Hello')],
      );

      expect(captured.url.path, '/v1/chat/completions');
      expect(captured.headers['authorization'], 'Bearer sk-oai');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final messages = body['messages'] as List;
      expect((messages.first as Map)['role'], 'system');
      expect(response.text, 'Bonjour');
      expect(response.inputTokens, 8);
      expect(response.outputTokens, 2);
    });
  });

  group('GeminiLlmClient', () {
    test('sends generateContent shape and joins candidate parts', () async {
      late http.Request captured;
      final client = GeminiLlmClient(
        apiKey: 'g-key',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'modelVersion': 'gemini-2.5-flash',
              'candidates': [
                {
                  'finishReason': 'STOP',
                  'content': {
                    'parts': [
                      {'text': 'Guten '},
                      {'text': 'Tag'},
                    ],
                  },
                },
              ],
              'usageMetadata': {
                'promptTokenCount': 4,
                'candidatesTokenCount': 2,
              },
            }),
            200,
          );
        }),
      );

      final response = await client.complete(
        system: 'Answer in German.',
        messages: const [
          LlmMessage.user('Hello'),
          LlmMessage.assistant('Hallo'),
          LlmMessage.user('Again'),
        ],
      );

      expect(
        captured.url.path,
        '/v1beta/models/gemini-2.5-flash:generateContent',
      );
      expect(captured.headers['x-goog-api-key'], 'g-key');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final contents = body['contents'] as List;
      expect((contents[1] as Map)['role'], 'model');
      expect(response.text, 'Guten Tag');
      expect(response.inputTokens, 4);
      expect(response.outputTokens, 2);
    });

    test('marks safety blocks as refused', () async {
      final client = GeminiLlmClient(
        apiKey: 'g-key',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'finishReason': 'SAFETY',
                  'content': {'parts': <Object>[]},
                },
              ],
            }),
            200,
          );
        }),
      );

      final response =
          await client.complete(messages: const [LlmMessage.user('x')]);
      expect(response.refused, isTrue);
      expect(response.text, isEmpty);
    });
  });
}
