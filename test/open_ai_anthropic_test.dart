import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:test/test.dart';

void main() {
  group('AnthropicOpenAIClient', () {
    test('can be instantiated', () {
      final client = AnthropicOpenAIClient(apiKey: 'test-key');
      expect(client, isNotNull);
      client.close();
    });
  });
}
