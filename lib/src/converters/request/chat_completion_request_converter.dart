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

  /// Converts an OpenAI ChatCompletionCreateRequest to an Anthropic MessageCreateRequest.
  ///
  /// If [bodyTransformer] is provided, the converted request is serialized to
  /// JSON, passed to the transformer for mutation (e.g. adding cache_control
  /// breakpoints), and then deserialized back to a typed request.
  anthropic.MessageCreateRequest convert(
    ChatCompletionCreateRequest request, {
    void Function(Map<String, dynamic> body)? bodyTransformer,
  }) {
    // Log warnings for unsupported parameters
    _logUnsupportedParams(request);

    // Extract system prompt from messages
    final systemPrompt = _messageConverter.extractSystemPrompt(request.messages);

    // Convert messages to Anthropic format
    final messages = _messageConverter.convertMessages(request.messages);

    // Model is now a plain string
    final model = request.model;

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
    if (responseFormat is JsonSchemaResponseFormat) {
      if (toolChoice != null) {
        AnthropicOpenAILogger.warn(
          'responseFormat jsonSchema overrides explicit toolChoice. '
          'The model will be forced to call the structured output tool.',
        );
      }
      final schema = responseFormat.schema;
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

    var anthropicRequest = anthropic.MessageCreateRequest(
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

    // Apply body transformer if provided (e.g. for cache breakpoints).
    if (bodyTransformer != null) {
      final body = anthropicRequest.toJson();
      bodyTransformer(body);
      anthropicRequest = anthropic.MessageCreateRequest.fromJson(
        _deepCastJson(body),
      );
    }

    return anthropicRequest;
  }

  /// Converts OpenAI stop sequences to Anthropic format.
  List<String>? _convertStopSequences(List<String>? stop) {
    if (stop == null || stop.isEmpty) return null;
    return stop;
  }

  /// Recursively casts all nested [Map] and [List] values to
  /// `Map<String, dynamic>` and `List<dynamic>` respectively.
  ///
  /// Body transformers may produce `_Map<dynamic, dynamic>` via spread
  /// operators or map literals, which `fromJson()` rejects with type cast
  /// errors. This ensures the entire tree is properly typed.
  static Map<String, dynamic> _deepCastJson(Map body) {
    return body.map((key, value) => MapEntry(key as String, _deepCastValue(value)));
  }

  static dynamic _deepCastValue(dynamic value) {
    if (value is Map) return _deepCastJson(value);
    if (value is List) return value.map(_deepCastValue).toList();
    return value;
  }

  /// Logs warnings for unsupported parameters.
  void _logUnsupportedParams(ChatCompletionCreateRequest request) {
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
    if (request.responseFormat != null && request.responseFormat is! JsonSchemaResponseFormat) {
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
  }
}
