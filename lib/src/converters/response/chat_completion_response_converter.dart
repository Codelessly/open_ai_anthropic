import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../mappers/stop_reason_mapper.dart';
import '../request/chat_completion_request_converter.dart' show jsonSchemaToolName;

/// Converts Anthropic message responses to OpenAI chat completion responses.
class ChatCompletionResponseConverter {
  final StopReasonMapper _stopReasonMapper;

  ChatCompletionResponseConverter({
    StopReasonMapper? stopReasonMapper,
  }) : _stopReasonMapper = stopReasonMapper ?? StopReasonMapper();

  /// Converts an Anthropic Message to an OpenAI ChatCompletion.
  ChatCompletion convert(
    anthropic.Message anthropicMessage,
    String requestModel,
  ) {
    // Check if the response contains a JSON schema tool call (structured output).
    final jsonSchemaToolUse = anthropicMessage.toolUseBlocks.where((b) => b.name == jsonSchemaToolName).firstOrNull;

    String? textContent;
    if (jsonSchemaToolUse != null) {
      // The structured output is in the tool's input — surface it as text content.
      textContent = jsonEncode(jsonSchemaToolUse.input);
    } else {
      final textParts = anthropicMessage.textBlocks.map((b) => b.text).toList();
      textContent = textParts.isEmpty ? null : textParts.join('\n');
    }

    // Extract real tool calls (excluding the JSON schema tool).
    final toolCalls = _extractToolCalls(anthropicMessage);

    // When JSON schema tool was used, the stop reason is "tool_use" but from
    // the caller's perspective this is a normal text response → map to "stop".
    final finishReason = jsonSchemaToolUse != null
        ? FinishReason.stop
        : _stopReasonMapper.toOpenAI(anthropicMessage.stopReason);

    final choice = ChatChoice(
      index: 0,
      message: AssistantMessage(
        content: textContent,
        toolCalls: toolCalls,
      ),
      finishReason: finishReason,
    );

    return ChatCompletion(
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
  List<ToolCall>? _extractToolCalls(anthropic.Message message) {
    final toolCalls = message.toolUseBlocks
        .where((toolUse) => toolUse.name != jsonSchemaToolName)
        .map(
          (toolUse) => ToolCall(
            id: toolUse.id,
            type: 'function',
            function: FunctionCall(
              name: toolUse.name,
              arguments: jsonEncode(toolUse.input),
            ),
          ),
        )
        .toList();

    return toolCalls.isEmpty ? null : toolCalls;
  }

  /// Converts Anthropic usage to OpenAI usage.
  Usage _convertUsage(anthropic.Usage usage) {
    return Usage(
      promptTokens: usage.inputTokens,
      completionTokens: usage.outputTokens,
      totalTokens: usage.inputTokens + usage.outputTokens,
    );
  }
}
