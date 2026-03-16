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

    test('captures cache tokens from message_start when message_delta lacks them', () async {
      // Real Anthropic API behavior: cache fields come in message_start.message.usage,
      // NOT in message_delta.usage. The transformer must not lose them.
      final transformer = StreamEventTransformer(requestModel: 'claude-sonnet-4-20250514');

      final events = [
        anthropic.MessageStartEvent(
          message: anthropic.Message(
            id: 'msg_004',
            type: 'message',
            role: anthropic.MessageRole.assistant,
            content: [],
            model: 'claude-sonnet-4-20250514',
            stopReason: null,
            usage: anthropic.Usage(
              inputTokens: 100,
              outputTokens: 0,
              cacheCreationInputTokens: 17000,
              cacheReadInputTokens: 0,
            ),
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
        // message_delta only has output_tokens — no cache fields
        anthropic.MessageDeltaEvent(
          delta: anthropic.MessageDelta(stopReason: anthropic.StopReason.endTurn),
          usage: anthropic.MessageDeltaUsage(outputTokens: 5),
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

      // Cache creation tokens from message_start must appear in the output
      expect(usageJson['cache_creation_input_tokens'], 17000,
          reason: 'cache_creation_input_tokens from message_start should be preserved');

      // promptTokens should include input + cacheCreation
      expect(usageEvent.usage!.promptTokens, 17100); // 100 + 17000
    });

    test('captures cache read tokens from message_start when message_delta lacks them', () async {
      final transformer = StreamEventTransformer(requestModel: 'claude-sonnet-4-20250514');

      final events = [
        anthropic.MessageStartEvent(
          message: anthropic.Message(
            id: 'msg_005',
            type: 'message',
            role: anthropic.MessageRole.assistant,
            content: [],
            model: 'claude-sonnet-4-20250514',
            stopReason: null,
            usage: anthropic.Usage(
              inputTokens: 200,
              outputTokens: 0,
              cacheReadInputTokens: 15000,
            ),
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
          usage: anthropic.MessageDeltaUsage(outputTokens: 3),
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

      expect(usageJson['cache_read_input_tokens'], 15000);
      expect(usageEvent.usage!.promptTokens, 15200); // 200 + 15000
      expect(usageEvent.usage!.promptTokensDetails?.cachedTokens, 15000);
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
