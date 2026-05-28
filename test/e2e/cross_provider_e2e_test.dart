// Live cross-provider E2E: alternates OpenAI GPT and Anthropic Claude
// using a single OpenAI-format conversation history, validating that
// tool calls, context recall, and cache breakpoints survive across
// providers.
//
// Runs once per available [AnthropicMode] (OAuth + direct API key).
// Requires OPENAI_API_KEY plus one of:
//   CLAUDE_CODE_CREDENTIALS (OAuth mode)
//   ANTHROPIC_API_KEY       (direct mode)
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:test/test.dart';

import 'test_modes.dart';

/// Cache-breakpoint bodyTransformer: cache the system message + last two
/// user messages. Defensive overlay — the converter also auto-injects,
/// but this exercises the explicit-bodyTransformer code path too.
void Function(Map<String, dynamic>) _cacheBreakpoints = (body) {
  final system = body['system'];
  if (system is String) {
    body['system'] = [
      {
        'type': 'text',
        'text': system,
        'cache_control': {'type': 'ephemeral'},
      },
    ];
  }
  final messages = body['messages'];
  if (messages is! List) return;
  final userIndices = <int>[];
  for (int i = 0; i < messages.length; i++) {
    if (messages[i] is Map && messages[i]['role'] == 'user') {
      userIndices.add(i);
    }
  }
  final lastTwo = userIndices.length <= 2 ? userIndices : userIndices.sublist(userIndices.length - 2);
  for (final idx in lastTwo) {
    final msg = messages[idx];
    if (msg is! Map) continue;
    final content = msg['content'];
    if (content is String) {
      msg['content'] = [
        {
          'type': 'text',
          'text': content,
          'cache_control': {'type': 'ephemeral'},
        },
      ];
    } else if (content is List && content.isNotEmpty) {
      for (int j = content.length - 1; j >= 0; j--) {
        if (content[j] is Map && content[j]['type'] == 'text') {
          content[j] = {
            ...content[j],
            'cache_control': {'type': 'ephemeral'},
          };
          break;
        }
      }
    }
  }
};

String _largeSystemPrompt() {
  final buffer = StringBuffer();
  buffer.writeln(
    'You are a helpful geography assistant. When asked about capitals or '
    'populations, use the provided tools. Keep responses brief.',
  );
  buffer.writeln();
  buffer.writeln('Here is a large knowledge base you must reference:');
  buffer.writeln();
  for (int i = 0; i < 200; i++) {
    buffer.writeln(
      'Fact $i: The value of parameter_${i}_alpha is ${i * 17 + 42}. '
      'This is important for calibrating the system when the input '
      'exceeds threshold_${i}_beta which equals ${i * 31 + 7}. '
      'Remember to cross-reference with section ${i + 1} of the manual.',
    );
  }
  return buffer.toString();
}

void main() {
  // The other e2e tests already prove direct-API caching, tool calls,
  // and cross-provider history sharing. Re-running an 8-round-trip in
  // direct-API mode burns ~$0.10 to validate redundant behavior, so it's
  // OAuth-only by default. Set `OAA_CROSS_PROVIDER_ALL_MODES=1` to opt in.
  final runAllModes = Platform.environment['OAA_CROSS_PROVIDER_ALL_MODES'] == '1';
  final allModes = loadAvailableModes();
  final modes = runAllModes ? allModes : allModes.where((m) => m.mode == AnthropicMode.oauth).toList();
  final openAIKey = loadOpenAiApiKey();

  const openAIModel = 'gpt-4.1-nano';
  const claudeModel = 'claude-sonnet-4-6';

  for (final fixture in modes) {
    group(fixture.label, () {
      // Per-group state — fresh conversation per mode.
      oai.OpenAIClient? openAIClient;
      oai.OpenAIClient? claudeClient;
      late List<oai.ChatMessage> history;

      // Tools used across both providers.
      final tools = [
        oai.Tool.function(
          name: 'lookup_capital',
          description: 'Look up the capital city of a country.',
          parameters: {
            'type': 'object',
            'properties': {
              'country': {
                'type': 'string',
                'description': 'The country name, e.g. "France"',
              },
            },
            'required': ['country'],
          },
        ),
        oai.Tool.function(
          name: 'lookup_population',
          description: 'Look up the population of a city.',
          parameters: {
            'type': 'object',
            'properties': {
              'city': {
                'type': 'string',
                'description': 'The city name, e.g. "Paris"',
              },
            },
            'required': ['city'],
          },
        ),
      ];

      String executeToolCall(String name, Map<String, dynamic> args) {
        return switch (name) {
          'lookup_capital' => jsonEncode({
            'capital': switch ((args['country'] as String?)?.toLowerCase()) {
              'france' => 'Paris',
              'japan' => 'Tokyo',
              'brazil' => 'Brasília',
              'australia' => 'Canberra',
              _ => 'Unknown',
            },
            'country': args['country'],
          }),
          'lookup_population' => jsonEncode({
            'population': switch ((args['city'] as String?)?.toLowerCase()) {
              'paris' => '2.1 million',
              'tokyo' => '13.9 million',
              'brasília' || 'brasilia' => '3.0 million',
              'canberra' => '460,000',
              _ => 'Unknown',
            },
            'city': args['city'],
          }),
          _ => jsonEncode({'error': 'Unknown function: $name'}),
        };
      }

      void handleToolCalls(oai.AssistantMessage msg) {
        if (msg.toolCalls == null || msg.toolCalls!.isEmpty) return;
        for (final toolCall in msg.toolCalls!) {
          final args = jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;
          final result = executeToolCall(toolCall.function.name, args);
          history.add(
            oai.ChatMessage.tool(
              toolCallId: toolCall.id,
              content: result,
            ),
          );
        }
      }

      Future<(oai.AssistantMessage, oai.Usage?)> roundTripOpenAI(String userMessage) async {
        history.add(oai.ChatMessage.user(userMessage));
        final response = await openAIClient!.chat.completions.create(
          oai.ChatCompletionCreateRequest(
            model: openAIModel,
            messages: history,
            tools: tools,
            toolChoice: oai.ToolChoice.auto(),
          ),
        );
        final msg = response.choices.first.message;
        history.add(msg);
        if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
          handleToolCalls(msg);
          final followUp = await openAIClient!.chat.completions.create(
            oai.ChatCompletionCreateRequest(
              model: openAIModel,
              messages: history,
              tools: tools,
            ),
          );
          final followUpMsg = followUp.choices.first.message;
          history.add(followUpMsg);
          return (followUpMsg, followUp.usage);
        }
        return (msg, response.usage);
      }

      Future<(oai.AssistantMessage, oai.Usage?)> roundTripClaude(String userMessage) async {
        history.add(oai.ChatMessage.user(userMessage));
        final response = await claudeClient!.chat.completions.create(
          oai.ChatCompletionCreateRequest(
            model: claudeModel,
            messages: history,
            tools: tools,
            toolChoice: oai.ToolChoice.auto(),
          ),
        );
        final msg = response.choices.first.message;
        history.add(msg);
        if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
          handleToolCalls(msg);
          final followUp = await claudeClient!.chat.completions.create(
            oai.ChatCompletionCreateRequest(
              model: claudeModel,
              messages: history,
              tools: tools,
            ),
          );
          final followUpMsg = followUp.choices.first.message;
          history.add(followUpMsg);
          return (followUpMsg, followUp.usage);
        }
        return (msg, response.usage);
      }

      setUp(() {
        history = <oai.ChatMessage>[];
        openAIClient = openAIKey == null ? null : oai.OpenAIClient.withApiKey(openAIKey);
        claudeClient = fixture.buildClient(bodyTransformer: _cacheBreakpoints);
      });

      tearDown(() {
        openAIClient?.close();
        claudeClient?.close();
      });

      test(
        'E2E: 8 round-trips alternating GPT ↔ Claude with cache breakpoints',
        () async {
          if (openAIKey == null) {
            markTestSkipped('OPENAI_API_KEY not set');
            return;
          }

          final systemPrompt = _largeSystemPrompt();
          history.add(oai.ChatMessage.system(systemPrompt));

          final claudeCacheHits = <int?>[];
          final openAICacheHits = <int?>[];

          final rounds = <_Round>[
            _Round(
              prompt: 'What continent is France in? Just the continent name.',
              provider: 'openai',
              validator: (r) => expect(r.toLowerCase(), contains('europe')),
            ),
            _Round(
              prompt: 'And Japan?',
              provider: 'claude',
              validator: (r) => expect(r.toLowerCase(), contains('asia')),
            ),
            _Round(
              prompt: 'What is the capital of France? Use the lookup_capital tool.',
              provider: 'openai',
              expectToolCalls: true,
              validator: (r) => expect(r.toLowerCase(), contains('paris')),
            ),
            _Round(
              prompt: "What about Japan's capital? Use the lookup_capital tool.",
              provider: 'claude',
              expectToolCalls: true,
              validator: (r) => expect(r.toLowerCase(), contains('tokyo')),
            ),
            _Round(
              prompt: 'What is the population of Paris? Use lookup_population.',
              provider: 'openai',
              expectToolCalls: true,
              validator: (r) => expect(r.toLowerCase(), contains('2.1')),
            ),
            _Round(
              prompt: "And Tokyo's population? Use lookup_population.",
              provider: 'claude',
              expectToolCalls: true,
              validator: (r) => expect(r.toLowerCase(), contains('13.9')),
            ),
            _Round(
              prompt:
                  'Which of the two cities we discussed has a larger population? '
                  'Just the city name.',
              provider: 'openai',
              validator: (r) => expect(r.toLowerCase(), contains('tokyo')),
            ),
            _Round(
              prompt:
                  'List all the capital cities we found during our conversation. '
                  'Just the city names, comma-separated.',
              provider: 'claude',
              validator: (r) {
                final lower = r.toLowerCase();
                expect(lower, contains('paris'));
                expect(lower, contains('tokyo'));
              },
            ),
          ];

          for (var i = 0; i < rounds.length; i++) {
            final round = rounds[i];
            final roundNum = i + 1;
            final providerLabel = round.provider == 'openai' ? 'GPT ($openAIModel)' : 'Claude ($claudeModel)';

            print('\n[${fixture.label}] --- Round $roundNum/8 [$providerLabel] ---');
            print('[${fixture.label}]   Prompt: ${round.prompt}');

            late oai.AssistantMessage response;
            oai.Usage? usage;
            if (round.provider == 'openai') {
              (response, usage) = await roundTripOpenAI(round.prompt);
              openAICacheHits.add(usage?.promptTokensDetails?.cachedTokens);
            } else {
              (response, usage) = await roundTripClaude(round.prompt);
              claudeCacheHits.add(usage?.promptTokensDetails?.cachedTokens);
            }

            final text = response.content ?? '(tool calls only)';
            print('[${fixture.label}]   Response: $text');
            print(
              '[${fixture.label}]   Usage: prompt=${usage?.promptTokens}, '
              'cached=${usage?.promptTokensDetails?.cachedTokens ?? 0}, '
              'completion=${usage?.completionTokens}',
            );

            if (round.expectToolCalls) {
              expect(
                response.content,
                isNotNull,
                reason: '[${fixture.label}] Round $roundNum: Expected text after tool execution',
              );
            }

            round.validator(response.content ?? '');
            print('[${fixture.label}]   ✓ Validated');
          }

          print('\n[${fixture.label}] CACHE VERIFICATION');
          print('[${fixture.label}]   Claude cache hits per round: $claudeCacheHits');
          print('[${fixture.label}]   OpenAI cache hits per round: $openAICacheHits');

          if (claudeCacheHits.length >= 2) {
            final laterHits = claudeCacheHits.sublist(1);
            final anyCacheHit = laterHits.any((t) => t != null && t > 0);
            expect(
              anyCacheHit,
              isTrue,
              reason:
                  '[${fixture.label}] Claude should have cache hits after the '
                  'first round. Hits: $claudeCacheHits',
            );
            print('[${fixture.label}]   ✓ Claude cache hits verified');
          }

          if (openAICacheHits.length >= 2) {
            final anyOpenAIHit = openAICacheHits.skip(1).any((t) => t != null && t > 0);
            if (anyOpenAIHit) {
              print('[${fixture.label}]   ✓ OpenAI also reported cache hits');
            } else {
              print('[${fixture.label}]   ℹ OpenAI did not report cache hits (provider-dependent)');
            }
          }

          print('\n[${fixture.label}] CONVERSATION SUMMARY');
          print('[${fixture.label}]   Total messages: ${history.length}');
          for (var i = 0; i < history.length; i++) {
            final msg = history[i];
            final role = switch (msg) {
              oai.SystemMessage() => 'system',
              oai.UserMessage() => 'user',
              oai.AssistantMessage() => 'assistant',
              oai.ToolMessage() => 'tool',
              oai.DeveloperMessage() => 'developer',
            };
            final preview = switch (msg) {
              oai.UserMessage(:final content) => switch (content) {
                oai.UserTextContent(:final text) => text.substring(0, text.length.clamp(0, 60)),
                _ => '(multipart)',
              },
              oai.AssistantMessage(:final content, :final toolCalls) =>
                toolCalls != null && toolCalls.isNotEmpty
                    ? 'tool_calls: ${toolCalls.map((t) => t.function.name).join(', ')}'
                    : (content ?? '(empty)').substring(0, (content ?? '').length.clamp(0, 60)),
              oai.ToolMessage(:final content) => content.substring(0, content.length.clamp(0, 50)),
              oai.SystemMessage(:final content) => content.substring(0, content.length.clamp(0, 50)),
              oai.DeveloperMessage(:final content) => content.substring(0, content.length.clamp(0, 50)),
            };
            print('[${fixture.label}]   [$i] $role: $preview');
          }

          print('\n[${fixture.label}] 8 cross-provider round-trips completed successfully!');
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );

      test(
        'E2E: streaming exposes Anthropic cache token fields in toJson usage',
        () async {
          final systemPrompt = _largeSystemPrompt();

          final request = oai.ChatCompletionCreateRequest(
            model: 'claude-sonnet-4-6',
            messages: [
              oai.ChatMessage.system(systemPrompt),
              oai.ChatMessage.user('What is 2+2? One word.'),
            ],
            maxCompletionTokens: 10,
          );

          // Make two requests. Cache may already be warm from prior runs,
          // so we accept either creation or read tokens.
          for (int i = 0; i < 2; i++) {
            int? creation;
            int? read;
            await for (final chunk in claudeClient!.chat.completions.createStream(request)) {
              if (chunk.usage != null) {
                final json = chunk.toJson();
                final usageJson = json['usage'] as Map<String, dynamic>?;
                creation = usageJson?['cache_creation_input_tokens'] as int?;
                read = usageJson?['cache_read_input_tokens'] as int?;
              }
            }
            print('[${fixture.label}] Streaming request ${i + 1} — creation: $creation, read: $read');
            final hasCache = (creation ?? 0) > 0 || (read ?? 0) > 0;
            expect(
              hasCache,
              isTrue,
              reason:
                  '[${fixture.label}] Streaming request ${i + 1} should expose '
                  'cache tokens in toJson. creation: $creation, read: $read',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'E2E: responseBodyTransformer receives Anthropic cache token fields (non-streaming)',
        () async {
          int? capturedCreation;
          int? capturedRead;

          final localClient = fixture.buildClient(
            bodyTransformer: _cacheBreakpoints,
            responseBodyTransformer: (json) {
              final usageJson = json['usage'] as Map<String, dynamic>?;
              capturedCreation = usageJson?['cache_creation_input_tokens'] as int?;
              capturedRead = usageJson?['cache_read_input_tokens'] as int?;
            },
          );

          final systemPrompt = _largeSystemPrompt();
          final request = oai.ChatCompletionCreateRequest(
            model: 'claude-sonnet-4-6',
            messages: [
              oai.ChatMessage.system(systemPrompt),
              oai.ChatMessage.user('What is 3+3? One word.'),
            ],
            maxCompletionTokens: 10,
          );

          for (int i = 0; i < 2; i++) {
            capturedCreation = null;
            capturedRead = null;
            await localClient.chat.completions.create(request);
            print(
              '[${fixture.label}] responseBodyTransformer request ${i + 1} — '
              'creation: $capturedCreation, read: $capturedRead',
            );

            final hasCache = (capturedCreation ?? 0) > 0 || (capturedRead ?? 0) > 0;
            expect(
              hasCache,
              isTrue,
              reason:
                  '[${fixture.label}] responseBodyTransformer should receive cache '
                  'tokens on request ${i + 1}. creation: $capturedCreation, read: $capturedRead',
            );
          }

          localClient.close();
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    });
  }

  if (modes.isEmpty) {
    test('skipped — no credentials wired', () {
      markTestSkipped('Neither CLAUDE_CODE_CREDENTIALS nor ANTHROPIC_API_KEY is set');
    });
  }
}

class _Round {
  final String prompt;
  final String provider; // 'openai' or 'claude'
  final bool expectToolCalls;
  final void Function(String response) validator;

  const _Round({
    required this.prompt,
    required this.provider,
    this.expectToolCalls = false,
    required this.validator,
  });
}
