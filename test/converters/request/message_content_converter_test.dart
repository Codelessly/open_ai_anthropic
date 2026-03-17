import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';
import 'package:test/test.dart';

import 'package:open_ai_anthropic/src/converters/request/chat_completion_request_converter.dart';
import 'package:open_ai_anthropic/src/converters/request/message_content_converter.dart';
import 'package:open_ai_anthropic/src/converters/response/chat_completion_response_converter.dart';

void main() {
  late MessageContentConverter converter;

  setUp(() {
    converter = MessageContentConverter();
  });

  // =========================================================================
  // #16 — Orphaned tool calls get synthetic error results
  // =========================================================================
  group('orphaned tool calls (#16)', () {
    test('inserts synthetic error tool result when tool call has no result', () {
      // Assistant makes a tool call but conversation ends without a tool result.
      // Anthropic API rejects this. pi-mono inserts a synthetic error result.
      final messages = <ChatMessage>[
        ChatMessage.user('Do something'),
        ChatMessage.assistant(
          toolCalls: [
            ToolCall(
              id: 'call_orphan',
              type: 'function',
              function: FunctionCall(name: 'my_tool', arguments: '{}'),
            ),
          ],
        ),
        // No ToolMessage for call_orphan — it's orphaned
        ChatMessage.user('Never mind, do something else'),
      ];

      final result = converter.convertMessages(messages);

      // Should have: user, assistant, tool_result(synthetic), user
      // The synthetic tool result should be a user message with tool_result block
      expect(result.length, 4,
          reason: 'Should insert synthetic tool result for orphaned call');

      // The third message should be the synthetic tool result
      final syntheticMsg = result[2];
      expect(syntheticMsg.role, anthropic.MessageRole.user);
      switch (syntheticMsg.content) {
        case anthropic.BlocksMessageContent(:final blocks):
          expect(blocks.length, 1);
          final block = blocks.first;
          expect(block, isA<anthropic.ToolResultInputBlock>());
        default:
          fail('Expected BlocksMessageContent with tool_result');
      }
    });

    test('inserts synthetic results for multiple orphaned tool calls', () {
      final messages = <ChatMessage>[
        ChatMessage.user('Do two things'),
        ChatMessage.assistant(
          toolCalls: [
            ToolCall(id: 'call_1', type: 'function', function: FunctionCall(name: 'tool_a', arguments: '{}')),
            ToolCall(id: 'call_2', type: 'function', function: FunctionCall(name: 'tool_b', arguments: '{}')),
          ],
        ),
        // Only one tool result — call_2 is orphaned
        ChatMessage.tool(toolCallId: 'call_1', content: 'result_1'),
      ];

      final result = converter.convertMessages(messages);

      // Should have synthetic result for call_2
      final allToolResults = <String>[];
      for (final msg in result) {
        if (msg.role == anthropic.MessageRole.user) {
          switch (msg.content) {
            case anthropic.BlocksMessageContent(:final blocks):
              for (final block in blocks) {
                if (block is anthropic.ToolResultInputBlock) {
                  allToolResults.add(block.toolUseId);
                }
              }
            default:
              break;
          }
        }
      }

      expect(allToolResults, contains('call_1'));
      expect(allToolResults, contains('call_2'),
          reason: 'Should have synthetic result for orphaned call_2');
    });

    test('does not insert synthetic results when all tool calls have results', () {
      final messages = <ChatMessage>[
        ChatMessage.user('Do something'),
        ChatMessage.assistant(
          toolCalls: [
            ToolCall(id: 'call_1', type: 'function', function: FunctionCall(name: 'tool_a', arguments: '{}')),
          ],
        ),
        ChatMessage.tool(toolCallId: 'call_1', content: 'done'),
      ];

      final result = converter.convertMessages(messages);

      // Should have: user, assistant, tool_result — no synthetic
      expect(result.length, 3);
    });
  });

  // =========================================================================
  // #13 — Empty text block filtering
  // =========================================================================
  group('empty text filtering (#13)', () {
    test('filters whitespace-only assistant text content', () {
      final messages = <ChatMessage>[
        ChatMessage.user('Hello'),
        ChatMessage.assistant(content: '   '),
        ChatMessage.user('World'),
      ];

      final result = converter.convertMessages(messages);

      // The whitespace-only assistant message should still be present
      // but with empty content, not whitespace
      for (final msg in result) {
        if (msg.role == anthropic.MessageRole.assistant) {
          switch (msg.content) {
            case anthropic.TextMessageContent(:final text):
              expect(text.trim().isEmpty, isTrue,
                  reason: 'Whitespace-only text should be filtered to empty');
            case anthropic.BlocksMessageContent(:final blocks):
              for (final block in blocks) {
                if (block is anthropic.TextInputBlock) {
                  expect(block.text.trim().isEmpty, isFalse,
                      reason: 'Should not have whitespace-only text blocks');
                }
              }
          }
        }
      }
    });

    test('skips empty user messages', () {
      final messages = <ChatMessage>[
        ChatMessage.user(''),
        ChatMessage.user('Hello'),
      ];

      final result = converter.convertMessages(messages);

      // Empty user message should be skipped
      expect(result.length, 1,
          reason: 'Empty user message should be filtered out');
    });
  });

  // =========================================================================
  // #20 — Tool call ID normalization in messages
  // =========================================================================
  group('tool call ID normalization (#10)', () {
    test('normalizes tool call IDs with invalid characters', () {
      final messages = <ChatMessage>[
        ChatMessage.user('Do something'),
        ChatMessage.assistant(
          toolCalls: [
            ToolCall(
              id: 'call|with|pipes',
              type: 'function',
              function: FunctionCall(name: 'my_tool', arguments: '{}'),
            ),
          ],
        ),
        ChatMessage.tool(toolCallId: 'call|with|pipes', content: 'done'),
      ];

      final result = converter.convertMessages(messages);

      // Find the tool_use block in the assistant message
      final assistantMsg = result.firstWhere((m) => m.role == anthropic.MessageRole.assistant);
      switch (assistantMsg.content) {
        case anthropic.BlocksMessageContent(:final blocks):
          final toolUse = blocks.whereType<anthropic.ToolUseInputBlock>().first;
          expect(toolUse.id, isNot(contains('|')),
              reason: 'Pipes should be normalized out of tool call IDs');
          expect(toolUse.id, matches(RegExp(r'^[a-zA-Z0-9_-]+$')),
              reason: 'ID should only contain valid characters');
        default:
          fail('Expected blocks content with tool_use');
      }

      // Find the tool_result block — should use the same normalized ID
      final toolResultMsg = result.last;
      switch (toolResultMsg.content) {
        case anthropic.BlocksMessageContent(:final blocks):
          final toolResult = blocks.whereType<anthropic.ToolResultInputBlock>().first;
          expect(toolResult.toolUseId, isNot(contains('|')),
              reason: 'Tool result ID should also be normalized');
        default:
          fail('Expected blocks content with tool_result');
      }
    });
  });

  // =========================================================================
  // #20 — Reverse tool name remapping in responses
  // =========================================================================
  group('reverse tool name remapping (#20)', () {
    test('response converter remaps CC tool names back to original', () {
      final responseConverter = ChatCompletionResponseConverter();

      // Simulate Anthropic returning CC-canonical tool name "Bash"
      // when the original tool was "bash"
      final message = anthropic.Message(
        id: 'msg_1',
        type: 'message',
        role: anthropic.MessageRole.assistant,
        content: [
          anthropic.ToolUseBlock(
            id: 'toolu_1',
            name: 'Bash', // CC canonical name
            input: {'command': 'ls'},
          ),
        ],
        model: 'claude-sonnet-4-6',
        stopReason: anthropic.StopReason.toolUse,
        usage: anthropic.Usage(inputTokens: 10, outputTokens: 5),
      );

      final result = responseConverter.convert(
        message,
        'claude-sonnet-4-6',
        isOAuth: true,
        originalToolNames: ['bash', 'read_files'],
      );

      final toolCalls = result.completion.choices.first.message.toolCalls;
      expect(toolCalls, isNotNull);
      expect(toolCalls!.first.function.name, 'bash',
          reason: 'Should remap CC name "Bash" back to original "bash"');
    });

    test('response converter passes through non-CC tool names unchanged', () {
      final responseConverter = ChatCompletionResponseConverter();

      final message = anthropic.Message(
        id: 'msg_2',
        type: 'message',
        role: anthropic.MessageRole.assistant,
        content: [
          anthropic.ToolUseBlock(
            id: 'toolu_2',
            name: 'lookup_capital', // Not a CC tool name
            input: {'country': 'France'},
          ),
        ],
        model: 'claude-sonnet-4-6',
        stopReason: anthropic.StopReason.toolUse,
        usage: anthropic.Usage(inputTokens: 10, outputTokens: 5),
      );

      final result = responseConverter.convert(
        message,
        'claude-sonnet-4-6',
        isOAuth: true,
        originalToolNames: ['lookup_capital'],
      );

      final toolCalls = result.completion.choices.first.message.toolCalls;
      expect(toolCalls!.first.function.name, 'lookup_capital');
    });
  });

  // =========================================================================
  // #21 — Metadata user_id forwarding
  // =========================================================================
  group('metadata user_id forwarding (#21)', () {
    test('forwards metadata user_id to Anthropic request', () {
      final requestConverter = ChatCompletionRequestConverter();

      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
        user: 'user-123',
      );

      final result = requestConverter.convert(request, isOAuth: true);
      final json = result.toJson();

      expect(json['metadata'], isNotNull,
          reason: 'Should forward user as metadata.user_id');
      expect((json['metadata'] as Map)['user_id'], 'user-123');
    });
  });

  // =========================================================================
  // #22 — Image-only content gets text placeholder
  // =========================================================================
  group('image-only content placeholder (#22)', () {
    test('prepends text placeholder when user message has only images', () {
      final messages = <ChatMessage>[
        ChatMessage.user(
          UserMessageContent.parts([
            ContentPart.imageUrl('https://example.com/image.png'),
          ]),
        ),
      ];

      final result = converter.convertMessages(messages);

      final userMsg = result.first;
      switch (userMsg.content) {
        case anthropic.BlocksMessageContent(:final blocks):
          // Should have a text block prepended before the image
          final hasText = blocks.any((b) => b is anthropic.TextInputBlock);
          expect(hasText, isTrue,
              reason: 'Image-only content should have a text placeholder prepended');
        default:
          fail('Expected BlocksMessageContent');
      }
    });

    test('does NOT prepend placeholder when user message has text and images', () {
      final messages = <ChatMessage>[
        ChatMessage.user(
          UserMessageContent.parts([
            ContentPart.text('Look at this'),
            ContentPart.imageUrl('https://example.com/image.png'),
          ]),
        ),
      ];

      final result = converter.convertMessages(messages);

      final userMsg = result.first;
      switch (userMsg.content) {
        case anthropic.BlocksMessageContent(:final blocks):
          final textBlocks = blocks.whereType<anthropic.TextInputBlock>().toList();
          expect(textBlocks.length, 1,
              reason: 'Should not add extra placeholder when text already exists');
          expect(textBlocks.first.text, 'Look at this');
        default:
          fail('Expected BlocksMessageContent');
      }
    });
  });
}
