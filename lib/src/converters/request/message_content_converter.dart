import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../mappers/tool_mapper.dart';
import '../../utils/logger.dart';

/// Converts OpenAI message content to Anthropic message format.
class MessageContentConverter {
  final ToolMapper _toolMapper;

  MessageContentConverter({ToolMapper? toolMapper}) : _toolMapper = toolMapper ?? ToolMapper();

  /// Extracts the system prompt from OpenAI messages.
  ///
  /// In OpenAI, system prompts are messages with role "system" or "developer".
  /// In Anthropic, the system prompt is a top-level parameter.
  String? extractSystemPrompt(List<ChatMessage> messages) {
    final systemMessages = <String>[];

    for (final message in messages) {
      switch (message) {
        case SystemMessage(:final content):
          systemMessages.add(content);
        case DeveloperMessage(:final content):
          systemMessages.add(content);
        default:
          break;
      }
    }

    if (systemMessages.isEmpty) return null;
    return systemMessages.join('\n\n');
  }

  /// Converts OpenAI messages to Anthropic input messages.
  ///
  /// Filters out system/developer messages (handled separately as system prompt).
  List<anthropic.InputMessage> convertMessages(List<ChatMessage> messages) {
    final result = <anthropic.InputMessage>[];

    // Group tool messages that follow an assistant message with tool calls
    final pendingToolResults = <String, String>{};

    for (int i = 0; i < messages.length; i++) {
      final message = messages[i];

      switch (message) {
        case SystemMessage():
        case DeveloperMessage():
          // Skip - handled by extractSystemPrompt
          break;

        case UserMessage():
          // If there are pending tool results, send them first as a user message
          if (pendingToolResults.isNotEmpty) {
            result.add(_createToolResultMessage(pendingToolResults));
            pendingToolResults.clear();
          }

          result.add(
            anthropic.InputMessage(
              role: anthropic.MessageRole.user,
              content: _convertUserContent(message.content),
            ),
          );

        case AssistantMessage():
          // If there are pending tool results, send them first
          if (pendingToolResults.isNotEmpty) {
            result.add(_createToolResultMessage(pendingToolResults));
            pendingToolResults.clear();
          }

          result.add(
            anthropic.InputMessage(
              role: anthropic.MessageRole.assistant,
              content: _convertAssistantContent(message),
            ),
          );

        case ToolMessage(:final toolCallId, :final content):
          // Collect tool results to send as a single user message
          pendingToolResults[toolCallId] = content;
      }
    }

    // Send any remaining tool results
    if (pendingToolResults.isNotEmpty) {
      result.add(_createToolResultMessage(pendingToolResults));
    }

    // Validate that we have at least one message
    if (result.isEmpty) {
      throw ArgumentError(
        'At least one non-system message is required. '
        'Anthropic API requires at least one user or assistant message.',
      );
    }

    return result;
  }

  /// Creates an Anthropic user message containing tool results.
  anthropic.InputMessage _createToolResultMessage(
    Map<String, String> results,
  ) {
    final blocks = results.entries.map((entry) {
      return _toolMapper.toToolResultBlock(entry.key, entry.value);
    }).toList();

    return anthropic.InputMessage(
      role: anthropic.MessageRole.user,
      content: anthropic.MessageContent.blocks(blocks),
    );
  }

  /// Converts OpenAI user message content to Anthropic format.
  anthropic.MessageContent _convertUserContent(UserMessageContent content) {
    return switch (content) {
      UserTextContent(:final text) => anthropic.MessageContent.text(text),
      UserPartsContent(:final parts) => anthropic.MessageContent.blocks(
        parts.map(_convertContentPart).whereType<anthropic.InputContentBlock>().toList(),
      ),
    };
  }

  /// Converts a single content part to an Anthropic input block.
  anthropic.InputContentBlock? _convertContentPart(ContentPart part) {
    return switch (part) {
      TextContentPart(:final text) => anthropic.InputContentBlock.text(text),
      ImageContentPart(:final url) => _convertImagePart(url),
      AudioContentPart() => () {
        AnthropicOpenAILogger.warn(
          'Audio input is not supported by Anthropic and will be ignored.',
        );
        return null;
      }(),
    };
  }

  /// Converts an image content part to an Anthropic image block.
  anthropic.InputContentBlock _convertImagePart(String url) {
    // Check if it's a data URL (base64)
    if (url.startsWith('data:')) {
      return _convertDataUrlImage(url);
    }

    // It's a regular URL - use URL source
    return anthropic.InputContentBlock.image(
      anthropic.ImageSource.url(url),
    );
  }

  /// Converts a data URL to an Anthropic base64 image block.
  anthropic.InputContentBlock _convertDataUrlImage(String dataUrl) {
    // Parse data URL: data:[<mediatype>][;base64],<data>
    final regex = RegExp(r'data:([^;,]+)(?:;base64)?,(.+)');
    final match = regex.firstMatch(dataUrl);

    if (match == null) {
      throw FormatException('Invalid data URL format: $dataUrl');
    }

    final mediaType = match.group(1) ?? 'image/jpeg';
    final data = match.group(2) ?? '';

    // Map media types to Anthropic supported types
    final anthropicMediaType = switch (mediaType) {
      'image/png' => anthropic.ImageMediaType.png,
      'image/gif' => anthropic.ImageMediaType.gif,
      'image/webp' => anthropic.ImageMediaType.webp,
      _ => anthropic.ImageMediaType.jpeg, // Default to JPEG
    };

    return anthropic.InputContentBlock.image(
      anthropic.ImageSource.base64(data: data, mediaType: anthropicMediaType),
    );
  }

  /// Converts OpenAI assistant message content to Anthropic format.
  anthropic.MessageContent _convertAssistantContent(AssistantMessage msg) {
    final blocks = <anthropic.InputContentBlock>[];

    // Add text content if present
    if (msg.content != null && msg.content!.isNotEmpty) {
      blocks.add(anthropic.InputContentBlock.text(msg.content!));
    }

    // Add tool calls as tool_use blocks
    if (msg.toolCalls != null) {
      for (final toolCall in msg.toolCalls!) {
        blocks.add(
          anthropic.InputContentBlock.toolUse(
            id: toolCall.id,
            name: toolCall.function.name,
            input: _parseToolArguments(toolCall.function.arguments),
          ),
        );
      }
    }

    // If no blocks, return empty text
    if (blocks.isEmpty) {
      return anthropic.MessageContent.text('');
    }

    // If only one text block, return as text
    if (blocks.length == 1 && blocks.first is anthropic.TextInputBlock) {
      return anthropic.MessageContent.text(
        (blocks.first as anthropic.TextInputBlock).text,
      );
    }

    return anthropic.MessageContent.blocks(blocks);
  }

  /// Parses JSON tool arguments string to a Map.
  Map<String, dynamic> _parseToolArguments(String arguments) {
    if (arguments.isEmpty) return {};

    try {
      final parsed = jsonDecode(arguments);
      if (parsed is Map<String, dynamic>) {
        return parsed;
      }
      // Non-object JSON value, wrap in a 'value' key
      AnthropicOpenAILogger.warn(
        'Tool arguments is not a JSON object, wrapping in "value" key',
      );
      return {'value': parsed};
    } catch (e) {
      // If JSON parsing fails, return as a single string value
      AnthropicOpenAILogger.warn(
        'Failed to parse tool arguments as JSON: $e. '
        'Wrapping raw string in "value" key.',
      );
      return {'value': arguments};
    }
  }
}
