import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../mappers/stop_reason_mapper.dart';

/// Converts Anthropic message responses to OpenAI chat completion responses.
class ChatCompletionResponseConverter {
  final StopReasonMapper _stopReasonMapper;

  ChatCompletionResponseConverter({
    StopReasonMapper? stopReasonMapper,
  }) : _stopReasonMapper = stopReasonMapper ?? StopReasonMapper();

  /// Converts an Anthropic Message to an OpenAI CreateChatCompletionResponse.
  CreateChatCompletionResponse convert(
    anthropic.Message anthropicMessage,
    String requestModel,
  ) {
    final textContent = _extractTextContent(anthropicMessage.content);
    final toolCalls = _extractToolCalls(anthropicMessage.content);

    final assistantMessage = ChatCompletionMessage.assistant(
      content: textContent,
      toolCalls: toolCalls,
    );

    final choice = ChatCompletionResponseChoice(
      index: 0,
      message: assistantMessage as ChatCompletionAssistantMessage,
      finishReason: _stopReasonMapper.toOpenAI(anthropicMessage.stopReason),
      logprobs: null, // Anthropic doesn't provide logprobs
    );

    return CreateChatCompletionResponse(
      id: anthropicMessage.id ?? _generateId(),
      choices: [choice],
      created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      model: anthropicMessage.model ?? requestModel,
      object: 'chat.completion',
      usage: _convertUsage(anthropicMessage.usage),
      provider: 'anthropic',
    );
  }

  /// Extracts text content from Anthropic message content.
  String? _extractTextContent(anthropic.MessageContent content) {
    return content.map(
      text: (text) => text.value.isEmpty ? null : text.value,
      blocks: (blocks) {
        final textParts = blocks.value
            .map((block) => block.mapOrNull(
                  text: (textBlock) => textBlock.text,
                ))
            .whereType<String>()
            .toList();

        return textParts.isEmpty ? null : textParts.join('\n');
      },
    );
  }

  /// Extracts tool calls from Anthropic message content.
  List<ChatCompletionMessageToolCall>? _extractToolCalls(
    anthropic.MessageContent content,
  ) {
    return content.mapOrNull(
      blocks: (blocks) {
        final toolCalls = blocks.value
            .map((block) => block.mapOrNull(
                  toolUse: (toolUse) => ChatCompletionMessageToolCall(
                    id: toolUse.id,
                    type: ChatCompletionMessageToolCallType.function,
                    function: ChatCompletionMessageFunctionCall(
                      name: toolUse.name,
                      arguments: jsonEncode(toolUse.input),
                    ),
                  ),
                ))
            .whereType<ChatCompletionMessageToolCall>()
            .toList();

        return toolCalls.isEmpty ? null : toolCalls;
      },
    );
  }

  /// Converts Anthropic usage to OpenAI completion usage.
  CompletionUsage? _convertUsage(anthropic.Usage? usage) {
    if (usage == null) return null;

    return CompletionUsage(
      promptTokens: usage.inputTokens,
      completionTokens: usage.outputTokens,
      totalTokens: usage.inputTokens + usage.outputTokens,
    );
  }

  /// Generates a unique ID for the response.
  String _generateId() {
    return 'chatcmpl-${DateTime.now().millisecondsSinceEpoch}';
  }
}
