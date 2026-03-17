import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

import '../../mappers/tool_mapper.dart';
import '../../utils/claude_code_tools.dart';
import '../../utils/logger.dart';

/// Strips lone Unicode surrogates that can cause API errors.
/// Dart strings can contain these when handling external data.
String _sanitizeSurrogates(String text) {
  // Match lone high surrogates (U+D800-U+DBFF) not followed by a low surrogate,
  // and lone low surrogates (U+DC00-U+DFFF) not preceded by a high surrogate.
  return text.replaceAll(RegExp(r'[\uD800-\uDFFF]'), '');
}

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
  /// Inserts synthetic error tool results for orphaned tool calls (#16).
  /// Filters empty user messages (#23).
  /// Normalizes tool call IDs for cross-provider compatibility (#10).
  List<anthropic.InputMessage> convertMessages(List<ChatMessage> messages) {
    final result = <anthropic.InputMessage>[];

    // Group tool messages that follow an assistant message with tool calls
    final pendingToolResults = <String, String>{};

    // Track tool call IDs from the last assistant message that had tool calls,
    // so we can detect orphaned calls.
    var pendingToolCallIds = <String>{};

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
            // Insert synthetic error results for any orphaned tool calls
            _insertSyntheticResults(pendingToolCallIds, pendingToolResults);
            result.add(_createToolResultMessage(pendingToolResults));
            pendingToolResults.clear();
            pendingToolCallIds.clear();
          } else if (pendingToolCallIds.isNotEmpty) {
            // Assistant had tool calls but no tool results at all — all orphaned
            final syntheticResults = <String, String>{};
            _insertSyntheticResults(pendingToolCallIds, syntheticResults);
            if (syntheticResults.isNotEmpty) {
              result.add(_createToolResultMessage(syntheticResults));
            }
            pendingToolCallIds.clear();
          }

          // Skip empty user messages (#23)
          final userContent = message.content;
          if (userContent is UserTextContent && userContent.text.trim().isEmpty) {
            break;
          }

          result.add(
            anthropic.InputMessage(
              role: anthropic.MessageRole.user,
              content: _convertUserContent(userContent),
            ),
          );

        case AssistantMessage():
          // If there are pending tool results, send them first
          if (pendingToolResults.isNotEmpty) {
            _insertSyntheticResults(pendingToolCallIds, pendingToolResults);
            result.add(_createToolResultMessage(pendingToolResults));
            pendingToolResults.clear();
            pendingToolCallIds.clear();
          } else if (pendingToolCallIds.isNotEmpty) {
            // Previous assistant's tool calls were all orphaned
            final syntheticResults = <String, String>{};
            _insertSyntheticResults(pendingToolCallIds, syntheticResults);
            if (syntheticResults.isNotEmpty) {
              result.add(_createToolResultMessage(syntheticResults));
            }
            pendingToolCallIds.clear();
          }

          // Track tool call IDs from this assistant message
          pendingToolCallIds = {};
          if (message.toolCalls != null) {
            for (final tc in message.toolCalls!) {
              pendingToolCallIds.add(tc.id);
            }
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

    // Send any remaining tool results (with synthetic results for orphans)
    if (pendingToolResults.isNotEmpty) {
      _insertSyntheticResults(pendingToolCallIds, pendingToolResults);
      result.add(_createToolResultMessage(pendingToolResults));
    } else if (pendingToolCallIds.isNotEmpty) {
      // End of messages with orphaned tool calls
      final syntheticResults = <String, String>{};
      _insertSyntheticResults(pendingToolCallIds, syntheticResults);
      if (syntheticResults.isNotEmpty) {
        result.add(_createToolResultMessage(syntheticResults));
      }
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

  /// Inserts synthetic error tool results for any tool call IDs that don't
  /// already have a result in [results].
  void _insertSyntheticResults(
    Set<String> toolCallIds,
    Map<String, String> results,
  ) {
    for (final id in toolCallIds) {
      if (!results.containsKey(id)) {
        results[id] = 'No result provided';
      }
    }
  }

  /// Creates an Anthropic user message containing tool results.
  anthropic.InputMessage _createToolResultMessage(
    Map<String, String> results,
  ) {
    final blocks = results.entries.map((entry) {
      final isError = entry.value == 'No result provided';
      return _toolMapper.toToolResultBlock(entry.key, entry.value, isError: isError ? true : null);
    }).toList();

    return anthropic.InputMessage(
      role: anthropic.MessageRole.user,
      content: anthropic.MessageContent.blocks(blocks),
    );
  }

  /// Converts OpenAI user message content to Anthropic format.
  /// If parts content has only images (no text), prepends a placeholder (#22).
  anthropic.MessageContent _convertUserContent(UserMessageContent content) {
    return switch (content) {
      UserTextContent(:final text) => anthropic.MessageContent.text(_sanitizeSurrogates(text)),
      UserPartsContent(:final parts) => () {
        final blocks = parts
            .map(_convertContentPart)
            .whereType<anthropic.InputContentBlock>()
            .toList();
        // If only images (no text blocks), prepend a placeholder (#22)
        final hasText = blocks.any((b) => b is anthropic.TextInputBlock);
        if (!hasText && blocks.isNotEmpty) {
          blocks.insert(0, anthropic.InputContentBlock.text('(see attached image)'));
        }
        return anthropic.MessageContent.blocks(blocks);
      }(),
    };
  }

  /// Converts a single content part to an Anthropic input block.
  anthropic.InputContentBlock? _convertContentPart(ContentPart part) {
    return switch (part) {
      TextContentPart(:final text) => anthropic.InputContentBlock.text(_sanitizeSurrogates(text)),
      ImageContentPart(:final url) => _convertImagePart(url),
      AudioContentPart() => () {
        AnthropicOpenAILogger.warn(
          'Audio input is not supported by Anthropic and will be ignored.',
        );
        return null;
      }(),
    };
  }

  /// Converts a binary content part to the appropriate Anthropic block.
  anthropic.InputContentBlock _convertImagePart(String url) {
    final uri = Uri.tryParse(url);
    final dataUri = uri?.data;

    // Not a data URI — forward as a plain URL.
    if (dataUri == null) {
      return anthropic.InputContentBlock.image(
        anthropic.ImageSource.url(url),
      );
    }

    final mimeType = dataUri.mimeType;
    final base64Data = dataUri.contentText;

    // PDF → document block.
    if (mimeType == 'application/pdf') {
      return anthropic.InputContentBlock.document(
        anthropic.DocumentSource.base64Pdf(base64Data),
      );
    }

    // Image (or unknown) → image block.
    final anthropicMediaType = switch (mimeType) {
      'image/png' => anthropic.ImageMediaType.png,
      'image/gif' => anthropic.ImageMediaType.gif,
      'image/webp' => anthropic.ImageMediaType.webp,
      _ => anthropic.ImageMediaType.jpeg,
    };

    return anthropic.InputContentBlock.image(
      anthropic.ImageSource.base64(data: base64Data, mediaType: anthropicMediaType),
    );
  }

  /// Converts OpenAI assistant message content to Anthropic format.
  anthropic.MessageContent _convertAssistantContent(AssistantMessage msg) {
    final blocks = <anthropic.InputContentBlock>[];

    // Add text content if present and non-empty (#13), sanitized (#18)
    if (msg.content != null && msg.content!.trim().isNotEmpty) {
      blocks.add(anthropic.InputContentBlock.text(_sanitizeSurrogates(msg.content!)));
    }

    // Add tool calls as tool_use blocks with normalized IDs (#10)
    if (msg.toolCalls != null) {
      for (final toolCall in msg.toolCalls!) {
        blocks.add(
          anthropic.InputContentBlock.toolUse(
            id: normalizeToolCallId(toolCall.id),
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
      AnthropicOpenAILogger.warn(
        'Tool arguments is not a JSON object, wrapping in "value" key',
      );
      return {'value': parsed};
    } catch (e) {
      AnthropicOpenAILogger.warn(
        'Failed to parse tool arguments as JSON: $e. '
        'Wrapping raw string in "value" key.',
      );
      return {'value': arguments};
    }
  }
}
