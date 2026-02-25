import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:test/test.dart';

void main() {
  group('AnthropicOpenAIClient', () {
    test('can be instantiated', () {
      final client = AnthropicOpenAIClient(apiKey: 'test-key');
      expect(client, isNotNull);
      client.endSession();
    });

    test('createEmbedding throws UnsupportedError', () {
      final client = AnthropicOpenAIClient(apiKey: 'test-key');
      expect(
        () => client.createEmbedding(request: throw UnimplementedError()),
        throwsUnsupportedError,
      );
      client.endSession();
    });

    test('createImage throws UnsupportedError', () {
      final client = AnthropicOpenAIClient(apiKey: 'test-key');
      expect(
        () => client.createImage(request: throw UnimplementedError()),
        throwsUnsupportedError,
      );
      client.endSession();
    });

    test('listModels throws UnsupportedError', () {
      final client = AnthropicOpenAIClient(apiKey: 'test-key');
      expect(
        () => client.listModels(),
        throwsUnsupportedError,
      );
      client.endSession();
    });
  });
}
