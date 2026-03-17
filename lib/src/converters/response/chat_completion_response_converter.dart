import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../mappers/stop_reason_mapper.dart';
import '../../utils/claude_code_tools.dart';
import '../request/chat_completion_request_converter.dart' show jsonSchemaToolName;

/// Result of converting an Anthropic response to OpenAI format.
///
/// Carries the OpenAI [ChatCompletion] plus Anthropic-specific cache token
/// fields that have no OpenAI equivalent. Use [toJson] to get the
/// completion's JSON with these fields injected into the `usage` object.
class ConvertedChatCompletion {
  final ChatCompletion completion;
  final int cacheCreationInputTokens;
  final int cacheReadInputTokens;

  const ConvertedChatCompletion({
    required this.completion,
    this.cacheCreationInputTokens = 0,
    this.cacheReadInputTokens = 0,
  });

  /// Returns the completion's JSON with Anthropic cache token fields injected
  /// into the `usage` object.
  Map<String, dynamic> toJson() {
    final json = completion.toJson();
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

/// Converts Anthropic message responses to OpenAI chat completion responses.
class ChatCompletionResponseConverter {
  final StopReasonMapper _stopReasonMapper;

  ChatCompletionResponseConverter({
    StopReasonMapper? stopReasonMapper,
  }) : _stopReasonMapper = stopReasonMapper ?? StopReasonMapper();

  /// Converts an Anthropic Message to an OpenAI ChatCompletion with
  /// Anthropic-specific cache token metadata.
  ConvertedChatCompletion convert(
    anthropic.Message anthropicMessage,
    String requestModel, {
    bool isOAuth = false,
    List<String>? originalToolNames,
  }) {
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
    final toolCalls = _extractToolCalls(
      anthropicMessage,
      isOAuth: isOAuth,
      originalToolNames: originalToolNames,
    );

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

    return ConvertedChatCompletion(
      completion: ChatCompletion(
        id: anthropicMessage.id,
        choices: [choice],
        created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        model: anthropicMessage.model,
        object: 'chat.completion',
        usage: _convertUsage(anthropicMessage.usage),
        provider: 'anthropic',
      ),
      cacheCreationInputTokens: anthropicMessage.usage.cacheCreationInputTokens ?? 0,
      cacheReadInputTokens: anthropicMessage.usage.cacheReadInputTokens ?? 0,
    );
  }

  /// Extracts tool calls from Anthropic response content blocks,
  /// excluding the internal [jsonSchemaToolName] tool.
  List<ToolCall>? _extractToolCalls(
    anthropic.Message message, {
    bool isOAuth = false,
    List<String>? originalToolNames,
  }) {
    final toolCalls = message.toolUseBlocks
        .where((toolUse) => toolUse.name != jsonSchemaToolName)
        .map(
          (toolUse) => ToolCall(
            id: toolUse.id,
            type: 'function',
            function: FunctionCall(
              name: isOAuth
                  ? fromClaudeCodeName(toolUse.name, originalToolNames)
                  : toolUse.name,
              arguments: jsonEncode(toolUse.input),
            ),
          ),
        )
        .toList();

    return toolCalls.isEmpty ? null : toolCalls;
  }

  /// Converts Anthropic usage to OpenAI usage.
  Usage _convertUsage(anthropic.Usage usage) {
    final inputTokens = usage.inputTokens;
    final outputTokens = usage.outputTokens;
    final cacheReadTokens = usage.cacheReadInputTokens ?? 0;
    final cacheCreationTokens = usage.cacheCreationInputTokens ?? 0;

    // Sum all input categories to match OpenAI's convention where
    // promptTokens is the total and cachedTokens is the cache-read subset.
    final totalPromptTokens = inputTokens + cacheReadTokens + cacheCreationTokens;

    return Usage(
      promptTokens: totalPromptTokens,
      completionTokens: outputTokens,
      totalTokens: totalPromptTokens + outputTokens,
      promptTokensDetails: cacheReadTokens > 0 ? PromptTokensDetails(cachedTokens: cacheReadTokens) : null,
    );
  }
}
