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

      // Total prompt tokens should include cache tokens
      // (same logic as streaming: input + cacheRead + cacheCreation)
      expect(result.usage?.promptTokens, 600); // 100 + 200 + 300
      expect(result.usage?.completionTokens, 50);
      expect(result.usage?.totalTokens, 650); // 600 + 50

      // Cache read tokens should be reported in promptTokensDetails
      expect(result.usage?.promptTokensDetails, isNotNull);
      expect(result.usage?.promptTokensDetails?.cachedTokens, 200);
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

      expect(result.usage?.promptTokens, 100);
      expect(result.usage?.completionTokens, 50);
      expect(result.usage?.totalTokens, 150);
      // No cache read tokens, so promptTokensDetails should be null
      expect(result.usage?.promptTokensDetails, isNull);
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

      expect(result.usage?.promptTokens, 200); // 50 + 150 + 0
      expect(result.usage?.totalTokens, 230); // 200 + 30
      expect(result.usage?.promptTokensDetails?.cachedTokens, 150);
    });
  });
}
