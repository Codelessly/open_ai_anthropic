import 'dart:async';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:openai_dart/openai_dart.dart';
import 'package:test/test.dart';

import 'package:open_ai_anthropic/src/converters/streaming/stream_event_transformer.dart';

void main() {
  group('StreamEventTransformer cache token reporting', () {
    test('includes cache_creation_input_tokens in toJson usage', () async {
      final transformer = StreamEventTransformer(requestModel: 'claude-sonnet-4-20250514');

      final events = [
        anthropic.MessageStartEvent(
          message: anthropic.Message(
            id: 'msg_001',
            type: 'message',
            role: anthropic.MessageRole.assistant,
            content: [],
            model: 'claude-sonnet-4-20250514',
            stopReason: null,
            usage: anthropic.Usage(inputTokens: 100, outputTokens: 0),
          ),
        ),
        anthropic.ContentBlockStartEvent(
          index: 0,
          contentBlock: anthropic.TextBlock(text: ''),
        ),
        anthropic.ContentBlockDeltaEvent(
          index: 0,
          delta: anthropic.TextDelta('Hello'),
        ),
        anthropic.ContentBlockStopEvent(index: 0),
        anthropic.MessageDeltaEvent(
          delta: anthropic.MessageDelta(stopReason: anthropic.StopReason.endTurn),
          usage: anthropic.MessageDeltaUsage(
            outputTokens: 5,
            inputTokens: 100,
            cacheCreationInputTokens: 500,
            cacheReadInputTokens: 0,
          ),
        ),
        anthropic.MessageStopEvent(),
      ];

      final controller = StreamController<anthropic.MessageStreamEvent>();
      final outputEvents = <ChatStreamEvent>[];

      controller.stream.transform(transformer).listen(outputEvents.add);
      for (final event in events) {
        controller.add(event);
      }
      await controller.close();

      // Find the event with usage (from MessageDelta)
      final usageEvent = outputEvents.where((e) => e.usage != null).first;
      final json = usageEvent.toJson();
      final usageJson = json['usage'] as Map<String, dynamic>;

      expect(usageJson['cache_creation_input_tokens'], 500,
          reason: 'cache_creation_input_tokens should be in toJson output');
    });

    test('includes cache_read_input_tokens in toJson usage', () async {
      final transformer = StreamEventTransformer(requestModel: 'claude-sonnet-4-20250514');

      final events = [
        anthropic.MessageStartEvent(
          message: anthropic.Message(
            id: 'msg_002',
            type: 'message',
            role: anthropic.MessageRole.assistant,
            content: [],
            model: 'claude-sonnet-4-20250514',
            stopReason: null,
            usage: anthropic.Usage(inputTokens: 50, outputTokens: 0),
          ),
        ),
        anthropic.ContentBlockStartEvent(
          index: 0,
          contentBlock: anthropic.TextBlock(text: ''),
        ),
        anthropic.ContentBlockDeltaEvent(
          index: 0,
          delta: anthropic.TextDelta('Hi'),
        ),
        anthropic.ContentBlockStopEvent(index: 0),
        anthropic.MessageDeltaEvent(
          delta: anthropic.MessageDelta(stopReason: anthropic.StopReason.endTurn),
          usage: anthropic.MessageDeltaUsage(
            outputTokens: 3,
            inputTokens: 50,
            cacheCreationInputTokens: 100,
            cacheReadInputTokens: 400,
          ),
        ),
        anthropic.MessageStopEvent(),
      ];

      final controller = StreamController<anthropic.MessageStreamEvent>();
      final outputEvents = <ChatStreamEvent>[];

      controller.stream.transform(transformer).listen(outputEvents.add);
      for (final event in events) {
        controller.add(event);
      }
      await controller.close();

      final usageEvent = outputEvents.where((e) => e.usage != null).first;
      final json = usageEvent.toJson();
      final usageJson = json['usage'] as Map<String, dynamic>;

      expect(usageJson['cache_creation_input_tokens'], 100);
      expect(usageJson['cache_read_input_tokens'], 400);
    });

    test('omits cache fields from toJson when zero', () async {
      final transformer = StreamEventTransformer(requestModel: 'claude-sonnet-4-20250514');

      final events = [
        anthropic.MessageStartEvent(
          message: anthropic.Message(
            id: 'msg_003',
            type: 'message',
            role: anthropic.MessageRole.assistant,
            content: [],
            model: 'claude-sonnet-4-20250514',
            stopReason: null,
            usage: anthropic.Usage(inputTokens: 100, outputTokens: 0),
          ),
        ),
        anthropic.ContentBlockStartEvent(
          index: 0,
          contentBlock: anthropic.TextBlock(text: ''),
        ),
        anthropic.ContentBlockDeltaEvent(
          index: 0,
          delta: anthropic.TextDelta('Hi'),
        ),
        anthropic.ContentBlockStopEvent(index: 0),
        anthropic.MessageDeltaEvent(
          delta: anthropic.MessageDelta(stopReason: anthropic.StopReason.endTurn),
          usage: anthropic.MessageDeltaUsage(
            outputTokens: 3,
            inputTokens: 100,
          ),
        ),
        anthropic.MessageStopEvent(),
      ];

      final controller = StreamController<anthropic.MessageStreamEvent>();
      final outputEvents = <ChatStreamEvent>[];

      controller.stream.transform(transformer).listen(outputEvents.add);
      for (final event in events) {
        controller.add(event);
      }
      await controller.close();

      final usageEvent = outputEvents.where((e) => e.usage != null).first;
      final json = usageEvent.toJson();
      final usageJson = json['usage'] as Map<String, dynamic>;

      expect(usageJson.containsKey('cache_creation_input_tokens'), isFalse);
      expect(usageJson.containsKey('cache_read_input_tokens'), isFalse);
    });
  });
}
