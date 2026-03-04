import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

/// Maps tools and tool calls between OpenAI and Anthropic formats.
class ToolMapper {
  /// Builds an [anthropic.InputSchema] from a raw JSON schema map.
  static anthropic.InputSchema buildInputSchema(Map<String, dynamic>? schema) {
    if (schema == null || schema.isEmpty) {
      return const anthropic.InputSchema(type: 'object');
    }
    final rawProperties = schema['properties'];
    final properties = rawProperties is Map<String, dynamic>
        ? rawProperties
        : rawProperties is Map
        ? Map<String, dynamic>.from(rawProperties)
        : null;
    return anthropic.InputSchema(
      type: schema['type'] as String? ?? 'object',
      properties: properties,
      required: (schema['required'] as List?)?.cast<String>(),
    );
  }

  /// Converts OpenAI tools to Anthropic tool definitions.
  List<anthropic.ToolDefinition>? toAnthropic(List<Tool>? tools) {
    if (tools == null || tools.isEmpty) return null;

    return tools.map((tool) {
      final function = tool.function;
      return anthropic.ToolDefinition.custom(
        anthropic.Tool(
          name: function.name,
          description: function.description,
          inputSchema: buildInputSchema(function.parameters),
        ),
      );
    }).toList();
  }

  /// Converts OpenAI tool choice to Anthropic tool choice.
  anthropic.ToolChoice? toAnthropicToolChoice(
    ToolChoice? toolChoice,
    bool? parallelToolCalls,
  ) {
    if (toolChoice == null) return null;

    final disableParallel = parallelToolCalls == null ? null : !parallelToolCalls;

    return switch (toolChoice) {
      ToolChoiceAuto() => anthropic.ToolChoice.auto(disableParallelToolUse: disableParallel),
      ToolChoiceRequired() => anthropic.ToolChoice.any(disableParallelToolUse: disableParallel),
      ToolChoiceNone() => null,
      ToolChoiceFunction(:final name) => anthropic.ToolChoice.tool(
        name,
        disableParallelToolUse: disableParallel,
      ),
    };
  }

  /// Extracts tool calls from Anthropic response content blocks.
  List<ToolCall>? extractToolCalls(List<anthropic.ContentBlock> blocks) {
    final toolCalls = blocks
        .whereType<anthropic.ToolUseBlock>()
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

  /// Converts an OpenAI tool message to an Anthropic tool result block.
  anthropic.InputContentBlock toToolResultBlock(
    String toolCallId,
    String? content, {
    bool? isError,
  }) {
    return anthropic.InputContentBlock.toolResult(
      toolUseId: toolCallId,
      content: [anthropic.ToolResultContent.text(content ?? '')],
      isError: isError,
    );
  }
}
