import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';
import 'package:test/test.dart';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
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

    test('handles untyped maps from bodyTransformer without casting errors', () {
      // Reproduces production crash: bodyTransformer creates _Map<dynamic, dynamic>
      // via spread operators on toJson() output, which fromJson() rejects.
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-20250514',
        messages: [
          ChatMessage.system('You are helpful.'),
          ChatMessage.user('Hello'),
          ChatMessage.assistant(
            toolCalls: [
              ToolCall(
                id: 'call_1',
                type: 'function',
                function: FunctionCall(
                  name: 'read_files',
                  arguments: '{"paths":["lib"]}',
                ),
              ),
            ],
          ),
          ChatMessage.tool(toolCallId: 'call_1', content: 'file contents here'),
          ChatMessage.user('Now process that'),
        ],
        tools: [
          Tool.function(
            name: 'read_files',
            description: 'Read files',
            parameters: {'type': 'object', 'properties': {}},
          ),
        ],
      );

      // Simulate what addCacheBreakpointsAnthropic does in production:
      // spreads existing maps (producing _Map<dynamic, dynamic>) and adds
      // nested maps that Dart infers as Map<dynamic, dynamic>.
      expect(
        () => converter.convert(
          request,
          bodyTransformer: (body) {
            // Cache system message — creates untyped nested map
            final system = body['system'];
            if (system is String) {
              body['system'] = <dynamic>[
                <dynamic, dynamic>{
                  'type': 'text',
                  'text': system,
                  'cache_control': <dynamic, dynamic>{'type': 'ephemeral'},
                },
              ];
            }

            // Cache last user message — uses spread on existing map (produces untyped)
            final messages = body['messages'];
            if (messages is List) {
              for (int i = messages.length - 1; i >= 0; i--) {
                final msg = messages[i];
                if (msg is Map && msg['role'] == 'user') {
                  final content = msg['content'];
                  if (content is String) {
                    // This spread produces _Map<dynamic, dynamic> in real code
                    msg['content'] = <dynamic>[
                      <dynamic, dynamic>{
                        ...msg,
                        'type': 'text',
                        'text': content,
                        'cache_control': <dynamic, dynamic>{'type': 'ephemeral'},
                      },
                    ];
                  }
                  break;
                }
              }
            }
          },
        ),
        returnsNormally,
        reason: 'bodyTransformer with untyped maps should not throw cast errors',
      );
    });

    test('no bodyTransformer and CacheRetention.none yields plain-text system (non-OAuth)', () {
      // Sanity check that bodyTransformer mutations are opt-in. Cache control
      // is also opt-out via CacheRetention.none — pass it explicitly so this
      // test exercises the pure pass-through path with no auto-injection.
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-20250514',
        messages: [
          ChatMessage.system('You are helpful.'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(request, cacheRetention: CacheRetention.none);

      expect(result.system, isA<anthropic.TextSystemPrompt>());
    });
  });

  group('OAuth mode (isOAuth)', () {
    test('prepends Claude Code identity to system prompt', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          ChatMessage.system('You are helpful.'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(request, isOAuth: true);

      expect(result.system, isA<anthropic.BlocksSystemPrompt>());
      final blocks = (result.system! as anthropic.BlocksSystemPrompt).blocks;
      expect(blocks.length, greaterThanOrEqualTo(2));
      expect(blocks.first.text, contains('Claude Code'));
      expect(blocks.last.text, 'You are helpful.');
      // Both should have cache_control
      for (final block in blocks) {
        expect(block.cacheControl, isNotNull);
      }
    });

    test('adds Claude Code identity even without user system prompt', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
      );

      final result = converter.convert(request, isOAuth: true);

      expect(result.system, isA<anthropic.BlocksSystemPrompt>());
      final blocks = (result.system! as anthropic.BlocksSystemPrompt).blocks;
      expect(blocks, hasLength(1));
      expect(blocks.first.text, contains('Claude Code'));
    });

    test('does NOT add Claude Code identity when isOAuth is false', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          ChatMessage.system('You are helpful.'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(request, isOAuth: false);

      // The system prompt must carry only the user-provided text, never the
      // Claude Code identity prefix. The container type (TextSystemPrompt vs
      // BlocksSystemPrompt) is an implementation detail driven by whether
      // cache_control is being attached — assert the textual content directly.
      final system = result.system!;
      final systemText = switch (system) {
        anthropic.TextSystemPrompt(:final text) => text,
        anthropic.BlocksSystemPrompt(:final blocks) => blocks.map((b) => b.text).join('\n'),
      };
      expect(systemText, equals('You are helpful.'));
      expect(systemText, isNot(contains('Claude Code')));
    });

    test('sets adaptive thinking for sonnet-4-6', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
      );

      final result = converter.convert(request, isOAuth: true);
      final json = result.toJson();
      expect(json['thinking'], isNotNull);
      expect((json['thinking'] as Map)['type'], 'adaptive');
    });

    test('sets adaptive thinking for opus-4-6', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-opus-4-6',
        messages: [ChatMessage.user('Hello')],
      );

      final result = converter.convert(request, isOAuth: true);
      final json = result.toJson();
      expect(json['thinking'], isNotNull);
      expect((json['thinking'] as Map)['type'], 'adaptive');
    });

    test('does NOT set thinking for non-4.6 models', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-haiku-4-5-20251001',
        messages: [ChatMessage.user('Hello')],
      );

      final result = converter.convert(request, isOAuth: true);
      final json = result.toJson();
      expect(json.containsKey('thinking'), isFalse);
    });

    test('does NOT set thinking when isOAuth is false', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
      );

      final result = converter.convert(request, isOAuth: false);
      final json = result.toJson();
      expect(json.containsKey('thinking'), isFalse);
    });

    test('strips temperature when thinking is active', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
        temperature: 0.7,
      );

      final result = converter.convert(request, isOAuth: true);
      expect(result.temperature, isNull);
    });

    test('keeps temperature for non-thinking models in OAuth', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-haiku-4-5-20251001',
        messages: [ChatMessage.user('Hello')],
        temperature: 0.7,
      );

      final result = converter.convert(request, isOAuth: true);
      expect(result.temperature, 0.7);
    });

    test('remaps tool names to CC canonical', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
        tools: [
          Tool.function(
            name: 'bash',
            description: 'Run command',
            parameters: {'type': 'object', 'properties': {}},
          ),
          Tool.function(
            name: 'my_custom_tool',
            description: 'Custom',
            parameters: {'type': 'object', 'properties': {}},
          ),
        ],
      );

      final result = converter.convert(request, isOAuth: true);
      final tool0 = result.tools![0] as anthropic.CustomToolDefinition;
      final tool1 = result.tools![1] as anthropic.CustomToolDefinition;
      expect(tool0.tool.name, 'Bash'); // Remapped
      expect(tool1.tool.name, 'my_custom_tool'); // Unknown, unchanged
    });

    test('applies cache_control to last message (user)', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          ChatMessage.user('First'),
          ChatMessage.assistant(content: 'Response'),
          ChatMessage.user('Second'),
        ],
      );

      final result = converter.convert(request, isOAuth: true);
      final json = result.toJson();
      final messages = json['messages'] as List;
      final lastMsg = messages.last as Map;
      expect(lastMsg['role'], equals('user'));
      final content = lastMsg['content'];
      if (content is List && content.isNotEmpty) {
        final lastBlock = content.last as Map;
        expect(lastBlock.containsKey('cache_control'), isTrue);
      } else {
        fail('Last message should have blocks format with cache_control');
      }
    });

    test('applies cache_control to last message (assistant)', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          ChatMessage.user('Hello'),
          ChatMessage.assistant(content: 'Response with tool calls'),
        ],
      );

      final result = converter.convert(request, isOAuth: true);
      final json = result.toJson();
      final messages = json['messages'] as List;
      final lastMsg = messages.last as Map;
      expect(lastMsg['role'], equals('assistant'));
      final content = lastMsg['content'];
      if (content is List && content.isNotEmpty) {
        final lastBlock = content.last as Map;
        expect(lastBlock.containsKey('cache_control'), isTrue);
      } else if (content is String) {
        // String content gets converted to blocks format with cache_control
        fail('Last message should have blocks format with cache_control');
      }
    });

    test('uses higher default max_tokens', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
        // No maxTokens set — should use a higher default
      );

      final result = converter.convert(request, isOAuth: true);
      expect(result.maxTokens, greaterThan(4096));
    });

    test('cache_control on last user message survives untyped map content from toJson', () {
      // Reproduces production crash: toJson() produces content blocks as
      // _Map<dynamic, dynamic>. The OAuth cache breakpoint injection spreads
      // these maps, producing another _Map<dynamic, dynamic> which crashes
      // when assigned back into the List.
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          ChatMessage.system('System prompt.'),
          ChatMessage.user(
            UserMessageContent.parts([
              ContentPart.text('Part 1'),
              ContentPart.text('Part 2'),
            ]),
          ),
        ],
      );

      // This must not throw _Map<dynamic, dynamic> type cast errors
      expect(
        () => converter.convert(request, isOAuth: true),
        returnsNormally,
        reason: 'OAuth cache_control injection on multi-part user message must not throw',
      );
    });
  });

  // =========================================================================
  // Direct API key path (isOAuth: false) — cache_control injection.
  //
  // Anthropic's prompt caching API works identically with x-api-key and OAuth
  // Bearer authentication; no beta header is required. The converter must
  // therefore inject cache_control breakpoints on the system prompt and the
  // last message regardless of auth mode, gated solely on cacheRetention.
  //
  // The OAuth-specific layer (Claude Code identity prefix, adaptive thinking,
  // effort defaults, tool-name remap) remains gated on isOAuth.
  //
  // Reference: https://platform.claude.com/docs/en/build-with-claude/prompt-caching
  //   "Prompt caching is enabled by including cache_control parameters [...]
  //    no beta header is needed; the same syntax works with API keys and OAuth."
  // =========================================================================
  group('Direct API path cache_control (isOAuth: false)', () {
    test('injects cache_control on system prompt block (CacheRetention.short)', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-haiku-4-5-20251001',
        messages: [
          ChatMessage.system('You are a helpful assistant. ' * 200),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(
        request,
        isOAuth: false,
        cacheRetention: CacheRetention.short,
      );
      final json = result.toJson();

      // Direct API path must emit `system` as blocks (not a string) so the
      // cache_control marker can attach to the block.
      final system = json['system'];
      expect(
        system,
        isA<List<dynamic>>(),
        reason: 'system must be a blocks list, not a string, when cache_control is being injected',
      );
      final blocks = system as List;
      expect(
        blocks,
        hasLength(1),
        reason: 'Non-OAuth path has no Claude Code identity prefix, so exactly one system block',
      );
      final block = blocks.first as Map;
      expect(block['cache_control'], isNotNull, reason: 'System block must carry cache_control on direct API path');
      expect((block['cache_control'] as Map)['type'], equals('ephemeral'));
      expect(block['text'], contains('You are a helpful assistant.'));
      // Non-OAuth path must NOT prepend Claude Code identity.
      expect(block['text'], isNot(contains('Claude Code')));
    });

    test('injects cache_control on last user message (CacheRetention.short)', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-haiku-4-5-20251001',
        messages: [
          ChatMessage.system('You are a helpful assistant. ' * 200),
          ChatMessage.user('First turn user message'),
          ChatMessage.assistant(content: 'First turn assistant response'),
          ChatMessage.user('Second turn user message'),
        ],
      );

      final result = converter.convert(
        request,
        isOAuth: false,
        cacheRetention: CacheRetention.short,
      );
      final json = result.toJson();

      final messages = json['messages'] as List;
      final lastMsg = messages.last as Map;
      expect(lastMsg['role'], equals('user'));
      final content = lastMsg['content'];
      expect(
        content,
        isA<List<dynamic>>(),
        reason: 'Last message content must be wrapped in blocks so cache_control can attach',
      );
      final blocks = content as List;
      expect(blocks, isNotEmpty);
      final lastBlock = blocks.last as Map;
      expect(
        lastBlock['cache_control'],
        isNotNull,
        reason: 'Last message must carry cache_control on direct API path',
      );
      expect((lastBlock['cache_control'] as Map)['type'], equals('ephemeral'));
    });

    test('CacheRetention.long applies ttl:1h on system block (direct API)', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-haiku-4-5-20251001',
        messages: [
          ChatMessage.system('System prompt'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(
        request,
        isOAuth: false,
        cacheRetention: CacheRetention.long,
      );
      final json = result.toJson();

      final system = json['system'] as List;
      final block = system.first as Map;
      final cc = block['cache_control'] as Map;
      expect(cc['type'], equals('ephemeral'));
      expect(cc['ttl'], equals('1h'));
    });

    test('CacheRetention.none injects no cache_control anywhere (direct API)', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-haiku-4-5-20251001',
        messages: [
          ChatMessage.system('System prompt'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(
        request,
        isOAuth: false,
        cacheRetention: CacheRetention.none,
      );
      final json = result.toJson();

      // System may be string OR blocks-without-cache; the only invariant is
      // that NOTHING carries cache_control.
      final encoded = json.toString();
      expect(
        encoded,
        isNot(contains('cache_control')),
        reason: 'CacheRetention.none must produce zero cache_control markers',
      );
    });

    test('does not adopt OAuth-only features (no Claude Code identity, no thinking)', () {
      // Regression guard: cache_control lift must not accidentally bring
      // along the Claude Code identity prefix or adaptive thinking block.
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          ChatMessage.system('Plain system'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(
        request,
        isOAuth: false,
        cacheRetention: CacheRetention.short,
      );
      final json = result.toJson();

      expect(
        json.containsKey('thinking'),
        isFalse,
        reason: 'Non-OAuth path must never inject adaptive thinking',
      );
      final system = json['system'];
      final systemText = system is String ? system : (system as List).map((b) => (b as Map)['text']).join('\n');
      expect(systemText, isNot(contains('Claude Code')));
    });

    test('omits cache_control entirely when no system prompt and no user content blocks to mark', () {
      // Edge case: an empty messages list with no system prompt should not
      // crash and should not produce stray cache_control markers.
      final request = ChatCompletionCreateRequest(
        model: 'claude-haiku-4-5-20251001',
        messages: [ChatMessage.user('Hello')],
      );

      final result = converter.convert(
        request,
        isOAuth: false,
        cacheRetention: CacheRetention.short,
      );
      final json = result.toJson();

      // No system means we cannot attach a cache_control there — that's fine.
      // The last user message SHOULD still carry one (it's a valid breakpoint).
      final messages = json['messages'] as List;
      final lastMsg = messages.last as Map;
      final content = lastMsg['content'];
      if (content is List && content.isNotEmpty) {
        final lastBlock = content.last as Map;
        expect(
          lastBlock['cache_control'],
          isNotNull,
          reason: 'Last user message should be cache-marked even without a system prompt',
        );
      } else {
        fail('Expected last message content to be wrapped in blocks');
      }
    });
  });

  // =========================================================================
  // #15 — Conditional interleaved-thinking beta header
  // #19 — API key client beta headers
  // #9  — Cache TTL for long retention
  // =========================================================================
  group('Beta headers (#15, #19)', () {
    test('ClaudeCodeOpenAIClient beta string omits interleaved-thinking for 4.6 models', () {
      // pi-mono skips interleaved-thinking-2025-05-14 for adaptive thinking models
      // because it's deprecated on 4.6 and redundant (adaptive auto-enables it).
      final beta = ClaudeCodeOpenAIClient.buildBetaHeader('claude-sonnet-4-6');
      expect(
        beta,
        isNot(contains('interleaved-thinking')),
        reason: '4.6 models should not have interleaved-thinking beta',
      );
      expect(beta, contains('oauth-2025-04-20'));
      expect(beta, contains('claude-code-20250219'));
      expect(beta, contains('fine-grained-tool-streaming'));
    });

    test('ClaudeCodeOpenAIClient beta string includes interleaved-thinking for older models', () {
      final beta = ClaudeCodeOpenAIClient.buildBetaHeader('claude-sonnet-4-5-20250929');
      expect(beta, contains('interleaved-thinking-2025-05-14'), reason: 'Older models need interleaved-thinking beta');
      expect(beta, contains('oauth-2025-04-20'));
      expect(beta, contains('claude-code-20250219'));
    });
  });

  group('Cache TTL (#9)', () {
    test('long cache retention adds ttl to cache_control', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          ChatMessage.system('You are helpful.'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(
        request,
        isOAuth: true,
        cacheRetention: CacheRetention.long,
      );
      final json = result.toJson();

      // System prompt blocks should have ttl: "1h"
      final system = json['system'] as List;
      final firstBlock = system.first as Map;
      final cc = firstBlock['cache_control'] as Map;
      expect(cc['ttl'], '1h', reason: 'Long retention should add ttl: "1h" to cache_control');
    });

    test('short cache retention has no ttl', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          ChatMessage.system('You are helpful.'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(
        request,
        isOAuth: true,
        cacheRetention: CacheRetention.short,
      );
      final json = result.toJson();

      final system = json['system'] as List;
      final firstBlock = system.first as Map;
      final cc = firstBlock['cache_control'] as Map;
      expect(cc.containsKey('ttl'), isFalse, reason: 'Short retention should not have ttl');
    });

    test('none cache retention skips cache_control entirely', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          ChatMessage.system('You are helpful.'),
          ChatMessage.user('Hello'),
        ],
      );

      final result = converter.convert(
        request,
        isOAuth: true,
        cacheRetention: CacheRetention.none,
      );
      final json = result.toJson();

      // System should still have CC identity but blocks should NOT have cache_control
      final system = json['system'] as List;
      final firstBlock = system.first as Map;
      expect(firstBlock.containsKey('cache_control'), isFalse, reason: 'CacheRetention.none should skip cache_control');
    });
  });

  // =========================================================================
  // JSON schema + thinking compatibility
  //
  // Anthropic API rejects requests that combine extended thinking with
  // any form of forced tool choice (tool_choice: tool OR any).
  // Only tool_choice: auto works with thinking.
  //
  // Since auto doesn't guarantee the model calls the JSON schema tool,
  // the converter disables thinking when JSON schema output is required,
  // keeping forced tool choice for deterministic structured output.
  // =========================================================================
  group('JSON schema + thinking compatibility', () {
    test('disables thinking when JSON schema is active (OAuth + 4.6 model + jsonSchema)', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
        responseFormat: ResponseFormat.jsonSchema(
          name: 'TestResponse',
          strict: false,
          schema: {
            'type': 'object',
            'properties': {
              'answer': {'type': 'string'},
            },
          },
        ),
      );

      final result = converter.convert(request, isOAuth: true);

      // Thinking must be disabled — incompatible with forced tool choice
      final json = result.toJson();
      expect(
        json.containsKey('thinking'),
        isFalse,
        reason: 'Thinking must be skipped when JSON schema forces tool choice',
      );

      // Should have the JSON schema tool
      expect(result.tools, isNotNull);
      final toolNames = result.tools!.map((t) {
        if (t is anthropic.CustomToolDefinition) return t.tool.name;
        return null;
      }).toList();
      expect(toolNames, contains(jsonSchemaToolName));

      // tool_choice should be forced to the specific tool (deterministic)
      expect(result.toolChoice, isA<anthropic.ToolChoiceTool>());
    });

    test('keeps toolChoice "tool" when thinking is NOT active (non-OAuth + jsonSchema)', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
        responseFormat: ResponseFormat.jsonSchema(
          name: 'TestResponse',
          strict: false,
          schema: {
            'type': 'object',
            'properties': {
              'answer': {'type': 'string'},
            },
          },
        ),
      );

      final result = converter.convert(request, isOAuth: false);

      // No thinking
      final json = result.toJson();
      expect(json.containsKey('thinking'), isFalse);

      // tool_choice should be forced to the specific tool (more deterministic)
      expect(result.toolChoice, isA<anthropic.ToolChoiceTool>());
    });

    test('keeps toolChoice "tool" when thinking is NOT active (non-4.6 model + OAuth + jsonSchema)', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-haiku-4-5-20251001',
        messages: [ChatMessage.user('Hello')],
        responseFormat: ResponseFormat.jsonSchema(
          name: 'TestResponse',
          strict: false,
          schema: {
            'type': 'object',
            'properties': {
              'answer': {'type': 'string'},
            },
          },
        ),
      );

      final result = converter.convert(request, isOAuth: true);

      // No thinking for non-4.6 model
      final json = result.toJson();
      expect(json.containsKey('thinking'), isFalse);

      // tool_choice should remain forced to specific tool
      expect(result.toolChoice, isA<anthropic.ToolChoiceTool>());
    });

    test('disables thinking for opus-4-6 with jsonSchema in OAuth', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-opus-4-6',
        messages: [ChatMessage.user('Hello')],
        responseFormat: ResponseFormat.jsonSchema(
          name: 'TestResponse',
          strict: false,
          schema: {
            'type': 'object',
            'properties': {
              'answer': {'type': 'string'},
            },
          },
        ),
      );

      final result = converter.convert(request, isOAuth: true);

      // Thinking must be disabled for JSON schema
      final json = result.toJson();
      expect(json.containsKey('thinking'), isFalse);

      // tool_choice forced to specific tool
      expect(result.toolChoice, isA<anthropic.ToolChoiceTool>());
    });

    test('still enables thinking for 4.6 OAuth WITHOUT jsonSchema', () {
      final request = ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [ChatMessage.user('Hello')],
      );

      final result = converter.convert(request, isOAuth: true);

      // Thinking should be active when no JSON schema
      final json = result.toJson();
      expect(json['thinking'], isNotNull);
      expect((json['thinking'] as Map)['type'], 'adaptive');
    });

    // Regression: explicit `thinking` injected via bodyTransformer
    // (e.g. from `AnthropicReasoningConfig(thinkingMode: enabled, ...)`
    // flowing through `extraBody['thinking']`) must ALSO be stripped when
    // JSON schema structured output is active — otherwise Anthropic 400s:
    //   "Thinking may not be enabled when tool_choice forces tool use."
    test(
      'strips explicit thinking (bodyTransformer-injected) when jsonSchema is active — OAuth path',
      () {
        final request = ChatCompletionCreateRequest(
          model: 'claude-sonnet-4-6',
          messages: [
            ChatMessage.system('You are helpful.'),
            ChatMessage.user('Hello'),
          ],
          responseFormat: ResponseFormat.jsonSchema(
            name: 'TestResponse',
            strict: false,
            schema: {
              'type': 'object',
              'properties': {
                'answer': {'type': 'string'},
              },
            },
          ),
        );

        final result = converter.convert(
          request,
          isOAuth: true,
          // Simulates `_AnthropicRequestOverrides.applyToBody` writing
          // explicit `thinking` (from `AnthropicReasoningConfig`) and
          // `output_config` (from `effort`) into the body.
          bodyTransformer: (body) {
            body['thinking'] = {'type': 'enabled', 'budget_tokens': 10240};
            body['output_config'] = {'effort': 'medium'};
          },
        );

        final json = result.toJson();
        expect(
          json.containsKey('thinking'),
          isFalse,
          reason:
              'Explicit thinking from bodyTransformer must be stripped when JSON schema forces tool choice',
        );
        expect(
          json.containsKey('output_config'),
          isFalse,
          reason:
              'output_config (effort) must be stripped alongside thinking when JSON schema forces tool choice',
        );

        // System prompt must still be preserved (Claude Code identity + user system block).
        expect(result.system, isNotNull);

        // Forced tool_choice (the JSON schema tool) must still be set.
        expect(result.toolChoice, isA<anthropic.ToolChoiceTool>());

        // The JSON schema tool must still be present.
        final toolNames = result.tools!.map((t) {
          if (t is anthropic.CustomToolDefinition) return t.tool.name;
          return null;
        }).toList();
        expect(toolNames, contains(jsonSchemaToolName));
      },
    );

    test(
      'strips explicit thinking (bodyTransformer-injected) when jsonSchema is active — direct-API path',
      () {
        final request = ChatCompletionCreateRequest(
          model: 'claude-sonnet-4-6',
          messages: [ChatMessage.user('Hello')],
          responseFormat: ResponseFormat.jsonSchema(
            name: 'TestResponse',
            strict: false,
            schema: {
              'type': 'object',
              'properties': {
                'answer': {'type': 'string'},
              },
            },
          ),
        );

        final result = converter.convert(
          request,
          isOAuth: false,
          bodyTransformer: (body) {
            body['thinking'] = {'type': 'enabled', 'budget_tokens': 10240};
          },
        );

        final json = result.toJson();
        expect(
          json.containsKey('thinking'),
          isFalse,
          reason:
              'Explicit thinking must be stripped in direct-API (x-api-key) path too',
        );
        expect(result.toolChoice, isA<anthropic.ToolChoiceTool>());
      },
    );

    test(
      'preserves explicit thinking (bodyTransformer-injected) when jsonSchema is NOT active',
      () {
        // Sanity check: the strip only fires when JSON schema is in play.
        final request = ChatCompletionCreateRequest(
          model: 'claude-haiku-4-5-20251001',
          messages: [ChatMessage.user('Hello')],
        );

        final result = converter.convert(
          request,
          isOAuth: false,
          bodyTransformer: (body) {
            body['thinking'] = {'type': 'enabled', 'budget_tokens': 4096};
            body['output_config'] = {'effort': 'high'};
          },
        );

        final json = result.toJson();
        expect(json['thinking'], isNotNull);
        expect((json['thinking'] as Map)['type'], 'enabled');
        expect((json['thinking'] as Map)['budget_tokens'], 4096);
        expect(json['output_config'], isNotNull);
        expect((json['output_config'] as Map)['effort'], 'high');
      },
    );
  });
}
