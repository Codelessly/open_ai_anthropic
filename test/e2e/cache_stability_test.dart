/// Tests that cache breakpoints produce stable prefixes across multi-turn
/// conversations where the message list grows between API calls.
///
/// This is the definitive test for the fix: Call 2 MUST show cache reads
/// (not full re-creation) even though the message list changed.
///
/// Reference: claude-code/src/services/api/claude.ts lines 3078-3088
///   "Exactly one message-level cache_control marker per request."
library;

import 'dart:io';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:test/test.dart';

ClaudeCodeCredentials? _loadCreds() {
  final envFile = File('.env');
  if (envFile.existsSync()) {
    for (final line in envFile.readAsLinesSync()) {
      if (line.startsWith('CLAUDE_CODE_CREDENTIALS=')) {
        return ClaudeCodeCredentials.fromJsonString(
          line.substring('CLAUDE_CODE_CREDENTIALS='.length),
        );
      }
    }
  }
  return null;
}

/// ~30K token system prompt to ensure we exceed the 1024-token cache minimum.
String _largeSystemPrompt() {
  final buf = StringBuffer();
  buf.writeln('You are an expert assistant. Answer concisely.');
  for (int i = 0; i < 200; i++) {
    buf.writeln('''
## Section $i: Reference Data
Parameter_${i}_alpha = ${i * 17 + 42}. Threshold_${i}_gamma = ${i * 31 + 7}.
Frequency: ${i * 3.14159} Hz. Tolerance: ${1.0 / (i + 1)}%.
Temperature: ${(i * 0.0023) + 20.0}°C. Pressure: ${(i * 1.5) + 100} kPa.
''');
  }
  return buf.toString();
}

void main() {
  final creds = _loadCreds();

  test(
    'multi-turn: cache reads on second call despite message list change',
    () async {
      final client = ClaudeCodeOpenAIClient(credentials: creds);
      final systemPrompt = _largeSystemPrompt();
      print('System prompt length: ${systemPrompt.length} chars');

      // --- Call 1: system + user message ---
      final request1 = oai.ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          oai.ChatMessage.system(systemPrompt),
          oai.ChatMessage.user('What is parameter_5_alpha? One number only.'),
        ],
        maxCompletionTokens: 64,
      );

      int? r1Creation, r1Read, r1Prompt;
      String? r1Content;
      await for (final chunk in client.chat.completions.createStream(request1)) {
        final delta = chunk.choices?.firstOrNull?.delta;
        if (delta?.content != null) {
          r1Content = (r1Content ?? '') + delta!.content!;
        }
        if (chunk.usage != null) {
          r1Prompt = chunk.usage!.promptTokens;
          final u = chunk.toJson()['usage'] as Map<String, dynamic>?;
          r1Creation = u?['cache_creation_input_tokens'] as int?;
          r1Read = u?['cache_read_input_tokens'] as int?;
        }
      }
      print('Call 1: prompt=$r1Prompt, creation=$r1Creation, read=$r1Read');
      print('Call 1 response: $r1Content');

      expect(r1Prompt, isNotNull);
      // First call should have cache activity (creation if cold, read if warm
      // from a prior test run within the TTL window).
      final r1CacheTokens = (r1Creation ?? 0) + (r1Read ?? 0);
      expect(r1CacheTokens, greaterThan(0), reason: 'Call 1 should have cache activity');

      // --- Deliberate delay simulating real tool execution time ---
      // In a real conversation, there are seconds of delay between API calls
      // (model thinking, tool execution, user reading). The cache must survive.
      print('Waiting 5 seconds to simulate tool execution delay...');
      await Future<void>.delayed(const Duration(seconds: 5));

      // --- Call 2: system + user + assistant + NEW user message ---
      // This simulates a tool-use loop: the message list grows.
      final request2 = oai.ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          oai.ChatMessage.system(systemPrompt),
          oai.ChatMessage.user('What is parameter_5_alpha? One number only.'),
          oai.ChatMessage.assistant(content: r1Content ?? '127'),
          oai.ChatMessage.user(
            'Now what is threshold_10_gamma? One number only.',
          ),
        ],
        maxCompletionTokens: 64,
      );

      int? r2Creation, r2Read, r2Prompt;
      await for (final chunk in client.chat.completions.createStream(request2)) {
        if (chunk.usage != null) {
          r2Prompt = chunk.usage!.promptTokens;
          final u = chunk.toJson()['usage'] as Map<String, dynamic>?;
          r2Creation = u?['cache_creation_input_tokens'] as int?;
          r2Read = u?['cache_read_input_tokens'] as int?;
        }
      }
      print('Call 2: prompt=$r2Prompt, creation=$r2Creation, read=$r2Read');

      // THE CRITICAL ASSERTION: Call 2 must have cache reads.
      // The system prompt prefix (~30K tokens) should be a cache hit.
      expect(
        r2Read,
        isNotNull,
        reason: 'Call 2 MUST have cache reads — the system prompt prefix '
            'should hit the cache from Call 1',
      );
      expect(
        r2Read!,
        greaterThan(0),
        reason: 'Call 2 cache reads must be > 0',
      );

      // Cache reads should be a significant portion of the prompt
      // (at least the system prompt, which is ~30K+ tokens)
      final cacheHitRatio = r2Read / (r2Prompt ?? 1);
      print('Cache hit ratio: ${(cacheHitRatio * 100).toStringAsFixed(1)}%');
      expect(
        cacheHitRatio,
        greaterThan(0.5),
        reason: 'Cache hit ratio should be >50% (system prompt is most of it). '
            'Got ${(cacheHitRatio * 100).toStringAsFixed(1)}%. '
            'creation=$r2Creation, read=$r2Read, prompt=$r2Prompt',
      );

      // Cache creation on Call 2 should be small (just the new messages)
      final r2CreationActual = r2Creation ?? 0;
      print('Call 2 new cache creation: $r2CreationActual tokens');
      // If Call 1 had creation, Call 2's creation must be much smaller.
      // If Call 1 was a cache hit (warm), Call 2's creation should still be small.
      expect(
        r2CreationActual,
        lessThan(r1CacheTokens ~/ 2),
        reason: 'Call 2 cache creation should be much smaller than the prefix. '
            'Call 1 cache=$r1CacheTokens, Call 2 created $r2CreationActual',
      );

      // --- Longer delay simulating a slow tool (file read, web search, etc.) ---
      print('Waiting 15 seconds to simulate slow tool execution...');
      await Future<void>.delayed(const Duration(seconds: 15));

      // --- Call 3: system + 4 messages + NEW user message ---
      // Tests that cache still holds after a longer gap.
      final request3 = oai.ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-6',
        messages: [
          oai.ChatMessage.system(systemPrompt),
          oai.ChatMessage.user('What is parameter_5_alpha? One number only.'),
          oai.ChatMessage.assistant(content: r1Content ?? '127'),
          oai.ChatMessage.user(
            'Now what is threshold_10_gamma? One number only.',
          ),
          oai.ChatMessage.assistant(content: '317'),
          oai.ChatMessage.user(
            'What is the temperature for section 50? One number only.',
          ),
        ],
        maxCompletionTokens: 64,
      );

      int? r3Creation, r3Read, r3Prompt;
      await for (final chunk in client.chat.completions.createStream(request3)) {
        if (chunk.usage != null) {
          r3Prompt = chunk.usage!.promptTokens;
          final u = chunk.toJson()['usage'] as Map<String, dynamic>?;
          r3Creation = u?['cache_creation_input_tokens'] as int?;
          r3Read = u?['cache_read_input_tokens'] as int?;
        }
      }
      print('Call 3 (after 15s delay): prompt=$r3Prompt, creation=$r3Creation, read=$r3Read');

      // Call 3 must still have cache reads after the longer delay
      expect(
        r3Read,
        isNotNull,
        reason: 'Call 3 MUST have cache reads even after 15s delay',
      );
      expect(r3Read!, greaterThan(0));

      final r3HitRatio = r3Read / (r3Prompt ?? 1);
      print('Call 3 cache hit ratio: ${(r3HitRatio * 100).toStringAsFixed(1)}%');
      expect(
        r3HitRatio,
        greaterThan(0.5),
        reason: 'Call 3 cache hit ratio should be >50% even after 15s delay. '
            'Got ${(r3HitRatio * 100).toStringAsFixed(1)}%',
      );

      print('\n=== CACHE STABILITY SUMMARY ===');
      print('Call 1: creation=$r1Creation, read=$r1Read (${r1Creation != null ? "cold" : "warm"})');
      print('Call 2 (+5s):  read=$r2Read, created=$r2CreationActual');
      print('Call 3 (+15s): read=$r3Read, created=${r3Creation ?? 0}');
      print('===============================');

      client.close();
    },
    skip: creds == null ? 'No credentials' : null,
    timeout: Timeout(Duration(minutes: 3)),
  );
}
