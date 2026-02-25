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

Use `AnthropicOpenAIClient` class instead of `OpenAIClient` and the rest of the OpenAI API remains the same. Refer
[`openai_dart`](https://pub.dev/packages/openai_dart) package documentation for more details on how to use the OpenAI API.