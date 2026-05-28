// Verifies that Anthropic prompt caching surfaces token counts in the
// OpenAI-shaped response — once per available [AnthropicMode] (OAuth and
// direct API key). The OAuth path was previously the only one that
// emitted non-zero cache_creation_input_tokens; the direct-API path is
// the regression check for the cache_control gate fix (#41).
import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:test/test.dart';

import 'test_modes.dart';

/// Generates a system prompt around ~7-10k tokens — comfortably above
/// the per-model cache minimum (1024 for Sonnet, 4096 for Haiku) yet
/// small enough that two back-to-back calls don't bust the 30K-token/min
/// input-rate-limit tier on Sonnet 4.6.
String _massiveSystemPrompt() {
  final buf = StringBuffer();
  buf.writeln('You are an expert assistant with encyclopedic knowledge.');
  buf.writeln();

  for (int i = 0; i < 50; i++) {
    buf.writeln('''
## Section $i: Advanced Systems Theory

The fundamental principles of parameter_${i}_alpha (value: ${i * 17 + 42}) govern the
interaction between subsystem_${i}_beta and the primary control loop. When the input
signal exceeds threshold_${i}_gamma (${i * 31 + 7} units), the feedback mechanism
engages compensatory_module_${i}_delta, which operates at frequency ${i * 3.14159} Hz.

The calibration procedure for component_${i}_epsilon requires cross-referencing with
sections ${i + 1} through ${i + 5} of the technical manual. The error tolerance for
this particular subsystem is defined as ${1.0 / (i + 1)} percent, measured against
the baseline established during initialization phase ${i % 7}.

Temperature coefficient for region_${i}_zeta: ${(i * 0.0023) + 20.0} degrees Celsius.
Pressure rating: ${(i * 1.5) + 100} kPa. Flow rate: ${i * 0.75 + 10} L/min.
Safety margin factor: ${((i % 10) + 1) * 0.1}. Redundancy level: ${(i % 4) + 1}.
''');
  }
  return buf.toString();
}

void main() {
  final modes = loadAvailableModes();

  for (final fixture in modes) {
    group(fixture.label, () {
      test(
        'streaming: cache creation on first request, cache read on second',
        () async {
          final client = fixture.buildClient();
          final systemPrompt = _massiveSystemPrompt();
          print('[${fixture.label}] System prompt length: ${systemPrompt.length} chars');

          final request = oai.ChatCompletionCreateRequest(
            model: 'claude-sonnet-4-6',
            messages: [
              oai.ChatMessage.system(systemPrompt),
              oai.ChatMessage.user('What is the value of parameter_5_alpha? Answer in one word.'),
            ],
            maxCompletionTokens: 16000,
          );

          // Round 1 — should create cache (or read if already warm)
          int? r1Creation, r1Read, r1Prompt, r1Completion;
          await for (final chunk in client.chat.completions.createStream(request)) {
            if (chunk.usage != null) {
              r1Prompt = chunk.usage!.promptTokens;
              r1Completion = chunk.usage!.completionTokens;
              final json = chunk.toJson();
              final u = json['usage'] as Map<String, dynamic>?;
              r1Creation = u?['cache_creation_input_tokens'] as int?;
              r1Read = u?['cache_read_input_tokens'] as int?;
            }
          }
          print(
            '[${fixture.label}] Round 1: prompt=$r1Prompt, completion=$r1Completion, '
            'cacheCreation=$r1Creation, cacheRead=$r1Read',
          );

          expect(r1Prompt, isNotNull);
          expect(r1Prompt, greaterThan(0));
          final r1HasCache = (r1Creation ?? 0) > 0 || (r1Read ?? 0) > 0;
          expect(
            r1HasCache,
            isTrue,
            reason:
                '[${fixture.label}] Round 1 should report cache tokens. '
                'creation=$r1Creation, read=$r1Read',
          );

          // Round 2 — same prefix, should read from cache
          int? r2Creation, r2Read, r2Prompt, r2Completion;
          await for (final chunk in client.chat.completions.createStream(request)) {
            if (chunk.usage != null) {
              r2Prompt = chunk.usage!.promptTokens;
              r2Completion = chunk.usage!.completionTokens;
              final json = chunk.toJson();
              final u = json['usage'] as Map<String, dynamic>?;
              r2Creation = u?['cache_creation_input_tokens'] as int?;
              r2Read = u?['cache_read_input_tokens'] as int?;
            }
          }
          print(
            '[${fixture.label}] Round 2: prompt=$r2Prompt, completion=$r2Completion, '
            'cacheCreation=$r2Creation, cacheRead=$r2Read',
          );

          expect(
            r2Read,
            isNotNull,
            reason: '[${fixture.label}] Round 2 must have cache read tokens',
          );
          expect(
            r2Read,
            greaterThan(0),
            reason: '[${fixture.label}] Round 2 cacheRead must be > 0',
          );
          print(
            '[${fixture.label}] Cache read tokens: $r2Read '
            '(${((r2Read ?? 0) / (r2Prompt ?? 1) * 100).toStringAsFixed(1)}% of prompt)',
          );

          client.close();
        },
        timeout: Timeout(Duration(minutes: 3)),
      );

      test(
        'non-streaming: cache tokens reported via responseBodyTransformer',
        () async {
          int? lastCreation, lastRead;

          final client = fixture.buildClient(
            responseBodyTransformer: (json) {
              final u = json['usage'] as Map<String, dynamic>?;
              lastCreation = u?['cache_creation_input_tokens'] as int?;
              lastRead = u?['cache_read_input_tokens'] as int?;
            },
          );
          final systemPrompt = _massiveSystemPrompt();

          final request = oai.ChatCompletionCreateRequest(
            model: 'claude-sonnet-4-6',
            messages: [
              oai.ChatMessage.system(systemPrompt),
              oai.ChatMessage.user('What is threshold_10_gamma? One number.'),
            ],
            maxCompletionTokens: 16000,
          );

          // Round 1
          final resp1 = await client.chat.completions.create(request);
          print(
            '[${fixture.label}] Round 1 (non-streaming): prompt=${resp1.usage?.promptTokens}, '
            'cachedTokens=${resp1.usage?.promptTokensDetails?.cachedTokens}, '
            'creation=$lastCreation, read=$lastRead',
          );

          // Round 2
          final resp2 = await client.chat.completions.create(request);
          print(
            '[${fixture.label}] Round 2 (non-streaming): prompt=${resp2.usage?.promptTokens}, '
            'cachedTokens=${resp2.usage?.promptTokensDetails?.cachedTokens}, '
            'creation=$lastCreation, read=$lastRead',
          );

          expect(
            resp2.usage?.promptTokensDetails?.cachedTokens,
            greaterThan(0),
            reason: '[${fixture.label}] Second non-streaming request must have cachedTokens > 0',
          );

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
