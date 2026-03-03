import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../mappers/tool_mapper.dart';
import '../../utils/logger.dart';
import 'message_content_converter.dart';

/// Tool name used for JSON schema structured output via tool forcing.
/// When a request includes `responseFormat: jsonSchema(...)`, we convert it
/// to a tool with this name and force the model to call it, ensuring the
/// output conforms to the provided schema.
const String jsonSchemaToolName = '__json_response';

/// Converts OpenAI chat completion requests to Anthropic create message requests.
class ChatCompletionRequestConverter {
  final MessageContentConverter _messageConverter;
  final ToolMapper _toolMapper;

  ChatCompletionRequestConverter({
    MessageContentConverter? messageConverter,
    ToolMapper? toolMapper,
  }) : _messageConverter = messageConverter ?? MessageContentConverter(),
       _toolMapper = toolMapper ?? ToolMapper();

  /// Converts an OpenAI CreateChatCompletionRequest to an Anthropic MessageCreateRequest.
  anthropic.MessageCreateRequest convert(CreateChatCompletionRequest request) {
    // Log warnings for unsupported parameters
    _logUnsupportedParams(request);

    // Extract system prompt from messages
    final systemPrompt = _messageConverter.extractSystemPrompt(request.messages);

    // Convert messages to Anthropic format
    final messages = _messageConverter.convertMessages(request.messages);

    // Convert model
    final model = _convertModel(request.model);

    // Convert max tokens (required in Anthropic, optional in OpenAI)
    final maxTokens = request.maxCompletionTokens ?? request.maxTokens ?? 4096;

    // Convert stop sequences
    final stopSequences = _convertStopSequences(request.stop);

    // Convert tools
    var tools = _toolMapper.toAnthropic(request.tools);

    // Convert tool choice
    var toolChoice = _toolMapper.toAnthropicToolChoice(
      request.toolChoice,
      request.parallelToolCalls,
    );

    // Convert responseFormat JSON schema to tool-based structured output.
    // Anthropic doesn't have a native responseFormat; instead we create a
    // tool with the schema and force the model to call it.
    final responseFormat = request.responseFormat;
    if (responseFormat is ResponseFormatJsonSchema) {
      if (toolChoice != null) {
        AnthropicOpenAILogger.warn(
          'responseFormat jsonSchema overrides explicit toolChoice. '
          'The model will be forced to call the structured output tool.',
        );
      }
      final schema = responseFormat.jsonSchema.schema;
      final jsonTool = anthropic.ToolDefinition.custom(
        anthropic.Tool(
          name: jsonSchemaToolName,
          description: 'Output structured JSON response matching the required schema.',
          inputSchema: ToolMapper.buildInputSchema(schema),
        ),
      );
      tools = [...?tools, jsonTool];
      toolChoice = anthropic.ToolChoice.tool(jsonSchemaToolName);
    }

    return anthropic.MessageCreateRequest(
      model: model,
      messages: messages,
      maxTokens: maxTokens,
      system: systemPrompt != null ? anthropic.SystemPrompt.text(systemPrompt) : null,
      temperature: request.temperature,
      topP: request.topP,
      topK: request.topK,
      stopSequences: stopSequences,
      tools: tools,
      toolChoice: toolChoice,
    );
  }

  /// Converts the OpenAI model to an Anthropic model ID string.
  String _convertModel(ChatCompletionModel model) {
    // Pass through the model ID directly - users specify Claude model IDs
    return model.map(
      model: (m) => _modelEnumToString(m.value),
      modelId: (m) => m.value,
    );
  }

  /// Converts ChatCompletionModels enum to string.
  String _modelEnumToString(ChatCompletionModels model) {
    // The enum values don't directly correspond to Claude models
    // so we pass through the string value
    return switch (model) {
      ChatCompletionModels.gpt4o => 'claude-sonnet-4-20250514',
      ChatCompletionModels.gpt4oMini => 'claude-haiku-4-5-20251001',
      ChatCompletionModels.gpt4 => 'claude-3-opus-20240229',
      ChatCompletionModels.gpt4Turbo => 'claude-sonnet-4-20250514',
      ChatCompletionModels.gpt35Turbo => 'claude-3-5-haiku-20241022',
      _ => 'claude-sonnet-4-20250514', // Default fallback
    };
  }

  /// Converts OpenAI stop sequences to Anthropic format.
  List<String>? _convertStopSequences(ChatCompletionStop? stop) {
    if (stop == null) return null;

    return stop.map(
      listString: (list) => list.value,
      string: (s) => s.value != null ? [s.value!] : null,
    );
  }

  /// Logs warnings for unsupported parameters.
  void _logUnsupportedParams(CreateChatCompletionRequest request) {
    AnthropicOpenAILogger.logUnsupportedParam(
      'frequency_penalty',
      request.frequencyPenalty,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'presence_penalty',
      request.presencePenalty,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'logit_bias',
      request.logitBias,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'logprobs',
      request.logprobs,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'top_logprobs',
      request.topLogprobs,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'seed',
      request.seed,
    );
    // Only log response_format as unsupported when it's NOT jsonSchema
    // (jsonSchema is handled via tool-based structured output).
    if (request.responseFormat != null &&
        request.responseFormat is! ResponseFormatJsonSchema) {
      AnthropicOpenAILogger.logUnsupportedParam(
        'response_format',
        request.responseFormat,
      );
    }
    AnthropicOpenAILogger.logUnsupportedParam(
      'audio',
      request.audio,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'modalities',
      request.modalities,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'prediction',
      request.prediction,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'user',
      request.user,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'store',
      request.store,
    );
    AnthropicOpenAILogger.logUnsupportedParam(
      'metadata',
      request.metadata,
    );

    // Log warning if n > 1
    if (request.n != null && request.n! > 1) {
      AnthropicOpenAILogger.warn(
        'Parameter "n" > 1 is not supported by Anthropic. Only 1 choice will be returned.',
      );
    }

    // Deprecated parameters
    if (request.functions != null) {
      AnthropicOpenAILogger.warn(
        'Parameter "functions" is deprecated. Use "tools" instead.',
      );
    }
    if (request.functionCall != null) {
      AnthropicOpenAILogger.warn(
        'Parameter "function_call" is deprecated. Use "tool_choice" instead.',
      );
    }
  }
}
