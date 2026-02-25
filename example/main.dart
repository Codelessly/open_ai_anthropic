import 'dart:convert';
import 'dart:io';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:openai_dart/openai_dart.dart';

void main() async {
  final jsonContent = File('claude_credentials.json').readAsStringSync();
  final credentials = ClaudeCodeCredentials.fromJson(jsonDecode(jsonContent));

  // Create a client with your Anthropic API key
  final client = ClaudeCodeOpenAIClient(credentials: credentials);

  // Non-streaming example
  print('=== Non-streaming example ===\n');
  final response = await client.createChatCompletion(
    request: CreateChatCompletionRequest(
      model: ChatCompletionModel.modelId('claude-sonnet-4-5'),
      messages: [
        ChatCompletionMessage.system(content: "You are Claude Code, Anthropic's official CLI for Claude."),
        ChatCompletionMessage.user(
          content: ChatCompletionUserMessageContent.string('Hi'),
        ),
      ],
    ),
  );

  print('Response: ${response.choices.first.message.content}');
  print('Model: ${response.model}');
  print('Provider: ${response.provider}');

  // Streaming example
  print('\n=== Streaming example ===\n');
  final stream = client.createChatCompletionStream(
    request: CreateChatCompletionRequest(
      model: ChatCompletionModel.modelId('claude-sonnet-4-5'),
      messages: [
        ChatCompletionMessage.system(content: "You are Claude Code, Anthropic's official CLI for Claude."),
        ChatCompletionMessage.user(
          content: ChatCompletionUserMessageContent.string('Write a haiku about programming.'),
        ),
      ],
    ),
  );

  await for (final chunk in stream) {
    stdout.write(chunk.choices?.firstOrNull?.delta?.content ?? '');
  }
  print('\n');

  // Clean up
  client.endSession();
}
