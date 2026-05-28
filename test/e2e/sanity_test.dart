// Sanity probe for Anthropic clients — runs once per available
// [AnthropicMode] (OAuth + direct API key). Each test is skipped when
// the required credentials for its mode are absent.
import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:test/test.dart';

import 'test_modes.dart';

void main() {
  final modes = loadAvailableModes();

  for (final fixture in modes) {
    group(fixture.label, () {
      test(
        'Sonnet 4.6 returns text',
        () async {
          final client = fixture.buildClient();

          final response = await client.chat.completions.create(
            oai.ChatCompletionCreateRequest(
              model: 'claude-sonnet-4-6',
              messages: [oai.ChatMessage.user('Say hi in one word')],
              maxCompletionTokens: 16000,
            ),
          );

          final text = response.choices.first.message.content;
          print(
            '[${fixture.label}] Sonnet response: $text · usage prompt=${response.usage?.promptTokens} completion=${response.usage?.completionTokens}',
          );
          expect(text, isNotNull);
          expect(text, isNotEmpty);

          client.close();
        },
        timeout: Timeout(Duration(seconds: 60)),
      );

      test(
        'Sonnet 4.6 with custom tools issues a tool call',
        () async {
          final client = fixture.buildClient();

          final response = await client.chat.completions.create(
            oai.ChatCompletionCreateRequest(
              model: 'claude-sonnet-4-6',
              messages: [
                oai.ChatMessage.user('What is the capital of France? Use the lookup_capital tool.'),
              ],
              tools: [
                oai.Tool.function(
                  name: 'lookup_capital',
                  description: 'Look up the capital of a country',
                  parameters: {
                    'type': 'object',
                    'properties': {
                      'country': {'type': 'string'},
                    },
                    'required': ['country'],
                  },
                ),
              ],
              toolChoice: oai.ToolChoice.auto(),
              maxCompletionTokens: 16000,
            ),
          );

          final msg = response.choices.first.message;
          print(
            '[${fixture.label}] Tool call response: ${msg.content ?? "tool_calls: ${msg.toolCalls?.map((t) => "${t.function.name}(${t.function.arguments})").join(", ")}"}',
          );
          expect(msg.toolCalls, isNotNull);
          expect(msg.toolCalls, isNotEmpty);
          expect(msg.toolCalls!.first.function.name, 'lookup_capital');

          client.close();
        },
        timeout: Timeout(Duration(seconds: 60)),
      );

      test(
        'Haiku still works',
        () async {
          final client = fixture.buildClient();

          final response = await client.chat.completions.create(
            oai.ChatCompletionCreateRequest(
              model: 'claude-haiku-4-5-20251001',
              messages: [oai.ChatMessage.user('Say hi')],
              maxCompletionTokens: 1024,
            ),
          );

          print('[${fixture.label}] Haiku response: ${response.choices.first.message.content}');
          expect(response.choices.first.message.content, isNotNull);

          client.close();
        },
        timeout: Timeout(Duration(seconds: 30)),
      );
    });
  }

  if (modes.isEmpty) {
    test('skipped — no credentials wired', () {
      markTestSkipped('Neither CLAUDE_CODE_CREDENTIALS nor ANTHROPIC_API_KEY is set');
    });
  }
}
