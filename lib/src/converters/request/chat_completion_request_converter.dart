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

/// The Claude Code identity system prompt required for OAuth Sonnet/Opus access.
const String _claudeCodeIdentity =
    "You are Claude Code, Anthropic's official CLI for Claude.";

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
  ///
  /// If [isOAuth] is true, enables Claude Code compatibility:
  /// - Prepends Claude Code identity system prompt
  /// - Adds cache_control to system prompt blocks and last user message
  /// - Enables adaptive thinking for 4.6 models
  /// - Remaps tool names to Claude Code canonical casing
  /// - Strips temperature when thinking is active (incompatible)
  anthropic.MessageCreateRequest convert(
    ChatCompletionCreateRequest request, {
    void Function(Map<String, dynamic> body)? bodyTransformer,
    bool isOAuth = false,
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
    // Use higher default for OAuth (pi-mono uses modelMaxTokens/3 ≈ 21333)
    final maxTokens = request.maxCompletionTokens ??
        request.maxTokens ??
        (isOAuth ? 16384 : 4096);

    // Convert stop sequences
    final stopSequences = _convertStopSequences(request.stop);

    // Convert tools — remap names to CC canonical for OAuth
    var tools = _toolMapper.toAnthropic(request.tools, isOAuth: isOAuth);

    // Convert tool choice
    var toolChoice = _toolMapper.toAnthropicToolChoice(
      request.toolChoice,
      request.parallelToolCalls,
    );

    // Convert responseFormat JSON schema to tool-based structured output.
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

    // Build system prompt — for OAuth, prepend Claude Code identity with cache_control
    anthropic.SystemPrompt? system;
    if (isOAuth) {
      final blocks = <anthropic.SystemTextBlock>[
        anthropic.SystemTextBlock(
          text: _claudeCodeIdentity,
          cacheControl: const anthropic.CacheControlEphemeral(),
        ),
        if (systemPrompt != null)
          anthropic.SystemTextBlock(
            text: systemPrompt,
            cacheControl: const anthropic.CacheControlEphemeral(),
          ),
      ];
      system = anthropic.SystemPrompt.blocks(blocks);
    } else {
      system = systemPrompt != null
          ? anthropic.SystemPrompt.text(systemPrompt)
          : null;
    }

    // Thinking configuration — adaptive for 4.6 models when OAuth
    final useAdaptiveThinking = isOAuth && _supportsAdaptiveThinking(model);

    // Temperature is incompatible with thinking — must not send both
    final effectiveTemperature = useAdaptiveThinking
        ? null
        : request.temperature;

    var anthropicRequest = anthropic.MessageCreateRequest(
      model: model,
      messages: messages,
      maxTokens: maxTokens,
      system: system,
      temperature: effectiveTemperature,
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

    // For OAuth without a bodyTransformer, auto-apply cache breakpoints
    // and thinking via the JSON round-trip.
    if (isOAuth) {
      final body = anthropicRequest.toJson();
      bool modified = false;

      // Inject adaptive thinking for 4.6 models
      if (useAdaptiveThinking && !body.containsKey('thinking')) {
        body['thinking'] = {'type': 'adaptive'};
        modified = true;
      }

      // Apply cache_control to last user message's last content block
      final msgs = body['messages'];
      if (msgs is List) {
        for (int i = msgs.length - 1; i >= 0; i--) {
          final msg = msgs[i];
          if (msg is Map && msg['role'] == 'user') {
            final content = msg['content'];
            if (content is String) {
              msg['content'] = [
                {
                  'type': 'text',
                  'text': content,
                  'cache_control': {'type': 'ephemeral'},
                },
              ];
              modified = true;
            } else if (content is List && content.isNotEmpty) {
              final lastBlock = content.last;
              if (lastBlock is Map &&
                  !lastBlock.containsKey('cache_control')) {
                content[content.length - 1] = <String, dynamic>{
                  for (final e in lastBlock.entries)
                    e.key as String: e.value,
                  'cache_control': <String, dynamic>{'type': 'ephemeral'},
                };
                modified = true;
              }
            }
            break;
          }
        }
      }

      if (modified) {
        anthropicRequest = anthropic.MessageCreateRequest.fromJson(
          _deepCastJson(body),
        );
      }
    }

    return anthropicRequest;
  }

  /// Whether a model supports adaptive thinking (Opus 4.6 and Sonnet 4.6).
  static bool _supportsAdaptiveThinking(String modelId) {
    return modelId.contains('opus-4-6') ||
        modelId.contains('opus-4.6') ||
        modelId.contains('sonnet-4-6') ||
        modelId.contains('sonnet-4.6');
  }

  /// Converts OpenAI stop sequences to Anthropic format.
  List<String>? _convertStopSequences(List<String>? stop) {
    if (stop == null || stop.isEmpty) return null;
    return stop;
  }

  /// Recursively casts all nested [Map] and [List] values to
  /// `Map<String, dynamic>` and `List<dynamic>` respectively.
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
    AnthropicOpenAILogger.logUnsupportedParam('frequency_penalty', request.frequencyPenalty);
    AnthropicOpenAILogger.logUnsupportedParam('presence_penalty', request.presencePenalty);
    AnthropicOpenAILogger.logUnsupportedParam('logit_bias', request.logitBias);
    AnthropicOpenAILogger.logUnsupportedParam('logprobs', request.logprobs);
    AnthropicOpenAILogger.logUnsupportedParam('top_logprobs', request.topLogprobs);
    AnthropicOpenAILogger.logUnsupportedParam('seed', request.seed);
    if (request.responseFormat != null && request.responseFormat is! JsonSchemaResponseFormat) {
      AnthropicOpenAILogger.logUnsupportedParam('response_format', request.responseFormat);
    }
    AnthropicOpenAILogger.logUnsupportedParam('audio', request.audio);
    AnthropicOpenAILogger.logUnsupportedParam('modalities', request.modalities);
    AnthropicOpenAILogger.logUnsupportedParam('prediction', request.prediction);
    AnthropicOpenAILogger.logUnsupportedParam('user', request.user);
    AnthropicOpenAILogger.logUnsupportedParam('store', request.store);
    AnthropicOpenAILogger.logUnsupportedParam('metadata', request.metadata);

    if (request.n != null && request.n! > 1) {
      AnthropicOpenAILogger.warn(
        'Parameter "n" > 1 is not supported by Anthropic. Only 1 choice will be returned.',
      );
    }
  }
}
