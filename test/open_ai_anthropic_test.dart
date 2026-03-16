import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:test/test.dart';

void main() {
  group('AnthropicOpenAIClient', () {
    test('can be instantiated', () {
      final client = AnthropicOpenAIClient(apiKey: 'test-key');
      expect(client, isNotNull);
      client.close();
    });

    test('accepts bodyTransformer parameter', () {
      final client = AnthropicOpenAIClient(
        apiKey: 'test-key',
        bodyTransformer: (body) {},
      );
      expect(client, isNotNull);
      expect(client.bodyTransformer, isNotNull);
      client.close();
    });

    test('bodyTransformer defaults to null', () {
      final client = AnthropicOpenAIClient(apiKey: 'test-key');
      expect(client.bodyTransformer, isNull);
      client.close();
    });
  });
}
