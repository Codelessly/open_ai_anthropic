import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

/// Maps tools and tool calls between OpenAI and Anthropic formats.
class ToolMapper {
  /// Converts OpenAI tools to Anthropic tools.
  List<anthropic.Tool>? toAnthropic(List<ChatCompletionTool>? tools) {
    if (tools == null || tools.isEmpty) return null;

    return tools.map((tool) {
      final function = tool.function;
      return anthropic.Tool.custom(
        name: function.name,
        description: function.description,
        inputSchema: function.parameters ?? {'type': 'object'},
      );
    }).toList();
  }

  /// Converts OpenAI tool choice to Anthropic tool choice.
  anthropic.ToolChoice? toAnthropicToolChoice(
    ChatCompletionToolChoiceOption? toolChoice,
    bool? parallelToolCalls,
  ) {
    if (toolChoice == null) return null;

    return toolChoice.map(
      mode: (mode) => switch (mode.value) {
        ChatCompletionToolChoiceMode.auto => anthropic.ToolChoice(
            type: anthropic.ToolChoiceType.auto,
            disableParallelToolUse:
                parallelToolCalls == null ? null : !parallelToolCalls,
          ),
        ChatCompletionToolChoiceMode.required => anthropic.ToolChoice(
            type: anthropic.ToolChoiceType.any,
            disableParallelToolUse:
                parallelToolCalls == null ? null : !parallelToolCalls,
          ),
        ChatCompletionToolChoiceMode.none => null,
      },
      tool: (named) => anthropic.ToolChoice(
        type: anthropic.ToolChoiceType.tool,
        name: named.value.function.name,
        disableParallelToolUse:
            parallelToolCalls == null ? null : !parallelToolCalls,
      ),
    );
  }

  /// Extracts tool calls from Anthropic blocks and converts to OpenAI format.
  List<ChatCompletionMessageToolCall>? extractToolCalls(
    List<anthropic.Block> blocks,
  ) {
    final toolCalls = blocks
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
  }

  /// Converts OpenAI tool message to Anthropic tool result block.
  anthropic.Block toToolResultBlock(
    String toolCallId,
    String? content, {
    bool? isError,
  }) {
    return anthropic.Block.toolResult(
      toolUseId: toolCallId,
      content: anthropic.ToolResultBlockContent.text(content ?? ''),
      isError: isError,
    );
  }
}
