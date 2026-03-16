import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';
import 'package:test/test.dart';

import 'package:open_ai_anthropic/src/converters/request/chat_completion_request_converter.dart';

void main() {
  late ChatCompletionRequestConverter converter;

  setUp(() {
    converter = ChatCompletionRequestConverter();
  });

  group('bodyTransformer', () {
    test('applies bodyTransformer to converted request', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-20250514',
        messages: [
          ChatMessage.system('You are helpful.'),
          ChatMessage.user('Hello'),
        ],
      );

      // Simulate what addCacheBreakpointsAnthropic does:
      // mutate the body to add cache_control on the system message
      anthropic.MessageCreateRequest result = converter.convert(
        request,
        bodyTransformer: (body) {
          // The system field is a string — wrap it in blocks with cache_control
          final system = body['system'];
          if (system is String) {
            body['system'] = [
              {
                'type': 'text',
                'text': system,
                'cache_control': {'type': 'ephemeral'},
              },
            ];
          }
        },
      );

      // After bodyTransformer, system should be BlocksSystemPrompt with cache control
      expect(result.system, isA<anthropic.BlocksSystemPrompt>());
      final blocks = (result.system! as anthropic.BlocksSystemPrompt).blocks;
      expect(blocks, hasLength(1));
      expect(blocks.first.text, 'You are helpful.');
      expect(blocks.first.cacheControl, isNotNull);
    });

    test('bodyTransformer can add cache_control to messages', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-20250514',
        messages: [
          ChatMessage.user('Hello'),
        ],
      );

      anthropic.MessageCreateRequest result = converter.convert(
        request,
        bodyTransformer: (body) {
          final messages = body['messages'] as List;
          for (final msg in messages) {
            if (msg is Map && msg['role'] == 'user') {
              final content = msg['content'];
              if (content is String) {
                msg['content'] = [
                  {
                    'type': 'text',
                    'text': content,
                    'cache_control': {'type': 'ephemeral'},
                  },
                ];
              }
            }
          }
        },
      );

      // The last user message should now have cache control on its content block
      final lastMsg = result.messages.last;
      switch (lastMsg.content) {
        case anthropic.BlocksMessageContent(:final blocks):
          final textBlock = blocks.last as anthropic.TextInputBlock;
          expect(textBlock.cacheControl, isNotNull);
        default:
          fail('Expected BlocksMessageContent');
      }
    });

    test('bodyTransformer can add cache_control to tools', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-20250514',
        messages: [ChatMessage.user('Hello')],
        tools: [
          Tool.function(
            name: 'get_weather',
            description: 'Get the weather',
            parameters: {'type': 'object', 'properties': {}},
          ),
        ],
      );

      anthropic.MessageCreateRequest result = converter.convert(
        request,
        bodyTransformer: (body) {
          final tools = body['tools'] as List?;
          if (tools != null && tools.isNotEmpty) {
            final lastTool = tools.last as Map<String, dynamic>;
            lastTool['cache_control'] = {'type': 'ephemeral'};
          }
        },
      );

      final tool = result.tools!.first as anthropic.CustomToolDefinition;
      expect(tool.tool.cacheControl, isNotNull);
    });

    test('no bodyTransformer leaves request unchanged', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-20250514',
        messages: [
          ChatMessage.system('You are helpful.'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(request);

      // System is plain text, no cache control
      expect(result.system, isA<anthropic.TextSystemPrompt>());
    });
  });
}
