# OpenAI API for Anthropic (Claude & Claude Code)

A translation layer that lets you use the OpenAI API interface to interact with Anthropic's Claude models. Maps the OpenAI public API surface to Anthropic's API — models, endpoints, parameters, and data classes. Uses [`anthropic_sdk_dart`](https://pub.dev/packages/anthropic_sdk_dart) under the hood.

## Installation

```yaml
dependencies:
  open_ai_anthropic: <latest_version>
  openai_dart: ^4.3.0
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
    model: 'claude-sonnet-4-5',
    messages: [
      ChatMessage.system('You are a helpful assistant.'),
      ChatMessage.user('Hello!'),
    ],
  ),
);
print(response.text);
```

Constructor parameters:

| Parameter                | Description                                                                 |
| ------------------------ | --------------------------------------------------------------------------- |
| `apiKey`                 | Anthropic API key.                                                          |
| `baseUrl`                | Base URL (defaults to `https://api.anthropic.com/v1`).                      |
| `headers`                | Additional headers sent with every request.                                 |
| `queryParams`            | Additional query params sent with every request.                            |
| `retries`                | Retry count for failed requests (default `3`).                              |
| `client`                 | Custom `http.Client`.                                                       |
| `bodyTransformer`        | Mutates the Anthropic request body before it is sent.                       |
| `responseBodyTransformer`| Inspects the Anthropic response body (non-streaming) after conversion.      |
| `defaultEffort`          | Default adaptive-thinking effort (`kDefaultAdaptiveEffort` = `'medium'`).   |
| `isOAuth`                | Enables Claude Code compatibility (set automatically by `ClaudeCodeOpenAIClient`). |

### Streaming

```dart
final stream = client.chat.completions.createStream(
  ChatCompletionCreateRequest(
    model: 'claude-sonnet-4-5',
    messages: [ChatMessage.user('Write a haiku.')],
  ),
);

await for (final chunk in stream) {
  stdout.write(chunk.textDelta ?? '');
}
```

### Document Input with Structured Output

`AnthropicOpenAIClient.createDocumentCompletion()` sends a document (e.g. PDF) with a tool-forced JSON schema output. This exposes Anthropic's document input — which has no OpenAI equivalent — and returns the structured result directly.

```dart
final structured = await client.createDocumentCompletion(
  userPrompt: 'Extract invoice totals.',
  documentBytes: pdfBytes,
  documentMediaType: 'application/pdf',
  documentFileName: 'invoice.pdf',
  outputSchema: {
    'type': 'object',
    'properties': {
      'total': {'type': 'number'},
      'currency': {'type': 'string'},
    },
    'required': ['total', 'currency'],
  },
  outputToolName: 'record_invoice',
  outputToolDescription: 'Capture the extracted invoice fields.',
);
print(structured['total']);
```

### Claude Code Client (OAuth)

Use `ClaudeCodeOpenAIClient` for OAuth-based authentication. It subclasses `AnthropicOpenAIClient`, injects Claude Code identity/beta headers, enables adaptive thinking for 4.6 models, and remaps tool names to Claude Code canonical casing.

```dart
// From credentials JSON (auto-detects short-lived vs long-lived)
final credentialsJson = Platform.environment['CLAUDE_CODE_CREDENTIALS']!;
final credentials = ClaudeCodeCredentials.fromJsonString(credentialsJson);
final client = ClaudeCodeOpenAIClient(credentials: credentials);

// Short-lived OAuth credentials (with refresh token, ~8 hour expiry)
final shortLived = ShortLivedClaudeCodeCredentials(
  accessToken: 'oauth-access-token',
  refreshToken: 'oauth-refresh-token',
  expiresAt: DateTime.now().add(Duration(hours: 8)),
);

// Long-lived API key credentials (via `claude setup-token`, ~360 day expiry)
final longLived = LongLivedClaudeCodeCredentials(
  accessToken: 'sk-ant-...',
  expiresAt: DateTime.now().add(Duration(days: 360)),
);
```

Constructor parameters (beyond those inherited from `AnthropicOpenAIClient`):

| Parameter                 | Description                                                               |
| ------------------------- | ------------------------------------------------------------------------- |
| `credentials`             | A `ClaudeCodeCredentials` instance (either subtype).                      |
| `tokenStore`              | A `ClaudeCodeTokenStore` for custom storage/refresh. One of `credentials` or `tokenStore` is required. |
| `onTokenRefreshed`        | Callback invoked after a successful token refresh.                        |
| `use1mContext`            | Adds the `context-1m-2025-08-07` beta header (1M token context window).   |
| `debugLogNetworkRequests` | Logs HTTP requests/responses — for debugging only.                        |

#### Credential Types

`ClaudeCodeCredentials` is a sealed class with two subtypes:

- **`ShortLivedClaudeCodeCredentials`** — OAuth tokens with a refresh token. Expire in ~8 hours and can be auto-refreshed by the token store. `isExpired` includes a 5-minute proactive buffer.
- **`LongLivedClaudeCodeCredentials`** — API keys generated via `claude setup-token`. Valid for ~360 days, no refresh token, no expiration buffer.

`ClaudeCodeCredentials.fromJson` and `ClaudeCodeCredentials.fromJsonString` auto-detect the subtype based on the presence of a non-empty `refresh_token` field.

#### Token Stores

`ClaudeCodeTokenStore` auto-refreshes short-lived credentials and throws `StateError` for expired long-lived credentials. Factory helpers:

```dart
// Load from an explicit file path; auto-saves refreshed tokens back to disk.
final fileStore = await ClaudeCodeTokenStore.createFromFile('claude_credentials.json');

// Load from the default Claude Code credentials path (~/.claude/.credentials.json).
final systemStore = await ClaudeCodeTokenStore.createFromSystem();

// Non-throwing variants return null on failure.
final maybe = await ClaudeCodeTokenStore.tryCreateFromSystem();

final client = ClaudeCodeOpenAIClient(tokenStore: systemStore);
```

Each factory has a sync (`*Sync`) variant and a non-throwing `tryCreate*` variant. All accept `autoSave`, `onTokenRefreshedCallback`, and a custom `http.Client`.

### Generating OAuth Credentials

```console
dart run open_ai_anthropic:generate
```

Follow the terminal instructions to complete the OAuth flow. This generates a `claude_code_credentials.json` file and prints the credentials JSON for use as an environment variable.

You can also call the flow programmatically:

```dart
import 'package:open_ai_anthropic/generator.dart';

final tokenResponse = await TokenGenerator.generate(longLived: false);
```

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

The `bodyTransformer` works on the **Anthropic-format JSON** body (with `system`, `messages`, `tools` keys).

`ClaudeCodeOpenAIClient` automatically applies Claude Code's default cache breakpoint strategy (identity system block + last message) when no `bodyTransformer` is set. Use the `CacheRetention` enum (`none` / `short` / `long`) with the underlying request converter to switch between `ephemeral` and `ttl: 1h` caching.

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

For provider-specific fields without an OpenAI equivalent (e.g. `cache_creation_input_tokens`), pass a `responseBodyTransformer` to inspect the raw Anthropic response JSON after conversion.

## Adaptive Thinking (4.6 Models)

For OAuth requests against Claude 4.6 models (Opus 4.6 / Sonnet 4.6), adaptive thinking is enabled automatically along with an effort level to prevent unbounded thinking loops. The default effort (`kDefaultAdaptiveEffort = 'medium'`) can be overridden:

```dart
final client = ClaudeCodeOpenAIClient(
  credentials: credentials,
  // Pass any of 'low' | 'medium' | 'high' | 'max', or null to defer to the API default ('high').
);
// AnthropicOpenAIClient exposes the same `defaultEffort` parameter.
```

Required beta headers (`kThinkingBetaHeaders`) are added automatically for OAuth clients. `ClaudeCodeOpenAIClient.buildBetaHeader()` is available if you need to compute the header yourself for a specific model.

## Public API Exports

```dart
import 'package:open_ai_anthropic/open_ai_anthropic.dart';
// Clients
//   AnthropicOpenAIClient, ClaudeCodeOpenAIClient
// Typedefs / constants
//   BodyTransformer, CacheRetention, kThinkingBetaHeaders, kDefaultAdaptiveEffort
// Credentials
//   ClaudeCodeCredentials, ShortLivedClaudeCodeCredentials, LongLivedClaudeCodeCredentials
// Token store
//   ClaudeCodeTokenStore, FileClaudeCodeTokenStore, SystemClaudeCodeTokenStore, TokenRefreshedCallback

import 'package:open_ai_anthropic/generator.dart';
// TokenGenerator
```

## Cross-Provider Interoperability

The OpenAI-format conversation history (`List<ChatMessage>`) can be shared seamlessly across providers. Tool calls, tool results, system messages, and assistant responses all translate 1:1 — no data is lost between OpenAI and Claude.
