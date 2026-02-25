import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';

/// Maps stop reasons between OpenAI and Anthropic formats.
class StopReasonMapper {
  /// Converts an Anthropic stop reason to an OpenAI finish reason.
  ///
  /// Mapping:
  /// - endTurn → stop
  /// - maxTokens → length
  /// - stopSequence → stop
  /// - toolUse → toolCalls
  /// - pauseTurn → stop (no direct equivalent)
  /// - refusal → contentFilter (closest equivalent)
  ChatCompletionFinishReason? toOpenAI(anthropic.StopReason? reason) {
    if (reason == null) return null;

    return switch (reason) {
      anthropic.StopReason.endTurn => ChatCompletionFinishReason.stop,
      anthropic.StopReason.maxTokens => ChatCompletionFinishReason.length,
      anthropic.StopReason.stopSequence => ChatCompletionFinishReason.stop,
      anthropic.StopReason.toolUse => ChatCompletionFinishReason.toolCalls,
      anthropic.StopReason.pauseTurn => ChatCompletionFinishReason.stop,
      anthropic.StopReason.refusal => ChatCompletionFinishReason.contentFilter,
    };
  }
}
