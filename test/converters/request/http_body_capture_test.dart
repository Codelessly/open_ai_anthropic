/// Captures the actual HTTP request body that would be sent to
/// api.anthropic.com by ClaudeCodeClient on first vs recurring calls.
///
/// Uses a mock HTTP client to intercept the body before it leaves the process.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openai_dart/openai_dart.dart';
import 'package:test/test.dart';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';

void main() {
  group('HTTP body sent to Anthropic API', () {
    Future<Map<String, dynamic>> captureRequestBody({
      required void Function(Map<String, dynamic> body)? bodyTransformer,
    }) async {
      final completer = Completer<Map<String, dynamic>>();

      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        completer.complete(body);
        return http.Response('{"error": "test"}', 400);
      });

      final client = AnthropicOpenAIClient(
        apiKey: 'test-key',
        isOAuth: true,
        client: mockClient,
        bodyTransformer: bodyTransformer,
      );

      try {
        final stream = client.chat.completions.createStream(
          ChatCompletionCreateRequest(
            model: 'claude-sonnet-4-6',
            messages: [
              ChatMessage.user('Create a simple retro minesweeper game.'),
            ],
          ),
        );
        await stream.drain().catchError((_) {});
      } catch (_) {}

      client.close();
      return completer.future.timeout(const Duration(seconds: 5));
    }

    test('FIRST CALL: HTTP body has thinking AND output_config', () async {
      final body = await captureRequestBody(
        bodyTransformer: (body) {
          body['thinking'] = {'type': 'adaptive'};
          body['output_config'] = {'effort': 'medium'};
        },
      );

      expect(body.containsKey('thinking'), isTrue);
      expect((body['thinking'] as Map)['type'], equals('adaptive'));

      expect(body.containsKey('output_config'), isTrue, reason: 'First call HTTP body MUST contain output_config');
      expect((body['output_config'] as Map)['effort'], equals('medium'));

      expect(body['max_tokens'], equals(16384));
      expect(body['stream'], isTrue);
    });

    test('RECURRING CALL (after fix): HTTP body has thinking AND output_config', () async {
      // After fix, applyReasoningConfig runs on recurring calls too, so
      // the bodyTransformer always gets the overrides.
      final body = await captureRequestBody(
        bodyTransformer: (body) {
          body['thinking'] = {'type': 'adaptive'};
          body['output_config'] = {'effort': 'medium'};
        },
      );

      expect(body.containsKey('thinking'), isTrue);
      expect((body['thinking'] as Map)['type'], equals('adaptive'));

      expect(
        body.containsKey('output_config'),
        isTrue,
        reason: 'Recurring call HTTP body MUST have output_config after fix',
      );
      expect((body['output_config'] as Map)['effort'], equals('medium'));
    });

    test('FORCED DISABLED: thinking=disabled reaches Anthropic', () async {
      final body = await captureRequestBody(
        bodyTransformer: (body) {
          body['thinking'] = {'type': 'disabled'};
        },
      );

      expect(body.containsKey('thinking'), isTrue);
      expect((body['thinking'] as Map)['type'], equals('disabled'));
    });

    test('FORCED LOW EFFORT: effort=low reaches Anthropic', () async {
      final body = await captureRequestBody(
        bodyTransformer: (body) {
          body['thinking'] = {'type': 'adaptive'};
          body['output_config'] = {'effort': 'low'};
        },
      );

      expect(body.containsKey('output_config'), isTrue);
      expect((body['output_config'] as Map)['effort'], equals('low'));
    });
  });
}
