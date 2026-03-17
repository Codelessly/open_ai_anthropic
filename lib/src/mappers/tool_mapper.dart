import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../utils/claude_code_tools.dart';

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
  ///
  /// When [isOAuth] is true, tool names are remapped to Claude Code canonical
  /// casing (e.g. "bash" → "Bash", "read" → "Read").
  List<anthropic.ToolDefinition>? toAnthropic(
    List<Tool>? tools, {
    bool isOAuth = false,
  }) {
    if (tools == null || tools.isEmpty) return null;

    return tools.map((tool) {
      final function = tool.function;
      final name = isOAuth
          ? toClaudeCodeName(function.name)
          : function.name;
      return anthropic.ToolDefinition.custom(
        anthropic.Tool(
          name: name,
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

  /// Converts an OpenAI tool message to an Anthropic tool result block.
  anthropic.InputContentBlock toToolResultBlock(
    String toolCallId,
    String? content, {
    bool? isError,
  }) {
    return anthropic.InputContentBlock.toolResult(
      toolUseId: normalizeToolCallId(toolCallId),
      content: [anthropic.ToolResultContent.text(content ?? '')],
      isError: isError,
    );
  }
}
