import 'dart:async';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../mappers/stop_reason_mapper.dart';
import '../../utils/claude_code_tools.dart';
import '../request/chat_completion_request_converter.dart' show jsonSchemaToolName;

/// Transforms Anthropic MessageStreamEvents to OpenAI ChatStreamEvents.
///
/// This transformer maintains state across the stream to properly map
/// Anthropic's block-based streaming to OpenAI's delta-based streaming.
class StreamEventTransformer extends StreamTransformerBase<anthropic.MessageStreamEvent, ChatStreamEvent> {
  final String _requestModel;
  final StopReasonMapper _stopReasonMapper;
  final bool _isOAuth;
  final List<String>? _originalToolNames;

  StreamEventTransformer({
    required String requestModel,
    StopReasonMapper? stopReasonMapper,
    bool isOAuth = false,
    List<String>? originalToolNames,
  }) : _requestModel = requestModel,
       _stopReasonMapper = stopReasonMapper ?? StopReasonMapper(),
       _isOAuth = isOAuth,
       _originalToolNames = originalToolNames;

  @override
  Stream<ChatStreamEvent> bind(Stream<anthropic.MessageStreamEvent> stream) {
    return _TransformingStream(
      source: stream,
      requestModel: _requestModel,
      stopReasonMapper: _stopReasonMapper,
      isOAuth: _isOAuth,
      originalToolNames: _originalToolNames,
    );
  }
}

class _TransformingStream extends Stream<ChatStreamEvent> {
  final Stream<anthropic.MessageStreamEvent> source;
  final String requestModel;
  final StopReasonMapper stopReasonMapper;
  final bool isOAuth;
  final List<String>? originalToolNames;

  _TransformingStream({
    required this.source,
    required this.requestModel,
    required this.stopReasonMapper,
    this.isOAuth = false,
    this.originalToolNames,
  });

  @override
  StreamSubscription<ChatStreamEvent> listen(
    void Function(ChatStreamEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final state = _StreamState(requestModel: requestModel);
    final controller = StreamController<ChatStreamEvent>();

    final subscription = source.listen(
      (event) {
        final responses = _transformEvent(event, state);
        for (final response in responses) {
          controller.add(response);
        }
      },
      onError: (error, stackTrace) {
        controller.addError(error, stackTrace);
      },
      onDone: () {
        controller.close();
      },
      cancelOnError: cancelOnError,
    );

    controller.onCancel = () => subscription.cancel();

    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  List<ChatStreamEvent> _transformEvent(
    anthropic.MessageStreamEvent event,
    _StreamState state,
  ) {
    return switch (event) {
      anthropic.MessageStartEvent() => _handleMessageStart(event, state),
      anthropic.MessageDeltaEvent() => _handleMessageDelta(event, state),
      anthropic.MessageStopEvent() => _handleMessageStop(event, state),
      anthropic.ContentBlockStartEvent() => _handleContentBlockStart(event, state),
      anthropic.ContentBlockDeltaEvent() => _handleContentBlockDelta(event, state),
      anthropic.ContentBlockStopEvent() => _handleContentBlockStop(event, state),
      anthropic.PingEvent() => [], // Ignore ping events
      anthropic.ErrorEvent() => throw _convertError(event),
    };
  }

  List<ChatStreamEvent> _handleMessageStart(
    anthropic.MessageStartEvent event,
    _StreamState state,
  ) {
    state.messageId = event.message.id;
    state.model = event.message.model;
    state.created = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Capture input usage — Anthropic reports cache token fields here,
    // and message_delta may only contain output_tokens.
    // Fall back to nested cache_creation/cache_read objects when flat fields are null,
    // as Anthropic may return data only in the nested format.
    final usage = event.message.usage;
    state.inputTokens = usage.inputTokens;
    state.cacheCreationInputTokens = usage.cacheCreationInputTokens ??
        (usage.cacheCreation != null
            ? usage.cacheCreation!.ephemeral5mInputTokens +
                usage.cacheCreation!.ephemeral1hInputTokens
            : 0);
    state.cacheReadInputTokens = usage.cacheReadInputTokens ??
        (usage.cacheRead != null
            ? usage.cacheRead!.ephemeral5mInputTokens +
                usage.cacheRead!.ephemeral1hInputTokens
            : 0);

    // Emit initial chunk with role
    return [
      _createResponse(
        state: state,
        delta: const ChatDelta(role: 'assistant'),
      ),
    ];
  }

  List<ChatStreamEvent> _handleMessageDelta(
    anthropic.MessageDeltaEvent event,
    _StreamState state,
  ) {
    // When JSON schema tool was used, the stop reason is "tool_use" but from
    // the caller's perspective this is a normal text response → map to "stop".
    final finishReason = state.jsonSchemaBlockIndices.isNotEmpty
        ? FinishReason.stop
        : stopReasonMapper.toOpenAI(event.delta.stopReason);

    // message_delta may only have output_tokens. Fall back to values
    // captured from message_start for input and cache token fields.
    final inputTokens = event.usage.inputTokens ?? state.inputTokens;
    final outputTokens = event.usage.outputTokens;
    final cacheReadTokens = event.usage.cacheReadInputTokens ?? state.cacheReadInputTokens;
    final cacheCreationTokens = event.usage.cacheCreationInputTokens ?? state.cacheCreationInputTokens;

    // Anthropic reports input_tokens as just the uncached portion.
    // Sum all input categories to match OpenAI's convention where
    // promptTokens is the total and cachedTokens is the cache-read subset.
    final totalPromptTokens = inputTokens + cacheReadTokens + cacheCreationTokens;

    final usage = Usage(
      promptTokens: totalPromptTokens,
      completionTokens: outputTokens,
      totalTokens: totalPromptTokens + outputTokens,
      promptTokensDetails: cacheReadTokens > 0 ? PromptTokensDetails(cachedTokens: cacheReadTokens) : null,
    );

    return [
      _createResponse(
        state: state,
        finishReason: finishReason,
        usage: usage,
        cacheCreationInputTokens: cacheCreationTokens,
        cacheReadInputTokens: cacheReadTokens,
      ),
    ];
  }

  List<ChatStreamEvent> _handleMessageStop(
    anthropic.MessageStopEvent event,
    _StreamState state,
  ) {
    // Message stop doesn't need to emit anything - the delta event has finish_reason
    return [];
  }

  List<ChatStreamEvent> _handleContentBlockStart(
    anthropic.ContentBlockStartEvent event,
    _StreamState state,
  ) {
    final block = event.contentBlock;

    return switch (block) {
      anthropic.TextBlock() || anthropic.ThinkingBlock() || anthropic.RedactedThinkingBlock() => [],
      anthropic.ToolUseBlock(:final id, :final name) => () {
        // JSON schema tool is an internal implementation detail — surface its
        // output as text content deltas instead of tool call chunks.
        if (name == jsonSchemaToolName) {
          state.jsonSchemaBlockIndices.add(event.index);
          return <ChatStreamEvent>[];
        }

        final toolCallIndex = state.toolCallCount++;
        state.blockToolCallIndex[event.index] = toolCallIndex;

        // Reverse-map CC canonical names back to original (#20)
        final resolvedName = isOAuth
            ? fromClaudeCodeName(name, originalToolNames)
            : name;

        return [
          _createResponse(
            state: state,
            delta: ChatDelta(
              toolCalls: [
                ToolCallDelta(
                  index: toolCallIndex,
                  id: id,
                  type: 'function',
                  function: FunctionCallDelta(
                    name: resolvedName,
                    arguments: '',
                  ),
                ),
              ],
            ),
          ),
        ];
      }(),
      anthropic.ServerToolUseBlock(:final id, :final name) => () {
        // Server tool use (e.g. MCP) is treated like a tool call
        final toolCallIndex = state.toolCallCount++;
        state.blockToolCallIndex[event.index] = toolCallIndex;

        final resolvedName = isOAuth
            ? fromClaudeCodeName(name, originalToolNames)
            : name;

        return [
          _createResponse(
            state: state,
            delta: ChatDelta(
              toolCalls: [
                ToolCallDelta(
                  index: toolCallIndex,
                  id: id,
                  type: 'function',
                  function: FunctionCallDelta(
                    name: resolvedName,
                    arguments: '',
                  ),
                ),
              ],
            ),
          ),
        ];
      }(),
      // All other block types (WebSearchToolResult, CodeExecution, etc.)
      _ => [],
    };
  }

  List<ChatStreamEvent> _handleContentBlockDelta(
    anthropic.ContentBlockDeltaEvent event,
    _StreamState state,
  ) {
    return switch (event.delta) {
      anthropic.TextDelta(:final text) => [
        _createResponse(
          state: state,
          delta: ChatDelta(content: text),
        ),
      ],
      anthropic.InputJsonDelta(:final partialJson) => () {
        // If this delta belongs to a JSON schema tool block, surface it as
        // text content instead of tool call arguments.
        if (state.jsonSchemaBlockIndices.contains(event.index)) {
          return [
            _createResponse(
              state: state,
              delta: ChatDelta(content: partialJson),
            ),
          ];
        }

        final toolCallIndex = _getToolCallIndex(state, event.index);
        if (toolCallIndex == null) {
          return <ChatStreamEvent>[];
        }

        return [
          _createResponse(
            state: state,
            delta: ChatDelta(
              toolCalls: [
                ToolCallDelta(
                  index: toolCallIndex,
                  function: FunctionCallDelta(
                    arguments: partialJson,
                  ),
                ),
              ],
            ),
          ),
        ];
      }(),
      anthropic.ThinkingDelta(:final thinking) => [
        _createResponse(
          state: state,
          delta: ChatDelta(
            reasoningContent: thinking,
          ),
        ),
      ],
      // Signature, citations, and compaction deltas have no OpenAI equivalent
      anthropic.SignatureDelta() || anthropic.CitationsDelta() || anthropic.CompactionDelta() => <ChatStreamEvent>[],
    };
  }

  List<ChatStreamEvent> _handleContentBlockStop(
    anthropic.ContentBlockStopEvent event,
    _StreamState state,
  ) {
    state.blockToolCallIndex.remove(event.index);
    // Note: jsonSchemaBlockIndices is NOT cleaned up here because
    // _handleMessageDelta needs it to fix the finish reason.
    return [];
  }

  int? _getToolCallIndex(_StreamState state, int blockIndex) {
    return state.blockToolCallIndex[blockIndex];
  }

  ChatStreamEvent _createResponse({
    required _StreamState state,
    ChatDelta? delta,
    FinishReason? finishReason,
    Usage? usage,
    int cacheCreationInputTokens = 0,
    int cacheReadInputTokens = 0,
  }) {
    final event = ChatStreamEvent(
      id: state.messageId,
      choices: [
        ChatStreamChoice(
          index: 0,
          delta: delta ?? const ChatDelta(),
          finishReason: finishReason,
        ),
      ],
      created: state.created,
      model: state.model,
      object: 'chat.completion.chunk',
      usage: usage,
      provider: 'anthropic',
    );

    // Wrap with Anthropic-specific cache fields if present.
    if (cacheCreationInputTokens > 0 || cacheReadInputTokens > 0) {
      return _AnthropicChatStreamEvent(
        base: event,
        cacheCreationInputTokens: cacheCreationInputTokens,
        cacheReadInputTokens: cacheReadInputTokens,
      );
    }

    return event;
  }

  Exception _convertError(anthropic.ErrorEvent event) {
    return Exception(
      'Anthropic stream error (${event.errorType}): ${event.message}',
    );
  }
}

/// A [ChatStreamEvent] that injects Anthropic-specific cache token fields
/// into its [toJson] output.
class _AnthropicChatStreamEvent extends ChatStreamEvent {
  final int cacheCreationInputTokens;
  final int cacheReadInputTokens;

  _AnthropicChatStreamEvent({
    required ChatStreamEvent base,
    required this.cacheCreationInputTokens,
    required this.cacheReadInputTokens,
  }) : super(
         id: base.id,
         object: base.object,
         created: base.created,
         model: base.model,
         choices: base.choices,
         usage: base.usage,
         systemFingerprint: base.systemFingerprint,
         serviceTier: base.serviceTier,
         provider: base.provider,
       );

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    final usage = json['usage'];
    if (usage is Map<String, dynamic>) {
      if (cacheCreationInputTokens > 0) {
        usage['cache_creation_input_tokens'] = cacheCreationInputTokens;
      }
      if (cacheReadInputTokens > 0) {
        usage['cache_read_input_tokens'] = cacheReadInputTokens;
      }
    }
    return json;
  }
}

/// Internal state maintained during stream transformation.
class _StreamState {
  String messageId;
  String model;
  int created;

  /// Maps content block index to its tool call index (only set for tool use blocks).
  final Map<int, int> blockToolCallIndex = {};
  int toolCallCount = 0;

  /// Block indices that belong to the internal JSON schema tool.
  /// Their input deltas are surfaced as text content, not tool call arguments.
  final Set<int> jsonSchemaBlockIndices = {};

  /// Input usage from `message_start`. Anthropic reports cache token fields
  /// here, and `message_delta` may only contain `output_tokens`.
  int inputTokens = 0;
  int cacheCreationInputTokens = 0;
  int cacheReadInputTokens = 0;

  _StreamState({required String requestModel})
    : messageId = 'chatcmpl-${DateTime.now().millisecondsSinceEpoch}',
      model = requestModel,
      created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
