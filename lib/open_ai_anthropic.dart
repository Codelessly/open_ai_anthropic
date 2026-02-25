/// A package that wraps Anthropic's SDK with OpenAI's API interface.
///
/// This package allows you to use Anthropic's Claude models with the exact
/// same API as OpenAI's SDK. Simply use [AnthropicOpenAIClient] instead of
/// `OpenAIClient` and provide your Anthropic API key.
///
/// Example:
/// ```dart
/// import 'package:open_ai_anthropic/open_ai_anthropic.dart';
/// import 'package:openai_dart/openai_dart.dart';
///
/// final client = AnthropicOpenAIClient(apiKey: 'your-anthropic-api-key');
///
/// final response = await client.createChatCompletion(
///   request: CreateChatCompletionRequest(
///     model: ChatCompletionModel.modelId('claude-sonnet-4-20250514'),
///     messages: [
///       ChatCompletionMessage.user(
///         content: ChatCompletionUserMessageContent.string('Hello!'),
///       ),
///     ],
///   ),
/// );
///
/// print(response.choices.first.message.content);
/// ```
///
/// For streaming responses:
/// ```dart
/// final stream = client.createChatCompletionStream(
///   request: CreateChatCompletionRequest(
///     model: ChatCompletionModel.modelId('claude-sonnet-4-20250514'),
///     messages: [...],
///   ),
/// );
///
/// await for (final chunk in stream) {
///   stdout.write(chunk.choices.first.delta?.content ?? '');
/// }
/// ```
library;

export 'src/client/claude_code_client.dart' show ClaudeCodeOpenAIClient;
export 'src/client/client.dart' show AnthropicOpenAIClient;
export 'src/model/claude_code_credentials.dart';
export 'src/utils/claude_code_token_store.dart';
