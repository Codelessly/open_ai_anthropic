# OpenAI API for Anthropic (Claude && Claude Code)

This package is a translation layer that allows you to use the OpenAI API interface to interact with Anthropic's Claude
models. Anthropic is known for its own data models and API structure that is not compatible with OpenAI's API spec.
This package bridges that gap by mapping OpenAI public API surface to Anthropic's API including models, endpoints, and
parameters and data classes. `[anthropic_sdk_dart](https://pub.dev/packages/anthropic_sdk_dart)` is used under the hood
to communicate with Anthropic's API.

## Installation
Add the following to your `pubspec.yaml` file:

```yaml
dependencies:
  openai_anthropic: ^0.1.0
```

Then run `flutter pub get` or `dart pub get` to install the package.

## Usage

### Generating OAuth credentials

Run following command to start the OAuth flow and generate credentials JSON. 
Follow the instructions in the terminal to complete the flow. 
This will generate a `claude_code_credentials.json` file in the current directory as well as print the credentials 
JSON in the terminal which you can set as an environment variable.
```console
dart pub run openai_anthropic:generate
```

Use `AnthropicOpenAIClient` class instead of `OpenAIClient` and the rest of the OpenAI API remains the same. Refer
[`openai_dart`](https://pub.dev/packages/openai_dart) package documentation for more details on how to use the OpenAI API.

```dart
import 'package:openai_anthropic/openai_anthropic.dart';

final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
final client = AnthropicOpenAIClient(apiKey: apiKey);
```

### Chat

```dart
final res = await client.createChatCompletion(
  request: CreateChatCompletionRequest(
    model: ChatCompletionModel.modelId('gpt-5'),
    messages: [
      ChatCompletionMessage.developer(
        content: 'You are a helpful assistant.',
      ),
      ChatCompletionMessage.user(
        content: ChatCompletionUserMessageContent.string('Hello!'),
      ),
    ],
  ),
);
print(res.choices.first.message.content);
// Hello! How can I assist you today?
```

Refer [`openai_dart`](https://pub.dev/packages/openai_dart) package documentation for more details on how to use the OpenAI API.

### Using Claude Code Client

```dart
// Using credentials JSON from env.
final credentialsJson = Platform.environment['CLAUDE_CODE_CREDENTIALS'];
final credentials = ClaudeCodeCredentials.fromJson(jsonDecode(credentialsJson!));
final client = ClaudeCodeOpenAIClient(credentials: credentials);
```
You can also pass a `tokenStore` instead of `credentials` for more control over how tokens are stored and refreshed. To
do so, extend `ClaudeCodeTokenStore` and implement the required methods.

How to use long-lived access token:

You can generate a long-lived access token by running `claude setup-token` command.

```dart
final token = Platform.environment['CLAUDE_CODE_TOKEN'];
final credentials = ClaudeCodeCredentials.fromToken(token);
final client = ClaudeCodeOpenAIClient(credentials: credentials);
```

### Refreshing OAuth tokens

```dart
/// Refresh access token using refresh token
static Future<Map<String, dynamic>> refreshAccessToken(String refreshToken) async {
  final response = await http.post(
    Uri.parse(ClaudeOAuthConfig.tokenUrl),
    headers: ClaudeOAuthConfig.defaultHeaders,
    body: jsonEncode({
      'grant_type': 'refresh_token',
      'client_id': ClaudeOAuthConfig.clientId,
      'refresh_token': refreshToken,
    }),
  );

  if (response.statusCode != 200) {
    throw Exception('Token refresh failed: ${response.body}');
  }

  final Map<String, dynamic> tokens = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  tokens['expires_at'] = DateTime.timestamp().add(Duration(seconds: tokens['expires_in'])).millisecondsSinceEpoch;
  return tokens;
}
```