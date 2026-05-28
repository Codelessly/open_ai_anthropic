import 'dart:convert';
import 'package:openai_dart/openai_dart.dart';
import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:open_ai_anthropic/src/converters/request/chat_completion_request_converter.dart';

void main() {
  final converter = ChatCompletionRequestConverter();

  final request = ChatCompletionCreateRequest(
    model: 'claude-haiku-4-5-20251001',
    messages: [
      ChatMessage.system('You are a helpful assistant. ' * 200),
      ChatMessage.user('First turn'),
      ChatMessage.assistant(content: 'Reply'),
      ChatMessage.user('Second turn user message'),
    ],
    tools: [
      Tool.function(name: 't1', description: 'd', parameters: {'type': 'object', 'properties': {}}),
      Tool.function(name: 't2', description: 'd', parameters: {'type': 'object', 'properties': {}}),
    ],
  );

  // Direct API path (the broken one in the bench)
  final result = converter.convert(request, isOAuth: false, cacheRetention: CacheRetention.short);
  final body = result.toJson();
  print('=== BODY (direct API, isOAuth: false) ===');
  print(JsonEncoder.withIndent('  ').convert(body));
  print('');
  print('=== quick checks ===');
  final system = body['system'];
  print('system is List: ${system is List}');
  if (system is List) {
    for (final b in system) {
      print('  system block has cache_control: ${(b as Map).containsKey('cache_control')}');
    }
  }
  final messages = body['messages'] as List;
  print('messages count: ${messages.length}');
  final last = messages.last as Map;
  print('last role: ${last['role']}');
  final c = last['content'];
  print('last content type: ${c.runtimeType}');
  if (c is List) {
    for (var i = 0; i < c.length; i++) {
      print('  block[$i] has cache_control: ${(c[i] as Map).containsKey('cache_control')}');
    }
  }
}
