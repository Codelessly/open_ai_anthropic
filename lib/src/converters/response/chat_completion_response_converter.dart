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
    final textParts = anthropicMessage.textBlocks.map((b) => b.text).toList();
    final textContent = textParts.isEmpty ? null : textParts.join('\n');
    final toolCalls = _extractToolCalls(anthropicMessage);

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
      id: anthropicMessage.id,
      choices: [choice],
      created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      model: anthropicMessage.model,
      object: 'chat.completion',
      usage: _convertUsage(anthropicMessage.usage),
      provider: 'anthropic',
    );
  }

  /// Extracts tool calls from Anthropic response content blocks.
  List<ChatCompletionMessageToolCall>? _extractToolCalls(anthropic.Message message) {
    final toolCalls = message.toolUseBlocks
        .map(
          (toolUse) => ChatCompletionMessageToolCall(
            id: toolUse.id,
            type: ChatCompletionMessageToolCallType.function,
            function: ChatCompletionMessageFunctionCall(
              name: toolUse.name,
              arguments: jsonEncode(toolUse.input),
            ),
          ),
        )
        .toList();

    return toolCalls.isEmpty ? null : toolCalls;
  }

  /// Converts Anthropic usage to OpenAI completion usage.
  CompletionUsage _convertUsage(anthropic.Usage usage) {
    return CompletionUsage(
      promptTokens: usage.inputTokens,
      completionTokens: usage.outputTokens,
      totalTokens: usage.inputTokens + usage.outputTokens,
    );
  }
}
