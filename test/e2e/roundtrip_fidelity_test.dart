import 'dart:io';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:test/test.dart';

({String? openAIKey, ClaudeCodeCredentials? claudeCredentials}) _loadCredentials() {
  String? openAIKey = Platform.environment['OPENAI_API_KEY'];
  ClaudeCodeCredentials? claudeCredentials;

  final credJson = Platform.environment['CLAUDE_CODE_CREDENTIALS'];
  if (credJson != null && credJson.isNotEmpty) {
    claudeCredentials = ClaudeCodeCredentials.fromJsonString(credJson);
  }

  final envFile = File('.env');
  if (envFile.existsSync()) {
    for (final line in envFile.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.startsWith('OPENAI_API_KEY=') &&
          (openAIKey == null || openAIKey.isEmpty)) {
        openAIKey = trimmed.substring('OPENAI_API_KEY='.length);
      }
      if (trimmed.startsWith('CLAUDE_CODE_CREDENTIALS=') &&
          claudeCredentials == null) {
        claudeCredentials = ClaudeCodeCredentials.fromJsonString(
            trimmed.substring('CLAUDE_CODE_CREDENTIALS='.length));
      }
    }
  }

  return (openAIKey: openAIKey, claudeCredentials: claudeCredentials);
}

void main() {
  final creds = _loadCredentials();
  final openAIKey = creds.openAIKey;
  final claudeCredentials = creds.claudeCredentials;

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

  test(
    'Round-trip fidelity: Claude streaming tool names match original definitions',
    () async {
      final client = ClaudeCodeOpenAIClient(credentials: claudeCredentials);

      // Ask Claude to use a tool with a lowercase name
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
      print('Non-streaming tool call: ${msg.toolCalls?.map((t) => t.function.name).toList()}');

      // Tool name in response must match the ORIGINAL definition name
      if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
        for (final tc in msg.toolCalls!) {
          expect(tc.function.name, 'get_weather',
              reason: 'Non-streaming: tool name must match original definition, not CC canonical');
        }
      }

      client.close();
    },
    skip: claudeCredentials == null ? 'CLAUDE_CODE_CREDENTIALS not set' : null,
    timeout: Timeout(Duration(seconds: 60)),
  );

  test(
    'Round-trip fidelity: Claude streaming tool names match original definitions',
    () async {
      final client = ClaudeCodeOpenAIClient(credentials: claudeCredentials);

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

      print('Streaming tool name: $streamedToolName');

      // Tool name in streaming response must also match original
      expect(streamedToolName, isNotNull, reason: 'Should have received a tool call');
      expect(streamedToolName, 'get_weather',
          reason: 'Streaming: tool name must match original definition, not CC canonical');

      client.close();
    },
    skip: claudeCredentials == null ? 'CLAUDE_CODE_CREDENTIALS not set' : null,
    timeout: Timeout(Duration(seconds: 60)),
  );

  test(
    'Round-trip fidelity: CC-canonical tool name survives streaming round-trip',
    () async {
      // "bash" is a CC canonical name (maps to "Bash"). Verify it round-trips.
      final client = ClaudeCodeOpenAIClient(credentials: claudeCredentials);

      final bashTools = [
        oai.Tool.function(
          name: 'bash',
          description: 'Execute a bash command',
          parameters: {
            'type': 'object',
            'properties': {'command': {'type': 'string'}},
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

      print('CC-canonical streaming tool name: $streamedToolName');
      expect(streamedToolName, isNotNull);
      // MUST be "bash" (original), not "Bash" (CC canonical)
      expect(streamedToolName, 'bash',
          reason: 'Streaming must remap CC canonical "Bash" back to original "bash"');

      client.close();
    },
    skip: claudeCredentials == null ? 'CLAUDE_CODE_CREDENTIALS not set' : null,
    timeout: Timeout(Duration(seconds: 60)),
  );

  test(
    'Round-trip fidelity: full GPT → Claude → GPT conversation preserves all data',
    () async {
      final openAIClient = oai.OpenAIClient.withApiKey(openAIKey!);
      final claudeClient = ClaudeCodeOpenAIClient(credentials: claudeCredentials);

      final history = <oai.ChatMessage>[
        oai.ChatMessage.system('You are a helpful assistant. Be brief.'),
        oai.ChatMessage.user('What is the capital of France?'),
      ];

      // Round 1: GPT-5
      final gptResponse = await openAIClient.chat.completions.create(
        oai.ChatCompletionCreateRequest(
          model: 'gpt-4.1-nano',
          messages: history,
        ),
      );
      final gptMsg = gptResponse.choices.first.message;
      history.add(gptMsg);
      print('GPT: ${gptMsg.content}');

      // Round 2: Claude (with same history)
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
      print('Claude: ${claudeMsg.content}');

      // Round 3: GPT-5 (with history from both providers)
      history.add(oai.ChatMessage.user('Which of those two countries is larger by area?'));
      final gpt2Response = await openAIClient.chat.completions.create(
        oai.ChatCompletionCreateRequest(
          model: 'gpt-4.1-nano',
          messages: history,
        ),
      );
      final gpt2Msg = gpt2Response.choices.first.message;
      print('GPT (round 2): ${gpt2Msg.content}');

      // GPT should be able to reference context from both prior rounds
      expect(gpt2Msg.content, isNotNull);
      expect(gpt2Msg.content!.toLowerCase(),
          anyOf(contains('france'), contains('japan')),
          reason: 'GPT should recall context from both providers');

      // Verify no Claude-specific artifacts leaked into messages
      for (final msg in history) {
        if (msg case oai.AssistantMessage(:final content)) {
          if (content != null) {
            expect(content, isNot(contains('Claude Code')),
                reason: 'CC identity should not leak into conversation history');
          }
        }
        if (msg case oai.SystemMessage(:final content)) {
          expect(content, isNot(contains('Claude Code')),
              reason: 'CC identity should not appear in user system messages');
        }
      }

      openAIClient.close();
      claudeClient.close();
    },
    skip: (openAIKey == null || openAIKey.isEmpty || claudeCredentials == null)
        ? 'Missing OPENAI_API_KEY or CLAUDE_CODE_CREDENTIALS'
        : null,
    timeout: Timeout(Duration(minutes: 2)),
  );
}
