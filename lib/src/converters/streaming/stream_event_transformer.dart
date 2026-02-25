import 'dart:async';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../mappers/stop_reason_mapper.dart';

/// Transforms Anthropic MessageStreamEvents to OpenAI CreateChatCompletionStreamResponse.
///
/// This transformer maintains state across the stream to properly map
/// Anthropic's block-based streaming to OpenAI's delta-based streaming.
class StreamEventTransformer
    extends StreamTransformerBase<anthropic.MessageStreamEvent,
        CreateChatCompletionStreamResponse> {
  final String _requestModel;
  final StopReasonMapper _stopReasonMapper;

  StreamEventTransformer({
    required String requestModel,
    StopReasonMapper? stopReasonMapper,
  })  : _requestModel = requestModel,
        _stopReasonMapper = stopReasonMapper ?? StopReasonMapper();

  @override
  Stream<CreateChatCompletionStreamResponse> bind(
    Stream<anthropic.MessageStreamEvent> stream,
  ) {
    return _TransformingStream(
      source: stream,
      requestModel: _requestModel,
      stopReasonMapper: _stopReasonMapper,
    );
  }
}

class _TransformingStream extends Stream<CreateChatCompletionStreamResponse> {
  final Stream<anthropic.MessageStreamEvent> source;
  final String requestModel;
  final StopReasonMapper stopReasonMapper;

  _TransformingStream({
    required this.source,
    required this.requestModel,
    required this.stopReasonMapper,
  });

  @override
  StreamSubscription<CreateChatCompletionStreamResponse> listen(
    void Function(CreateChatCompletionStreamResponse event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final state = _StreamState(requestModel: requestModel);
    final controller = StreamController<CreateChatCompletionStreamResponse>();

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

  List<CreateChatCompletionStreamResponse> _transformEvent(
    anthropic.MessageStreamEvent event,
    _StreamState state,
  ) {
    return event.map(
      messageStart: (e) => _handleMessageStart(e, state),
      messageDelta: (e) => _handleMessageDelta(e, state),
      messageStop: (e) => _handleMessageStop(e, state),
      contentBlockStart: (e) => _handleContentBlockStart(e, state),
      contentBlockDelta: (e) => _handleContentBlockDelta(e, state),
      contentBlockStop: (e) => _handleContentBlockStop(e, state),
      ping: (_) => [], // Ignore ping events
      error: (e) => throw _convertError(e),
    );
  }

  List<CreateChatCompletionStreamResponse> _handleMessageStart(
    anthropic.MessageStartEvent event,
    _StreamState state,
  ) {
    state.messageId = event.message.id ?? _generateId();
    state.model = event.message.model ?? requestModel;
    state.created = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Emit initial chunk with role
    return [
      _createResponse(
        state: state,
        delta: const ChatCompletionStreamResponseDelta(
          role: ChatCompletionMessageRole.assistant,
        ),
      ),
    ];
  }

  List<CreateChatCompletionStreamResponse> _handleMessageDelta(
    anthropic.MessageDeltaEvent event,
    _StreamState state,
  ) {
    final finishReason = stopReasonMapper.toOpenAI(event.delta.stopReason);

    // Convert usage if present
    CompletionUsage? usage;
    final outputTokens = event.usage.outputTokens;
    // We don't have input tokens in the delta, so use 0 as placeholder
    usage = CompletionUsage(
      promptTokens: 0, // Not available in delta
      completionTokens: outputTokens,
      totalTokens: outputTokens,
    );

    return [
      _createResponse(
        state: state,
        finishReason: finishReason,
        usage: usage,
      ),
    ];
  }

  List<CreateChatCompletionStreamResponse> _handleMessageStop(
    anthropic.MessageStopEvent event,
    _StreamState state,
  ) {
    // Message stop doesn't need to emit anything - the delta event has finish_reason
    return [];
  }

  List<CreateChatCompletionStreamResponse> _handleContentBlockStart(
    anthropic.ContentBlockStartEvent event,
    _StreamState state,
  ) {
    final block = event.contentBlock;

    return block.map(
      text: (_) {
        // Text blocks don't need a start event in OpenAI format
        state.currentBlockTypes[event.index] = _BlockType.text;
        return <CreateChatCompletionStreamResponse>[];
      },
      image: (_) {
        // Image blocks are not streamed in OpenAI format
        state.currentBlockTypes[event.index] = _BlockType.image;
        return <CreateChatCompletionStreamResponse>[];
      },
      toolUse: (toolUse) {
        // Track this as a tool use block
        state.currentBlockTypes[event.index] = _BlockType.toolUse;
        final toolCallIndex = state.toolCallCount++;

        // Emit tool call start with id and name
        return [
          _createResponse(
            state: state,
            delta: ChatCompletionStreamResponseDelta(
              toolCalls: [
                ChatCompletionStreamMessageToolCallChunk(
                  index: toolCallIndex,
                  id: toolUse.id,
                  type: ChatCompletionStreamMessageToolCallChunkType.function,
                  function: ChatCompletionStreamMessageFunctionCall(
                    name: toolUse.name,
                    arguments: '',
                  ),
                ),
              ],
            ),
          ),
        ];
      },
      toolResult: (_) {
        // Tool results are not streamed from assistant
        state.currentBlockTypes[event.index] = _BlockType.toolResult;
        return <CreateChatCompletionStreamResponse>[];
      },
      thinking: (_) {
        // Thinking blocks can be mapped to reasoning content
        state.currentBlockTypes[event.index] = _BlockType.thinking;
        return <CreateChatCompletionStreamResponse>[];
      },
      redactedThinking: (_) {
        state.currentBlockTypes[event.index] = _BlockType.redactedThinking;
        return <CreateChatCompletionStreamResponse>[];
      },
      document: (_) {
        state.currentBlockTypes[event.index] = _BlockType.document;
        return <CreateChatCompletionStreamResponse>[];
      },
      serverToolUse: (_) {
        state.currentBlockTypes[event.index] = _BlockType.serverToolUse;
        return <CreateChatCompletionStreamResponse>[];
      },
      webSearchToolResult: (_) {
        state.currentBlockTypes[event.index] = _BlockType.webSearchToolResult;
        return <CreateChatCompletionStreamResponse>[];
      },
      mCPToolUse: (mcpToolUse) {
        // MCP tool use is similar to regular tool use
        state.currentBlockTypes[event.index] = _BlockType.mcpToolUse;
        final toolCallIndex = state.toolCallCount++;

        return [
          _createResponse(
            state: state,
            delta: ChatCompletionStreamResponseDelta(
              toolCalls: [
                ChatCompletionStreamMessageToolCallChunk(
                  index: toolCallIndex,
                  id: mcpToolUse.id,
                  type: ChatCompletionStreamMessageToolCallChunkType.function,
                  function: ChatCompletionStreamMessageFunctionCall(
                    name: mcpToolUse.name,
                    arguments: '',
                  ),
                ),
              ],
            ),
          ),
        ];
      },
      mCPToolResult: (_) {
        state.currentBlockTypes[event.index] = _BlockType.mcpToolResult;
        return <CreateChatCompletionStreamResponse>[];
      },
      searchResult: (_) {
        state.currentBlockTypes[event.index] = _BlockType.searchResult;
        return <CreateChatCompletionStreamResponse>[];
      },
      codeExecutionToolResult: (_) {
        state.currentBlockTypes[event.index] = _BlockType.codeExecutionToolResult;
        return <CreateChatCompletionStreamResponse>[];
      },
      containerUpload: (_) {
        state.currentBlockTypes[event.index] = _BlockType.containerUpload;
        return <CreateChatCompletionStreamResponse>[];
      },
    );
  }

  List<CreateChatCompletionStreamResponse> _handleContentBlockDelta(
    anthropic.ContentBlockDeltaEvent event,
    _StreamState state,
  ) {
    return event.delta.map(
      textDelta: (textDelta) {
        // Emit text content delta
        return [
          _createResponse(
            state: state,
            delta: ChatCompletionStreamResponseDelta(
              content: textDelta.text,
            ),
          ),
        ];
      },
      inputJsonDelta: (inputJson) {
        // Emit tool call arguments delta
        final toolCallIndex = _getToolCallIndex(state, event.index);
        if (toolCallIndex == null) return <CreateChatCompletionStreamResponse>[];

        return [
          _createResponse(
            state: state,
            delta: ChatCompletionStreamResponseDelta(
              toolCalls: [
                ChatCompletionStreamMessageToolCallChunk(
                  index: toolCallIndex,
                  function: ChatCompletionStreamMessageFunctionCall(
                    arguments: inputJson.partialJson ?? '',
                  ),
                ),
              ],
            ),
          ),
        ];
      },
      thinking: (thinking) {
        // Map thinking to reasoning_content field
        return [
          _createResponse(
            state: state,
            delta: ChatCompletionStreamResponseDelta(
              reasoningContent: thinking.thinking,
            ),
          ),
        ];
      },
      signature: (_) {
        // Signature blocks don't have an OpenAI equivalent
        return <CreateChatCompletionStreamResponse>[];
      },
      citations: (_) {
        // Citations don't have a direct OpenAI equivalent
        return <CreateChatCompletionStreamResponse>[];
      },
    );
  }

  List<CreateChatCompletionStreamResponse> _handleContentBlockStop(
    anthropic.ContentBlockStopEvent event,
    _StreamState state,
  ) {
    // Content block stop doesn't need to emit anything in OpenAI format
    return [];
  }

  int? _getToolCallIndex(_StreamState state, int blockIndex) {
    // Count how many tool use blocks came before this index
    int toolCallIndex = 0;
    for (int i = 0; i < blockIndex; i++) {
      final type = state.currentBlockTypes[i];
      if (type == _BlockType.toolUse || type == _BlockType.mcpToolUse) {
        toolCallIndex++;
      }
    }

    final currentType = state.currentBlockTypes[blockIndex];
    if (currentType == _BlockType.toolUse ||
        currentType == _BlockType.mcpToolUse) {
      return toolCallIndex;
    }

    return null;
  }

  CreateChatCompletionStreamResponse _createResponse({
    required _StreamState state,
    ChatCompletionStreamResponseDelta? delta,
    ChatCompletionFinishReason? finishReason,
    CompletionUsage? usage,
  }) {
    return CreateChatCompletionStreamResponse(
      id: state.messageId,
      choices: [
        ChatCompletionStreamResponseChoice(
          index: 0,
          delta: delta,
          finishReason: finishReason,
        ),
      ],
      created: state.created,
      model: state.model,
      object: 'chat.completion.chunk',
      usage: usage,
      provider: 'anthropic',
    );
  }

  Exception _convertError(anthropic.ErrorEvent event) {
    return Exception('Anthropic stream error: ${event.error.message}');
  }

  String _generateId() {
    return 'chatcmpl-${DateTime.now().millisecondsSinceEpoch}';
  }
}

/// Internal state maintained during stream transformation.
class _StreamState {
  String messageId;
  String model;
  int created;
  final Map<int, _BlockType> currentBlockTypes = {};
  int toolCallCount = 0;

  _StreamState({required String requestModel})
      : messageId = 'chatcmpl-${DateTime.now().millisecondsSinceEpoch}',
        model = requestModel,
        created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
}

/// Types of content blocks we track during streaming.
enum _BlockType {
  text,
  image,
  toolUse,
  toolResult,
  thinking,
  redactedThinking,
  document,
  serverToolUse,
  webSearchToolResult,
  mcpToolUse,
  mcpToolResult,
  searchResult,
  codeExecutionToolResult,
  containerUpload,
}
