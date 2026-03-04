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
  /// - compaction → stop (no direct equivalent)
  /// - modelContextWindowExceeded → length (closest equivalent)
  FinishReason? toOpenAI(anthropic.StopReason? reason) {
    if (reason == null) return null;

    return switch (reason) {
      anthropic.StopReason.endTurn => FinishReason.stop,
      anthropic.StopReason.maxTokens => FinishReason.length,
      anthropic.StopReason.stopSequence => FinishReason.stop,
      anthropic.StopReason.toolUse => FinishReason.toolCalls,
      anthropic.StopReason.pauseTurn => FinishReason.stop,
      anthropic.StopReason.refusal => FinishReason.contentFilter,
      anthropic.StopReason.compaction => FinishReason.stop,
      anthropic.StopReason.modelContextWindowExceeded => FinishReason.length,
    };
  }
}
