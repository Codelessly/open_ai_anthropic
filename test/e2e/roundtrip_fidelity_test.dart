// Verifies tool-name + content fidelity through Anthropic round-trips.
// Runs once per available [AnthropicMode] (OAuth + direct API key).
import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:test/test.dart';

import 'test_modes.dart';

void main() {
  final modes = loadAvailableModes();
  final openAIKey = loadOpenAiApiKey();

  final tools = [
    oai.Tool.function(
      name: 'get_weather',
      description: 'Get the current weather for a location',
      parameters: {
        'type': 'object',
        'properties': {
          'location': {'type': 'string', 'description': 'City name'},
        },
        'required': ['location'],
      },
    ),
  ];

  for (final fixture in modes) {
    group(fixture.label, () {
      test(
        'Round-trip fidelity: non-streaming tool names match original definitions',
        () async {
          final client = fixture.buildClient();

          final response = await client.chat.completions.create(
            oai.ChatCompletionCreateRequest(
              model: 'claude-sonnet-4-6',
              messages: [
                oai.ChatMessage.user('What is the weather in Paris? Use the get_weather tool.'),
              ],
              tools: tools,
              toolChoice: oai.ToolChoice.auto(),
              maxCompletionTokens: 16000,
            ),
          );

          final msg = response.choices.first.message;
          print(
            '[${fixture.label}] Non-streaming tool call: ${msg.toolCalls?.map((t) => t.function.name).toList()}',
          );

          if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
            for (final tc in msg.toolCalls!) {
              expect(
                tc.function.name,
                'get_weather',
                reason:
                    '[${fixture.label}] Non-streaming: tool name must match '
                    'original definition, not CC canonical',
              );
            }
          }

          client.close();
        },
        timeout: Timeout(Duration(seconds: 60)),
      );

      test(
        'Round-trip fidelity: streaming tool names match original definitions',
        () async {
          final client = fixture.buildClient();

          String? streamedToolName;
          await for (final chunk in client.chat.completions.createStream(
            oai.ChatCompletionCreateRequest(
              model: 'claude-sonnet-4-6',
              messages: [
                oai.ChatMessage.user('What is the weather in Paris? Use the get_weather tool.'),
              ],
              tools: tools,
              toolChoice: oai.ToolChoice.auto(),
              maxCompletionTokens: 16000,
            ),
          )) {
            final choices = chunk.choices ?? [];
            if (choices.isNotEmpty) {
              final toolCalls = choices.first.delta.toolCalls;
              if (toolCalls != null) {
                for (final tc in toolCalls) {
                  if (tc.function?.name != null) {
                    streamedToolName = tc.function!.name;
                  }
                }
              }
            }
          }

          print('[${fixture.label}] Streaming tool name: $streamedToolName');
          expect(streamedToolName, isNotNull, reason: '[${fixture.label}] Should have received a tool call');
          expect(
            streamedToolName,
            'get_weather',
            reason:
                '[${fixture.label}] Streaming: tool name must match original '
                'definition, not CC canonical',
          );

          client.close();
        },
        timeout: Timeout(Duration(seconds: 60)),
      );

      test(
        'Round-trip fidelity: CC-canonical tool name survives streaming round-trip',
        () async {
          // "bash" is a CC canonical name (maps to "Bash") on OAuth.
          // On direct-API the converter doesn't remap; the test still
          // expects the original name to round-trip.
          final client = fixture.buildClient();

          final bashTools = [
            oai.Tool.function(
              name: 'bash',
              description: 'Execute a bash command',
              parameters: {
                'type': 'object',
                'properties': {
                  'command': {'type': 'string'},
                },
                'required': ['command'],
              },
            ),
          ];

          String? streamedToolName;
          await for (final chunk in client.chat.completions.createStream(
            oai.ChatCompletionCreateRequest(
              model: 'claude-sonnet-4-6',
              messages: [
                oai.ChatMessage.user('Run "echo hello" using the bash tool.'),
              ],
              tools: bashTools,
              toolChoice: oai.ToolChoice.auto(),
              maxCompletionTokens: 16000,
            ),
          )) {
            final choices = chunk.choices ?? [];
            if (choices.isNotEmpty) {
              final toolCalls = choices.first.delta.toolCalls;
              if (toolCalls != null) {
                for (final tc in toolCalls) {
                  if (tc.function?.name != null) {
                    streamedToolName = tc.function!.name;
                  }
                }
              }
            }
          }

          print('[${fixture.label}] CC-canonical streaming tool name: $streamedToolName');
          expect(streamedToolName, isNotNull);
          expect(
            streamedToolName,
            'bash',
            reason:
                '[${fixture.label}] Streaming must return original "bash" '
                '(not CC canonical "Bash")',
          );

          client.close();
        },
        timeout: Timeout(Duration(seconds: 60)),
      );

      test(
        'Round-trip fidelity: full GPT → Anthropic → GPT conversation preserves all data',
        () async {
          if (openAIKey == null) {
            markTestSkipped('OPENAI_API_KEY not set');
            return;
          }
          final openAIClient = oai.OpenAIClient.withApiKey(openAIKey);
          final claudeClient = fixture.buildClient();

          final history = <oai.ChatMessage>[
            oai.ChatMessage.system('You are a helpful assistant. Be brief.'),
            oai.ChatMessage.user('What is the capital of France?'),
          ];

          // Round 1: GPT
          final gptResponse = await openAIClient.chat.completions.create(
            oai.ChatCompletionCreateRequest(
              model: 'gpt-4.1-nano',
              messages: history,
            ),
          );
          final gptMsg = gptResponse.choices.first.message;
          history.add(gptMsg);
          print('[${fixture.label}] GPT: ${gptMsg.content}');

          // Round 2: Anthropic
          history.add(oai.ChatMessage.user('And Japan? One word.'));
          final claudeResponse = await claudeClient.chat.completions.create(
            oai.ChatCompletionCreateRequest(
              model: 'claude-sonnet-4-6',
              messages: history,
              maxCompletionTokens: 16000,
            ),
          );
          final claudeMsg = claudeResponse.choices.first.message;
          history.add(claudeMsg);
          print('[${fixture.label}] Claude: ${claudeMsg.content}');

          // Round 3: GPT (with mixed-provider history)
          history.add(oai.ChatMessage.user('Which of those two countries is larger by area?'));
          final gpt2Response = await openAIClient.chat.completions.create(
            oai.ChatCompletionCreateRequest(
              model: 'gpt-4.1-nano',
              messages: history,
            ),
          );
          final gpt2Msg = gpt2Response.choices.first.message;
          print('[${fixture.label}] GPT (round 2): ${gpt2Msg.content}');

          expect(gpt2Msg.content, isNotNull);
          expect(
            gpt2Msg.content!.toLowerCase(),
            anyOf(contains('france'), contains('japan')),
            reason: '[${fixture.label}] GPT should recall context from both providers',
          );

          // Verify no Claude-specific artifacts leaked into messages
          for (final msg in history) {
            if (msg case oai.AssistantMessage(:final content)) {
              if (content != null) {
                expect(
                  content,
                  isNot(contains('Claude Code')),
                  reason: '[${fixture.label}] CC identity should not leak into conversation history',
                );
              }
            }
            if (msg case oai.SystemMessage(:final content)) {
              expect(
                content,
                isNot(contains('Claude Code')),
                reason: '[${fixture.label}] CC identity should not appear in user system messages',
              );
            }
          }

          openAIClient.close();
          claudeClient.close();
        },
        timeout: Timeout(Duration(minutes: 2)),
      );
    });
  }

  if (modes.isEmpty) {
    test('skipped — no credentials wired', () {
      markTestSkipped('Neither CLAUDE_CODE_CREDENTIALS nor ANTHROPIC_API_KEY is set');
    });
  }
}
