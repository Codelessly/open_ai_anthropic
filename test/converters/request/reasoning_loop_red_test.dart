/// Tests that verify the open_ai_anthropic converter correctly handles
/// thinking and output_config on both first and recurring calls.
///
/// These tests go through the ACTUAL converter pipeline used by ClaudeCodeClient.
library;

import 'package:openai_dart/openai_dart.dart';
import 'package:test/test.dart';

import 'package:open_ai_anthropic/src/converters/request/chat_completion_request_converter.dart';

void main() {
  late ChatCompletionRequestConverter converter;

  setUp(() {
    converter = ChatCompletionRequestConverter();
  });

  group('ClaudeCodeClient first call vs recurring call', () {
    final request = ChatCompletionCreateRequest(
      model: 'claude-sonnet-4-6',
      messages: [
        ChatMessage.user('Create a simple retro minesweeper game.'),
      ],
    );

    test('FIRST CALL: bodyTransformer injects both thinking and output_config',
        () {
      final result = converter.convert(
        request,
        isOAuth: true,
        bodyTransformer: (body) {
          body['thinking'] = {'type': 'adaptive'};
          body['output_config'] = {'effort': 'medium'};
        },
      );

      final json = result.toJson();

      expect(json.containsKey('thinking'), isTrue);
      expect((json['thinking'] as Map)['type'], equals('adaptive'));

      expect(json.containsKey('output_config'), isTrue,
          reason: 'First call MUST have output_config');
      expect((json['output_config'] as Map)['effort'], equals('medium'));

      expect(json['max_tokens'], equals(16384));
    });

    test(
        'RECURRING CALL (after fix): bodyTransformer re-injects both fields',
        () {
      // After the fix, applyReasoningConfig runs on every call, so the
      // bodyTransformer always receives overrides from extraBody.
      final result = converter.convert(
        request,
        isOAuth: true,
        bodyTransformer: (body) {
          // With the fix, recurring calls get the same overrides as the first
          body['thinking'] = {'type': 'adaptive'};
          body['output_config'] = {'effort': 'medium'};
        },
      );

      final json = result.toJson();

      expect(json.containsKey('thinking'), isTrue);
      expect((json['thinking'] as Map)['type'], equals('adaptive'));

      expect(json.containsKey('output_config'), isTrue,
          reason: 'Recurring call MUST have output_config after fix');
      expect((json['output_config'] as Map)['effort'], equals('medium'));
    });

    test('max_tokens=16384 with adaptive thinking', () {
      final result = converter.convert(
        request,
        isOAuth: true,
        bodyTransformer: (body) {
          body['thinking'] = {'type': 'adaptive'};
          body['output_config'] = {'effort': 'medium'};
        },
      );

      final json = result.toJson();
      expect(json['max_tokens'], equals(16384));
    });
  });

  group('Forcefully setting thinking effort', () {
    final request = ChatCompletionCreateRequest(
      model: 'claude-sonnet-4-6',
      messages: [
        ChatMessage.user('Create a simple retro minesweeper game.'),
      ],
    );

    test('effort=low via bodyTransformer reaches the final body', () {
      final result = converter.convert(
        request,
        isOAuth: true,
        bodyTransformer: (body) {
          body['thinking'] = {'type': 'adaptive'};
          body['output_config'] = {'effort': 'low'};
        },
      );

      final json = result.toJson();
      expect(json['output_config'], isNotNull);
      expect((json['output_config'] as Map)['effort'], equals('low'));
    });

    test('thinking=disabled via bodyTransformer eliminates ALL thinking', () {
      final result = converter.convert(
        request,
        isOAuth: true,
        bodyTransformer: (body) {
          body['thinking'] = {'type': 'disabled'};
        },
      );

      final json = result.toJson();
      expect((json['thinking'] as Map)['type'], equals('disabled'));
    });

    test('OAuth block does NOT override explicit thinking from bodyTransformer',
        () {
      final result = converter.convert(
        request,
        isOAuth: true,
        bodyTransformer: (body) {
          body['thinking'] = {'type': 'disabled'};
        },
      );

      final json = result.toJson();
      expect((json['thinking'] as Map)['type'], equals('disabled'));
    });
  });

  group('Temperature stripping with thinking', () {
    test('temperature is stripped when adaptive thinking is active', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
        temperature: 0.7,
      );

      final result = converter.convert(request, isOAuth: true);
      final json = result.toJson();

      expect(json.containsKey('temperature'), isFalse,
          reason: 'Temperature is incompatible with thinking');
    });
  });
}
