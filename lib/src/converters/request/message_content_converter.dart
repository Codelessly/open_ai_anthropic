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
  String? extractSystemPrompt(List<ChatCompletionMessage> messages) {
    final systemMessages = <String>[];

    for (final message in messages) {
      message.mapOrNull(
        system: (msg) => systemMessages.add(msg.content),
        developer: (msg) {
          final content = msg.content.map(
            parts: (parts) =>
                parts.value.map((part) => part.mapOrNull(text: (t) => t.text)).whereType<String>().join('\n'),
            text: (text) => text.value,
          );
          systemMessages.add(content);
          return content;
        },
      );
    }

    if (systemMessages.isEmpty) return null;
    return systemMessages.join('\n\n');
  }

  /// Converts OpenAI messages to Anthropic input messages.
  ///
  /// Filters out system/developer messages (handled separately as system prompt).
  List<anthropic.InputMessage> convertMessages(
    List<ChatCompletionMessage> messages,
  ) {
    final result = <anthropic.InputMessage>[];

    // Group tool messages that follow an assistant message with tool calls
    final pendingToolResults = <String, String>{};

    for (int i = 0; i < messages.length; i++) {
      final message = messages[i];

      message.mapOrNull(
        system: (_) {
          // Skip - handled by extractSystemPrompt
        },
        developer: (_) {
          // Skip - handled by extractSystemPrompt
        },
        user: (msg) {
          // If there are pending tool results, send them first as a user message
          if (pendingToolResults.isNotEmpty) {
            result.add(_createToolResultMessage(pendingToolResults));
            pendingToolResults.clear();
          }

          result.add(
            anthropic.InputMessage(
              role: anthropic.MessageRole.user,
              content: _convertUserContent(msg.content),
            ),
          );
        },
        assistant: (msg) {
          // If there are pending tool results, send them first
          if (pendingToolResults.isNotEmpty) {
            result.add(_createToolResultMessage(pendingToolResults));
            pendingToolResults.clear();
          }

          result.add(
            anthropic.InputMessage(
              role: anthropic.MessageRole.assistant,
              content: _convertAssistantContent(msg),
            ),
          );
        },
        tool: (msg) {
          // Collect tool results to send as a single user message
          pendingToolResults[msg.toolCallId] = msg.content;
        },
        function: (msg) {
          // Deprecated - log warning
          AnthropicOpenAILogger.warn(
            'Function messages are deprecated. Use tool messages instead.',
          );
        },
      );
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
  anthropic.MessageContent _convertUserContent(
    ChatCompletionUserMessageContent content,
  ) {
    return content.map(
      string: (text) => anthropic.MessageContent.text(text.value),
      parts: (parts) => anthropic.MessageContent.blocks(
        parts.value.map(_convertContentPart).whereType<anthropic.InputContentBlock>().toList(),
      ),
    );
  }

  /// Converts a single content part to an Anthropic input block.
  anthropic.InputContentBlock? _convertContentPart(
    ChatCompletionMessageContentPart part,
  ) {
    return part.mapOrNull(
      text: (textPart) => anthropic.InputContentBlock.text(textPart.text),
      image: (imagePart) => _convertImagePart(imagePart),
      audio: (audioPart) {
        AnthropicOpenAILogger.warn(
          'Audio input is not supported by Anthropic and will be ignored.',
        );
        return null;
      },
      refusal: (refusalPart) {
        // Convert refusal to text for compatibility
        return anthropic.InputContentBlock.text(
          '[Refusal]: ${refusalPart.refusal}',
        );
      },
    );
  }

  /// Converts an image content part to an Anthropic image block.
  anthropic.InputContentBlock _convertImagePart(
    ChatCompletionMessageContentPartImage part,
  ) {
    final url = part.imageUrl.url;

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
  anthropic.MessageContent _convertAssistantContent(
    ChatCompletionAssistantMessage msg,
  ) {
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
