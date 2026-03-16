# OpenAI API for Anthropic (Claude & Claude Code)

A translation layer that lets you use the OpenAI API interface to interact with Anthropic's Claude models. Maps the OpenAI public API surface to Anthropic's API — models, endpoints, parameters, and data classes. Uses [`anthropic_sdk_dart`](https://pub.dev/packages/anthropic_sdk_dart) under the hood.

## Installation

```yaml
dependencies:
  open_ai_anthropic: ^0.1.0
```

Then run `dart pub get`.

## Usage

Use `AnthropicOpenAIClient` as a drop-in replacement for `OpenAIClient`. The rest of the OpenAI API remains the same — refer to [`openai_dart`](https://pub.dev/packages/openai_dart) for full documentation.

### API Key Authentication

```dart
import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:openai_dart/openai_dart.dart';

final client = AnthropicOpenAIClient(apiKey: 'your-anthropic-api-key');

final response = await client.chat.completions.create(
  ChatCompletionCreateRequest(
    model: 'claude-sonnet-4-20250514',
    messages: [
      ChatMessage.system('You are a helpful assistant.'),
      ChatMessage.user('Hello!'),
    ],
  ),
);
print(response.choices.first.message.content);
```

### Streaming

```dart
final stream = client.chat.completions.createStream(
  ChatCompletionCreateRequest(
    model: 'claude-sonnet-4-20250514',
    messages: [ChatMessage.user('Write a haiku.')],
  ),
);

await for (final chunk in stream) {
  stdout.write(chunk.textDelta ?? '');
}
```

### Claude Code Client (OAuth)

For OAuth-based authentication (e.g. Claude Code tokens):

```dart
// From credentials JSON
final credentialsJson = Platform.environment['CLAUDE_CODE_CREDENTIALS'];
final credentials = ClaudeCodeCredentials.fromJsonString(credentialsJson!);
final client = ClaudeCodeOpenAIClient(credentials: credentials);

// Or from a long-lived access token (via `claude setup-token`)
final token = Platform.environment['CLAUDE_CODE_TOKEN'];
final credentials = ClaudeCodeCredentials.fromToken(token!);
final client = ClaudeCodeOpenAIClient(credentials: credentials);
```

You can also pass a `ClaudeCodeTokenStore` instead of `credentials` for custom token storage and refresh logic.

### Generating OAuth Credentials

```console
dart run open_ai_anthropic:generate
```

Follow the terminal instructions to complete the OAuth flow. This generates a `claude_code_credentials.json` file and prints the credentials JSON for use as an environment variable.

## Cache Breakpoints

Both `AnthropicOpenAIClient` and `ClaudeCodeOpenAIClient` accept an optional `bodyTransformer` callback. This receives the Anthropic request body as a mutable JSON map before it is sent to the API, allowing you to inject `cache_control` breakpoints or other provider-specific mutations.

```dart
final client = AnthropicOpenAIClient(
  apiKey: 'your-key',
  bodyTransformer: (body) {
    // Cache the system message
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

    // Cache the last two user messages
    final messages = body['messages'];
    if (messages is! List) return;
    final userIndices = <int>[];
    for (int i = 0; i < messages.length; i++) {
      if (messages[i] is Map && messages[i]['role'] == 'user') {
        userIndices.add(i);
      }
    }
    final lastTwo = userIndices.length <= 2
        ? userIndices
        : userIndices.sublist(userIndices.length - 2);
    for (final idx in lastTwo) {
      final msg = messages[idx];
      if (msg is! Map) continue;
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
  },
);
```

The `bodyTransformer` works on the **Anthropic-format JSON** body (with `system`, `messages`, `tools` keys). This is the same shape used by existing cache breakpoint utilities like `addCacheBreakpointsAnthropic()`.

### Cache Token Reporting

Cache token usage is reported in both streaming and non-streaming responses:

```dart
final response = await client.chat.completions.create(request);

final usage = response.usage;
print('Total prompt tokens: ${usage?.promptTokens}');       // includes cached
print('Cached tokens: ${usage?.promptTokensDetails?.cachedTokens}'); // cache hits
print('Completion tokens: ${usage?.completionTokens}');
```

`promptTokens` includes all input token categories (uncached + cache read + cache creation). `promptTokensDetails.cachedTokens` reports the cache-read subset, matching OpenAI's convention.

## Cross-Provider Interoperability

The OpenAI-format conversation history (`List<ChatMessage>`) can be shared seamlessly across providers. Tool calls, tool results, system messages, and assistant responses all translate 1:1 — no data is lost between OpenAI and Claude.
