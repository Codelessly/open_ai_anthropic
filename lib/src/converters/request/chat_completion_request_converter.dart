import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../client/client.dart' show CacheRetention;
import '../../mappers/tool_mapper.dart';
import '../../utils/logger.dart';
import 'message_content_converter.dart';

/// Tool name used for JSON schema structured output via tool forcing.
/// When a request includes `responseFormat: jsonSchema(...)`, we convert it
/// to a tool with this name and force the model to call it, ensuring the
/// output conforms to the provided schema.
const String jsonSchemaToolName = '__json_response';

/// The Claude Code identity system prompt required for OAuth Sonnet/Opus access.
const String _claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude.";

/// Converts OpenAI chat completion requests to Anthropic create message requests.
/// Default effort level for auto-injected adaptive thinking.
///
/// 'medium' is Anthropic's recommendation for Sonnet 4.6 agentic workloads.
/// Claude thinks moderately and may skip thinking for simple queries.
/// Use 'low' for minimal thinking, 'high'/'max' for deep reasoning.
///
/// Set to `null` to disable auto-injection of effort (API default = 'high').
/// Requires the `effort-2025-11-24` beta header.
const String kDefaultAdaptiveEffort = 'medium';

class ChatCompletionRequestConverter {
  final MessageContentConverter _messageConverter;
  final ToolMapper _toolMapper;

  /// The effort level to inject when auto-enabling adaptive thinking for OAuth.
  /// Defaults to [kDefaultAdaptiveEffort]. Set to `null` to let the API decide
  /// (which defaults to 'high' — use with caution on complex prompts).
  final String? defaultEffort;

  ChatCompletionRequestConverter({
    MessageContentConverter? messageConverter,
    ToolMapper? toolMapper,
    this.defaultEffort = kDefaultAdaptiveEffort,
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
    CacheRetention cacheRetention = CacheRetention.short,
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
    final maxTokens = request.maxCompletionTokens ?? request.maxTokens ?? (isOAuth ? 16384 : 4096);

    // Convert stop sequences
    final stopSequences = _convertStopSequences(request.stop);

    // Convert tools — remap names to CC canonical for OAuth
    var tools = _toolMapper.toAnthropic(request.tools, isOAuth: isOAuth);

    // Convert tool choice
    var toolChoice = _toolMapper.toAnthropicToolChoice(
      request.toolChoice,
      request.parallelToolCalls,
    );

    // Thinking configuration — adaptive for 4.6 models when OAuth.
    // Computed early so JSON schema tool choice can respect thinking constraints.
    final useAdaptiveThinking = isOAuth && _supportsAdaptiveThinking(model);

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

    // Forced tool choice (tool, any) is incompatible with extended thinking,
    // regardless of which thinking mode is requested (enabled / adaptive).
    // Only tool_choice: auto works with thinking. Since auto doesn't guarantee
    // the model calls the JSON schema tool, we disable thinking instead when
    // JSON schema structured output is required.
    //
    // This applies to ANY thinking source — both the auto-injected adaptive
    // thinking (OAuth 4.6 models) and explicit thinking arriving via
    // `bodyTransformer` (e.g. `AnthropicReasoningConfig` flowing through
    // `extraBody['thinking']`). The bodyTransformer block below strips any
    // pre-injected `thinking`/`output_config` when this flag is true.
    final skipThinking = responseFormat is JsonSchemaResponseFormat;

    // Build system prompt.
    //
    // Cache control is a feature of the Anthropic API itself and works
    // identically whether the request is authenticated via x-api-key or OAuth
    // (https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
    // It is therefore gated solely on [cacheRetention] (#9).
    //
    // The Claude Code identity prefix is OAuth-specific (required for Sonnet/
    // Opus OAuth access) and remains gated on [isOAuth].
    //
    // Reference: claude-code/src/services/api/claude.ts
    //   getCacheControl()           — lines 358-374 (builds {type:'ephemeral', ttl?, scope?})
    //   buildSystemPromptBlocks()   — lines 3213-3237 (splits system prompt into cached blocks)
    //
    // Differences from reference:
    //   - Claude Code splits into up to 4 blocks with global/org/null scopes.
    //     We use at most 2 blocks (identity + user prompt), both with the same
    //     retention. Direct-API path uses 1 block (user prompt only).
    //   - Claude Code supports scope:'global' and scope:'org' for cross-session
    //     sharing. We don't implement scopes yet.
    final cacheControl = cacheRetention == CacheRetention.none
        ? null
        : anthropic.CacheControlEphemeral(
            ttl: cacheRetention == CacheRetention.long ? anthropic.CacheTtl.ttl1h : null,
          );

    final shouldUseSystemBlocks = isOAuth || cacheControl != null;
    anthropic.SystemPrompt? system;
    if (shouldUseSystemBlocks) {
      final blocks = <anthropic.SystemTextBlock>[
        if (isOAuth)
          anthropic.SystemTextBlock(
            text: _claudeCodeIdentity,
            cacheControl: cacheControl,
          ),
        if (systemPrompt != null)
          anthropic.SystemTextBlock(
            text: systemPrompt,
            cacheControl: cacheControl,
          ),
      ];
      // If neither identity nor user system prompt exists, leave system null
      // rather than emitting an empty blocks list (rejected by the API).
      system = blocks.isEmpty ? null : anthropic.SystemPrompt.blocks(blocks);
    } else {
      system = systemPrompt != null ? anthropic.SystemPrompt.text(systemPrompt) : null;
    }

    // Temperature is incompatible with thinking — must not send both.
    // When thinking is skipped (e.g. for JSON schema), keep the temperature.
    final effectiveTemperature = (useAdaptiveThinking && !skipThinking) ? null : request.temperature;

    // Forward user as metadata.user_id (#21)
    final metadata = request.user != null ? anthropic.Metadata(userId: request.user) : null;

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
      metadata: metadata,
    );

    // Apply body transformer if provided (e.g. for cache breakpoints, or
    // injecting `thinking` / `output_config` from `extraBody`).
    //
    // If JSON schema structured output is active (`skipThinking == true`),
    // strip any `thinking` / `output_config` the transformer may have
    // injected — Anthropic 400s when forced `tool_choice` (the JSON-schema
    // tool) coexists with extended thinking.
    if (bodyTransformer != null || skipThinking) {
      final body = anthropicRequest.toJson();
      bodyTransformer?.call(body);
      if (skipThinking) {
        body.remove('thinking');
        body.remove('output_config');
      }
      anthropicRequest = anthropic.MessageCreateRequest.fromJson(
        _deepCastJson(body),
      );
    }

    // Auto-apply OAuth-specific request features (adaptive thinking) and
    // last-message cache_control via a single JSON round-trip when no caller-
    // supplied bodyTransformer has done the work for us.
    //
    // The two concerns are independent:
    //   * Thinking + effort_config are OAuth-only (require Claude Code beta
    //     headers).
    //   * cache_control on the last message is auth-agnostic — Anthropic's
    //     caching API treats x-api-key and OAuth Bearer identically.
    final needsThinkingInjection = isOAuth && useAdaptiveThinking && !skipThinking;
    final needsCacheInjection = cacheControl != null;

    if (needsThinkingInjection || needsCacheInjection) {
      final body = anthropicRequest.toJson();
      bool modified = false;

      if (needsThinkingInjection && !body.containsKey('thinking')) {
        body['thinking'] = {'type': 'adaptive'};
        // Inject default effort alongside adaptive thinking to prevent
        // unbounded thinking loops. Without effort, the API defaults to 'high'
        // which causes 10–20 minute thinking on complex prompts.
        // Requires the effort-2025-11-24 beta header.
        if (defaultEffort != null && !body.containsKey('output_config')) {
          body['output_config'] = {'effort': defaultEffort};
        }
        modified = true;
      }

      // Apply cache_control to the last message's last content block.
      // Respects cacheRetention (#9). Works on both OAuth and direct API paths.
      //
      // Reference: claude-code/src/services/api/claude.ts
      //   addCacheBreakpoints()            — lines 3063-3211
      //   userMessageToMessageParam()      — lines 588-631
      //   assistantMessageToMessageParam() — lines 633-674
      //
      // Key design decisions from reference (lines 3078-3088):
      //   - Exactly one message-level cache_control marker per request.
      //   - Mycro's turn-to-turn eviction frees local-attention KV pages
      //     at any cached prefix position NOT in
      //     cache_store_int_token_boundaries. With two markers the
      //     second-to-last position's locals survive an extra turn for
      //     nothing; with one marker they're freed immediately.
      //   - Marker goes on the absolute last message (any role).
      //   - For array content, marker goes on the last non-thinking block
      //     (ref: assistantMessageToMessageParam lines 658-661 skips
      //     'thinking' and 'redacted_thinking').
      if (needsCacheInjection) {
        final ccJson = cacheControl.toJson();
        final msgs = body['messages'];
        if (msgs is List) {
          for (int i = msgs.length - 1; i >= 0; i--) {
            final msg = msgs[i];
            if (msg is! Map) continue;
            final content = msg['content'];

            // String content → wrap to block format with cache_control.
            // Ref: userMessageToMessageParam lines 595-607 (string branch)
            if (content is String && content.isNotEmpty) {
              msg['content'] = [
                {
                  'type': 'text',
                  'text': content,
                  'cache_control': ccJson,
                },
              ];
              modified = true;
              break;
            } else if (content is List && content.isNotEmpty) {
              // Array content → walk backward to find last non-thinking block.
              // Ref: assistantMessageToMessageParam lines 656-665
              //   (skips 'thinking' and 'redacted_thinking')
              //
              // Intentional divergence from reference: the TS code targets
              // the absolute last block and silently skips the message if
              // it's a thinking block. We walk backward, which is more
              // defensive — we'll always find a cacheable block if one
              // exists. Also omits 'connector_text' exclusion (ref line
              // 661, feature-gated in TS, not yet shipped).
              for (int j = content.length - 1; j >= 0; j--) {
                final block = content[j];
                if (block is! Map) continue;
                final blockType = block['type'];
                if (blockType == 'thinking' || blockType == 'redacted_thinking') {
                  continue;
                }
                if (!block.containsKey('cache_control')) {
                  content[j] = <String, dynamic>{
                    for (final e in block.entries) e.key as String: e.value,
                    'cache_control': ccJson,
                  };
                  modified = true;
                }
                break;
              }
              break;
            }
            // Empty/null content — try previous message
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
    // 'user' is forwarded as metadata.user_id, not logged as unsupported.
    AnthropicOpenAILogger.logUnsupportedParam('store', request.store);
    AnthropicOpenAILogger.logUnsupportedParam('metadata', request.metadata);

    if (request.n != null && request.n! > 1) {
      AnthropicOpenAILogger.warn(
        'Parameter "n" > 1 is not supported by Anthropic. Only 1 choice will be returned.',
      );
    }
  }
}
