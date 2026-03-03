import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../mappers/stop_reason_mapper.dart';
import '../request/chat_completion_request_converter.dart'
    show jsonSchemaToolName;

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
    // Check if the response contains a JSON schema tool call (structured output).
    final jsonSchemaToolUse = anthropicMessage.toolUseBlocks
        .where((b) => b.name == jsonSchemaToolName)
        .firstOrNull;

    String? textContent;
    if (jsonSchemaToolUse != null) {
      // The structured output is in the tool's input — surface it as text content.
      textContent = jsonEncode(jsonSchemaToolUse.input);
    } else {
      final textParts =
          anthropicMessage.textBlocks.map((b) => b.text).toList();
      textContent = textParts.isEmpty ? null : textParts.join('\n');
    }

    // Extract real tool calls (excluding the JSON schema tool).
    final toolCalls = _extractToolCalls(anthropicMessage);

    // When JSON schema tool was used, the stop reason is "tool_use" but from
    // the caller's perspective this is a normal text response → map to "stop".
    final finishReason = jsonSchemaToolUse != null
        ? ChatCompletionFinishReason.stop
        : _stopReasonMapper.toOpenAI(anthropicMessage.stopReason);

    final assistantMessage = ChatCompletionMessage.assistant(
      content: textContent,
      toolCalls: toolCalls,
    );

    final choice = ChatCompletionResponseChoice(
      index: 0,
      message: assistantMessage as ChatCompletionAssistantMessage,
      finishReason: finishReason,
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

  /// Extracts tool calls from Anthropic response content blocks,
  /// excluding the internal [jsonSchemaToolName] tool.
  List<ChatCompletionMessageToolCall>? _extractToolCalls(
      anthropic.Message message) {
    final toolCalls = message.toolUseBlocks
        .where((toolUse) => toolUse.name != jsonSchemaToolName)
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
