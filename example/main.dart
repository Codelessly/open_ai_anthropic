import 'dart:convert';
import 'dart:io';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:openai_dart/openai_dart.dart';

void main() async {
  final jsonContent = File('claude_credentials.json').readAsStringSync();
  final credentials = ClaudeCodeCredentials.fromJson(jsonDecode(jsonContent));

  // Create a client with your Claude Code credentials
  final client = ClaudeCodeOpenAIClient(credentials: credentials);

  // Non-streaming example
  print('=== Non-streaming example ===\n');
  final response = await client.chat.completions.create(
    ChatCompletionCreateRequest(
      model: 'claude-sonnet-4-5',
      messages: [
        ChatMessage.system("You are Claude Code, Anthropic's official CLI for Claude."),
        ChatMessage.user('Hi'),
      ],
    ),
  );

  print('Response: ${response.text}');
  print('Model: ${response.model}');
  print('Provider: ${response.provider}');

  // Streaming example
  print('\n=== Streaming example ===\n');
  final stream = client.chat.completions.createStream(
    ChatCompletionCreateRequest(
      model: 'claude-sonnet-4-5',
      messages: [
        ChatMessage.system("You are Claude Code, Anthropic's official CLI for Claude."),
        ChatMessage.user('Write a haiku about programming.'),
      ],
    ),
  );

  await for (final chunk in stream) {
    stdout.write(chunk.textDelta ?? '');
  }
  print('\n');

  // Clean up
  client.close();
}
