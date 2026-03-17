import 'dart:io';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:test/test.dart';

ClaudeCodeCredentials? _loadCredentials() {
  final envFile = File('.env');
  if (envFile.existsSync()) {
    for (final line in envFile.readAsLinesSync()) {
      if (line.startsWith('CLAUDE_CODE_CREDENTIALS=')) {
        return ClaudeCodeCredentials.fromJsonString(line.substring('CLAUDE_CODE_CREDENTIALS='.length));
      }
    }
  }
  final envVar = Platform.environment['CLAUDE_CODE_CREDENTIALS'];
  if (envVar != null && envVar.isNotEmpty) {
    return ClaudeCodeCredentials.fromJsonString(envVar);
  }
  return null;
}

void main() {
  final creds = _loadCredentials();

  test(
    'Sonnet 4.6 via ClaudeCodeOpenAIClient (OAuth)',
    () async {
      final client = ClaudeCodeOpenAIClient(
        credentials: creds,
        debugLogNetworkRequests: true,
      );

      final response = await client.chat.completions.create(
        oai.ChatCompletionCreateRequest(
          model: 'claude-sonnet-4-6',
          messages: [oai.ChatMessage.user('Say hi in one word')],
          maxCompletionTokens: 16000,
        ),
      );

      final text = response.choices.first.message.content;
      print('Sonnet response: $text');
      print(
        'Usage: promptTokens=${response.usage?.promptTokens}, '
        'completionTokens=${response.usage?.completionTokens}',
      );
      expect(text, isNotNull);
      expect(text, isNotEmpty);

      client.close();
    },
    skip: creds == null ? 'CLAUDE_CODE_CREDENTIALS not set' : null,
    timeout: Timeout(Duration(seconds: 60)),
  );

  test(
    'Sonnet 4.6 with custom tools via OAuth',
    () async {
      final client = ClaudeCodeOpenAIClient(credentials: creds);

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
        'Tool call response: ${msg.content ?? "tool_calls: ${msg.toolCalls?.map((t) => "${t.function.name}(${t.function.arguments})").join(", ")}"}',
      );
      // Should have made a tool call
      expect(msg.toolCalls, isNotNull);
      expect(msg.toolCalls, isNotEmpty);
      expect(msg.toolCalls!.first.function.name, 'lookup_capital');

      client.close();
    },
    skip: creds == null ? 'CLAUDE_CODE_CREDENTIALS not set' : null,
    timeout: Timeout(Duration(seconds: 60)),
  );

  test(
    'Haiku still works via OAuth',
    () async {
      final client = ClaudeCodeOpenAIClient(credentials: creds);

      final response = await client.chat.completions.create(
        oai.ChatCompletionCreateRequest(
          model: 'claude-haiku-4-5-20251001',
          messages: [oai.ChatMessage.user('Say hi')],
          maxCompletionTokens: 1024,
        ),
      );

      print('Haiku response: ${response.choices.first.message.content}');
      expect(response.choices.first.message.content, isNotNull);

      client.close();
    },
    skip: creds == null ? 'CLAUDE_CODE_CREDENTIALS not set' : null,
    timeout: Timeout(Duration(seconds: 30)),
  );
}
