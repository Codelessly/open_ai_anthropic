// Verifies cache breakpoints produce stable prefixes across multi-turn
// conversations whose message list grows between API calls.
//
// Runs once per available [AnthropicMode] (OAuth + direct API key).
//
// Reference: claude-code/src/services/api/claude.ts lines 3078-3088
//   "Exactly one message-level cache_control marker per request."
library;

import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:test/test.dart';

import 'test_modes.dart';

/// ~7-10K-token system prompt — comfortably above per-model cache minimum
/// (1024 Sonnet / 4096 Haiku) yet small enough that three calls in a
/// minute don't trip the 30K-token/min input-rate-limit tier.
String _largeSystemPrompt() {
  final buf = StringBuffer();
  buf.writeln('You are an expert assistant. Answer concisely.');
  for (int i = 0; i < 50; i++) {
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
  final modes = loadAvailableModes();

  for (final fixture in modes) {
    group(fixture.label, () {
      test(
        'multi-turn: cache reads on second call despite message list change',
        () async {
          final client = fixture.buildClient();
          final systemPrompt = _largeSystemPrompt();
          print('[${fixture.label}] System prompt length: ${systemPrompt.length} chars');

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
          print('[${fixture.label}] Call 1: prompt=$r1Prompt, creation=$r1Creation, read=$r1Read');
          print('[${fixture.label}] Call 1 response: $r1Content');

          expect(r1Prompt, isNotNull);
          final r1CacheTokens = (r1Creation ?? 0) + (r1Read ?? 0);
          expect(
            r1CacheTokens,
            greaterThan(0),
            reason: '[${fixture.label}] Call 1 should have cache activity',
          );

          print('[${fixture.label}] Waiting 5 seconds to simulate tool execution delay...');
          await Future<void>.delayed(const Duration(seconds: 5));

          // --- Call 2: prior conversation + new user message ---
          final request2 = oai.ChatCompletionCreateRequest(
            model: 'claude-sonnet-4-6',
            messages: [
              oai.ChatMessage.system(systemPrompt),
              oai.ChatMessage.user('What is parameter_5_alpha? One number only.'),
              oai.ChatMessage.assistant(content: r1Content ?? '127'),
              oai.ChatMessage.user('Now what is threshold_10_gamma? One number only.'),
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
          print('[${fixture.label}] Call 2: prompt=$r2Prompt, creation=$r2Creation, read=$r2Read');

          expect(
            r2Read,
            isNotNull,
            reason:
                '[${fixture.label}] Call 2 MUST have cache reads — the system '
                'prompt prefix should hit the cache from Call 1',
          );
          expect(r2Read!, greaterThan(0));

          final cacheHitRatio = r2Read / (r2Prompt ?? 1);
          print('[${fixture.label}] Cache hit ratio: ${(cacheHitRatio * 100).toStringAsFixed(1)}%');
          expect(
            cacheHitRatio,
            greaterThan(0.5),
            reason:
                '[${fixture.label}] Cache hit ratio should be >50% (system '
                'prompt is most of it). Got ${(cacheHitRatio * 100).toStringAsFixed(1)}%. '
                'creation=$r2Creation, read=$r2Read, prompt=$r2Prompt',
          );

          final r2CreationActual = r2Creation ?? 0;
          print('[${fixture.label}] Call 2 new cache creation: $r2CreationActual tokens');
          expect(
            r2CreationActual,
            lessThan(r1CacheTokens ~/ 2),
            reason:
                '[${fixture.label}] Call 2 cache creation should be much smaller '
                'than the prefix. Call 1 cache=$r1CacheTokens, Call 2 created '
                '$r2CreationActual',
          );

          print('[${fixture.label}] Waiting 15 seconds to simulate slow tool execution...');
          await Future<void>.delayed(const Duration(seconds: 15));

          // --- Call 3: longer conversation + new user message ---
          final request3 = oai.ChatCompletionCreateRequest(
            model: 'claude-sonnet-4-6',
            messages: [
              oai.ChatMessage.system(systemPrompt),
              oai.ChatMessage.user('What is parameter_5_alpha? One number only.'),
              oai.ChatMessage.assistant(content: r1Content ?? '127'),
              oai.ChatMessage.user('Now what is threshold_10_gamma? One number only.'),
              oai.ChatMessage.assistant(content: '317'),
              oai.ChatMessage.user('What is the temperature for section 50? One number only.'),
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
          print(
            '[${fixture.label}] Call 3 (after 15s delay): prompt=$r3Prompt, '
            'creation=$r3Creation, read=$r3Read',
          );

          expect(
            r3Read,
            isNotNull,
            reason: '[${fixture.label}] Call 3 MUST have cache reads even after 15s delay',
          );
          expect(r3Read!, greaterThan(0));

          final r3HitRatio = r3Read / (r3Prompt ?? 1);
          print('[${fixture.label}] Call 3 cache hit ratio: ${(r3HitRatio * 100).toStringAsFixed(1)}%');
          expect(
            r3HitRatio,
            greaterThan(0.5),
            reason:
                '[${fixture.label}] Call 3 cache hit ratio should be >50% even '
                'after 15s delay. Got ${(r3HitRatio * 100).toStringAsFixed(1)}%',
          );

          print('\n[${fixture.label}] === CACHE STABILITY SUMMARY ===');
          print(
            '[${fixture.label}] Call 1: creation=$r1Creation, read=$r1Read '
            '(${r1Creation != null && r1Creation > 0 ? "cold" : "warm"})',
          );
          print('[${fixture.label}] Call 2 (+5s):  read=$r2Read, created=$r2CreationActual');
          print('[${fixture.label}] Call 3 (+15s): read=$r3Read, created=${r3Creation ?? 0}');
          print('[${fixture.label}] ===============================');

          client.close();
        },
        timeout: Timeout(Duration(minutes: 3)),
      );
    });
  }

  if (modes.isEmpty) {
    test('skipped — no credentials wired', () {
      markTestSkipped('Neither CLAUDE_CODE_CREDENTIALS nor ANTHROPIC_API_KEY is set');
    });
  }
}
