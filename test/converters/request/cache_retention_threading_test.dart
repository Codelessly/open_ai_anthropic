// Verifies that the per-call [CacheRetention] set on an [AnthropicOpenAIClient]
// is threaded all the way into [ChatCompletionRequestConverter.convert]. The
// converter itself is unit-tested for each retention value elsewhere; this
// closes the gap between the client's `cacheRetention` field and the converter
// call so a `CacheRetention.none` request actually omits cache_control on the
// wire (realizing the cache-write-premium skip for one-shot roles).

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:open_ai_anthropic/src/converters/request/chat_completion_request_converter.dart';
import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:test/test.dart';

/// Records the [CacheRetention] passed to [convert] without performing a real
/// conversion's network round-trip.
class _SpyConverter extends ChatCompletionRequestConverter {
  CacheRetention? lastCacheRetention;

  @override
  anthropic.MessageCreateRequest convert(
    oai.ChatCompletionCreateRequest request, {
    // ignore: avoid_renaming_method_parameters
    void Function(Map<String, dynamic> body)? bodyTransformer,
    bool isOAuth = false,
    CacheRetention cacheRetention = CacheRetention.short,
  }) {
    lastCacheRetention = cacheRetention;
    return super.convert(
      request,
      bodyTransformer: bodyTransformer,
      isOAuth: isOAuth,
      cacheRetention: cacheRetention,
    );
  }
}

void main() {
  group('AnthropicOpenAIClient cacheRetention threading', () {
    test('defaults to CacheRetention.short', () {
      final client = AnthropicOpenAIClient(apiKey: 'k');
      expect(client.cacheRetention, CacheRetention.short);
      client.close();
    });

    test('forwards the client cacheRetention into convert() on createStream', () {
      final spy = _SpyConverter();
      final client = AnthropicOpenAIClient(apiKey: 'k', requestConverter: spy);
      client.cacheRetention = CacheRetention.none;

      final request = oai.ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          oai.ChatMessage.system('a system prompt'),
          oai.ChatMessage.user('hi'),
        ],
      );

      // `convert()` runs synchronously inside `createStream` BEFORE the stream
      // is returned (and before any network await), so calling it is enough to
      // record the threaded value — we never subscribe.
      client.chat.completions.createStream(request);

      expect(spy.lastCacheRetention, CacheRetention.none);
      client.close();
    });

    test('forwards the client cacheRetention into convert() on create', () {
      final spy = _SpyConverter();
      final client = AnthropicOpenAIClient(apiKey: 'k', requestConverter: spy);
      client.cacheRetention = CacheRetention.long;

      final request = oai.ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [oai.ChatMessage.user('hi')],
      );

      // `create()` runs `convert()` synchronously before its first network
      // await; fire it without awaiting and swallow the resulting network
      // failure — the spy already recorded the threaded value.
      client.chat.completions.create(request).then((_) {}, onError: (_) {});

      expect(spy.lastCacheRetention, CacheRetention.long);
      client.close();
    });
  });
}
