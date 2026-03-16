import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:test/test.dart';

import 'package:open_ai_anthropic/src/converters/response/chat_completion_response_converter.dart';

void main() {
  late ChatCompletionResponseConverter converter;

  setUp(() {
    converter = ChatCompletionResponseConverter();
  });

  group('Cache token reporting in non-streaming response', () {
    test('reports cache read and creation tokens in usage', () {
      final message = anthropic.Message(
        id: 'msg_123',
        type: 'message',
        role: anthropic.MessageRole.assistant,
        content: [anthropic.TextBlock(text: 'Hello!')],
        model: 'claude-sonnet-4-20250514',
        stopReason: anthropic.StopReason.endTurn,
        usage: anthropic.Usage(
          inputTokens: 100,
          outputTokens: 50,
          cacheReadInputTokens: 200,
          cacheCreationInputTokens: 300,
        ),
      );

      final result = converter.convert(message, 'claude-sonnet-4-20250514');
      final completion = result.completion;

      // Total prompt tokens should include cache tokens
      // (same logic as streaming: input + cacheRead + cacheCreation)
      expect(completion.usage?.promptTokens, 600); // 100 + 200 + 300
      expect(completion.usage?.completionTokens, 50);
      expect(completion.usage?.totalTokens, 650); // 600 + 50

      // Cache read tokens should be reported in promptTokensDetails
      expect(completion.usage?.promptTokensDetails, isNotNull);
      expect(completion.usage?.promptTokensDetails?.cachedTokens, 200);
    });

    test('handles zero cache tokens gracefully', () {
      final message = anthropic.Message(
        id: 'msg_124',
        type: 'message',
        role: anthropic.MessageRole.assistant,
        content: [anthropic.TextBlock(text: 'Hello!')],
        model: 'claude-sonnet-4-20250514',
        stopReason: anthropic.StopReason.endTurn,
        usage: anthropic.Usage(
          inputTokens: 100,
          outputTokens: 50,
        ),
      );

      final result = converter.convert(message, 'claude-sonnet-4-20250514');
      final completion = result.completion;

      expect(completion.usage?.promptTokens, 100);
      expect(completion.usage?.completionTokens, 50);
      expect(completion.usage?.totalTokens, 150);
      // No cache read tokens, so promptTokensDetails should be null
      expect(completion.usage?.promptTokensDetails, isNull);
    });

    test('reports cache tokens when only cache read is present', () {
      final message = anthropic.Message(
        id: 'msg_125',
        type: 'message',
        role: anthropic.MessageRole.assistant,
        content: [anthropic.TextBlock(text: 'Hello!')],
        model: 'claude-sonnet-4-20250514',
        stopReason: anthropic.StopReason.endTurn,
        usage: anthropic.Usage(
          inputTokens: 50,
          outputTokens: 30,
          cacheReadInputTokens: 150,
        ),
      );

      final result = converter.convert(message, 'claude-sonnet-4-20250514');
      final completion = result.completion;

      expect(completion.usage?.promptTokens, 200); // 50 + 150 + 0
      expect(completion.usage?.totalTokens, 230); // 200 + 30
      expect(completion.usage?.promptTokensDetails?.cachedTokens, 150);
    });
  });

  group('Cache creation tokens in toJson output', () {
    test('includes cache_creation_input_tokens in usage JSON', () {
      final message = anthropic.Message(
        id: 'msg_200',
        type: 'message',
        role: anthropic.MessageRole.assistant,
        content: [anthropic.TextBlock(text: 'Hello!')],
        model: 'claude-sonnet-4-20250514',
        stopReason: anthropic.StopReason.endTurn,
        usage: anthropic.Usage(
          inputTokens: 100,
          outputTokens: 50,
          cacheCreationInputTokens: 500,
        ),
      );

      final result = converter.convert(message, 'claude-sonnet-4-20250514');
      final json = result.toJson();
      final usageJson = json['usage'] as Map<String, dynamic>;

      expect(usageJson['cache_creation_input_tokens'], 500);
    });

    test('includes cache_read_input_tokens in usage JSON', () {
      final message = anthropic.Message(
        id: 'msg_201',
        type: 'message',
        role: anthropic.MessageRole.assistant,
        content: [anthropic.TextBlock(text: 'Hello!')],
        model: 'claude-sonnet-4-20250514',
        stopReason: anthropic.StopReason.endTurn,
        usage: anthropic.Usage(
          inputTokens: 50,
          outputTokens: 30,
          cacheReadInputTokens: 200,
          cacheCreationInputTokens: 100,
        ),
      );

      final result = converter.convert(message, 'claude-sonnet-4-20250514');
      final json = result.toJson();
      final usageJson = json['usage'] as Map<String, dynamic>;

      expect(usageJson['cache_creation_input_tokens'], 100);
      expect(usageJson['cache_read_input_tokens'], 200);
    });

    test('omits cache fields from JSON when zero', () {
      final message = anthropic.Message(
        id: 'msg_202',
        type: 'message',
        role: anthropic.MessageRole.assistant,
        content: [anthropic.TextBlock(text: 'Hello!')],
        model: 'claude-sonnet-4-20250514',
        stopReason: anthropic.StopReason.endTurn,
        usage: anthropic.Usage(
          inputTokens: 100,
          outputTokens: 50,
        ),
      );

      final result = converter.convert(message, 'claude-sonnet-4-20250514');
      final json = result.toJson();
      final usageJson = json['usage'] as Map<String, dynamic>;

      expect(usageJson.containsKey('cache_creation_input_tokens'), isFalse);
      expect(usageJson.containsKey('cache_read_input_tokens'), isFalse);
    });
  });
}
