import 'dart:convert';
import 'dart:io';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:openai_dart/openai_dart.dart' as oai;
import 'package:test/test.dart';

({String? openAIKey, ClaudeCodeCredentials? claudeCredentials}) _loadCredentials() {
  String? openAIKey = Platform.environment['OPENAI_API_KEY'];
  ClaudeCodeCredentials? claudeCredentials;

  final credJson = Platform.environment['CLAUDE_CODE_CREDENTIALS'];
  if (credJson != null && credJson.isNotEmpty) {
    claudeCredentials = ClaudeCodeCredentials.fromJsonString(credJson);
  }

  final envFile = File('.env');
  if (envFile.existsSync()) {
    for (final line in envFile.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.startsWith('OPENAI_API_KEY=') && (openAIKey == null || openAIKey.isEmpty)) {
        openAIKey = trimmed.substring('OPENAI_API_KEY='.length);
      }
      if (trimmed.startsWith('CLAUDE_CODE_CREDENTIALS=') && claudeCredentials == null) {
        final json = trimmed.substring('CLAUDE_CODE_CREDENTIALS='.length);
        claudeCredentials = ClaudeCodeCredentials.fromJsonString(json);
      }
    }
  }

  return (openAIKey: openAIKey, claudeCredentials: claudeCredentials);
}

/// Live E2E test that alternates between OpenAI GPT and Claude (via
/// ClaudeCodeOpenAIClient with OAuth) for 8 round-trips, validating that a
/// single OpenAI-format conversation history seamlessly interoperates between
/// providers with tool calls, context recall, and cache breakpoints.
///
/// Requires OPENAI_API_KEY and CLAUDE_CODE_CREDENTIALS in environment or .env.
void main() {
  oai.OpenAIClient? openAIClient;
  ClaudeCodeOpenAIClient? claudeClient;

  const openAIModel = 'gpt-4.1-nano';
  const claudeModel = 'claude-sonnet-4-20250514';

  // Single OpenAI-format conversation history shared across providers.
  final history = <oai.ChatMessage>[];

  // Tools in OpenAI format — shared across both providers.
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

  /// Simulate tool execution.
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

  /// Handle tool calls — execute tools and add results to history.
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

  /// Perform a round-trip using OpenAI GPT.
  Future<(oai.AssistantMessage, oai.Usage?)> roundTripOpenAI(
    String userMessage,
  ) async {
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

  /// Perform a round-trip using Claude (via ClaudeCodeOpenAIClient).
  Future<(oai.AssistantMessage, oai.Usage?)> roundTripClaude(
    String userMessage,
  ) async {
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

  // ---- Credential loading ----

  final creds = _loadCredentials();
  final openAIKey = creds.openAIKey;
  final claudeCredentials = creds.claudeCredentials;

  /// Large system prompt to exceed Anthropic's minimum cache threshold.
  String largeSystemPrompt() {
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

  tearDownAll(() {
    openAIClient?.close();
    claudeClient?.close();
  });

  test(
    'E2E: 8 round-trips alternating GPT ↔ Claude Code with cache breakpoints',
    () async {
      // Build clients.
      openAIClient = oai.OpenAIClient.withApiKey(openAIKey!);
      claudeClient = ClaudeCodeOpenAIClient(
        credentials: claudeCredentials,
        bodyTransformer: (body) {
          // Cache the system message.
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
          // Cache the last two user messages.
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
            var content = msg['content'];
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
        },
      );

      final systemPrompt = largeSystemPrompt();
      history.add(oai.ChatMessage.system(systemPrompt));

      // Track cache hits per provider.
      final claudeCacheHits = <int?>[];
      final openAICacheHits = <int?>[];

      // ---- 8 Rounds: OpenAI(odd) ↔ Claude(even) ----

      final rounds = <_Round>[
        // 1: OpenAI — simple question
        _Round(
          prompt: 'What continent is France in? Just the continent name.',
          provider: 'openai',
          validator: (r) => expect(r.toLowerCase(), contains('europe')),
        ),
        // 2: Claude — follow-up using context from round 1
        _Round(
          prompt: 'And Japan?',
          provider: 'claude',
          validator: (r) => expect(r.toLowerCase(), contains('asia')),
        ),
        // 3: OpenAI — tool call (lookup_capital)
        _Round(
          prompt: 'What is the capital of France? Use the lookup_capital tool.',
          provider: 'openai',
          expectToolCalls: true,
          validator: (r) => expect(r.toLowerCase(), contains('paris')),
        ),
        // 4: Claude — tool call (lookup_capital), building on OpenAI context
        _Round(
          prompt: "What about Japan's capital? Use the lookup_capital tool.",
          provider: 'claude',
          expectToolCalls: true,
          validator: (r) => expect(r.toLowerCase(), contains('tokyo')),
        ),
        // 5: OpenAI — tool call (lookup_population)
        _Round(
          prompt: 'What is the population of Paris? Use lookup_population.',
          provider: 'openai',
          expectToolCalls: true,
          validator: (r) => expect(r.toLowerCase(), contains('2.1')),
        ),
        // 6: Claude — tool call (lookup_population)
        _Round(
          prompt: "And Tokyo's population? Use lookup_population.",
          provider: 'claude',
          expectToolCalls: true,
          validator: (r) => expect(r.toLowerCase(), contains('13.9')),
        ),
        // 7: OpenAI — context recall (no tools)
        _Round(
          prompt:
              'Which of the two cities we discussed has a larger population? '
              'Just the city name.',
          provider: 'openai',
          validator: (r) => expect(r.toLowerCase(), contains('tokyo')),
        ),
        // 8: Claude — final summary referencing entire conversation
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
        final providerLabel = round.provider == 'openai' ? 'GPT ($openAIModel)' : 'Claude Code ($claudeModel)';

        print('\n--- Round $roundNum/8 [$providerLabel] ---');
        print('  Prompt: ${round.prompt}');

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
        print('  Response: $text');
        print(
          '  Usage: promptTokens=${usage?.promptTokens}, '
          'cachedTokens=${usage?.promptTokensDetails?.cachedTokens ?? 0}, '
          'completionTokens=${usage?.completionTokens}',
        );

        if (round.expectToolCalls) {
          expect(response.content, isNotNull, reason: 'Round $roundNum: Expected text after tool execution');
        }

        round.validator(response.content ?? '');
        print('  ✓ Validated');
      }

      // ---- Cache verification ----

      print('\n${'=' * 60}');
      print('CACHE VERIFICATION');
      print('=' * 60);
      print('  Claude cache hits per round: $claudeCacheHits');
      print('  OpenAI cache hits per round: $openAICacheHits');

      // Claude: second+ rounds should have cache hits (system prompt cached)
      // First Claude round (round 2) creates the cache; subsequent ones read.
      if (claudeCacheHits.length >= 2) {
        final laterHits = claudeCacheHits.sublist(1);
        final anyCacheHit = laterHits.any((t) => t != null && t > 0);
        expect(
          anyCacheHit,
          isTrue,
          reason:
              'Claude should have cache hits after the first round. '
              'Hits: $claudeCacheHits',
        );
        print('  ✓ Claude cache hits verified');
      }

      // OpenAI: may report cached tokens on later rounds too
      if (openAICacheHits.length >= 2) {
        final anyOpenAIHit = openAICacheHits.skip(1).any((t) => t != null && t > 0);
        if (anyOpenAIHit) {
          print('  ✓ OpenAI also reported cache hits');
        } else {
          print('  ℹ OpenAI did not report cache hits (provider-dependent)');
        }
      }

      // ---- Final summary ----

      print('\n${'=' * 60}');
      print('CONVERSATION SUMMARY');
      print('=' * 60);
      print('  Total messages: ${history.length}');
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
        print('  [$i] $role: $preview');
      }

      print('\n${'=' * 60}');
      print('8 cross-provider round-trips completed successfully!');
      print('=' * 60);
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: (openAIKey == null || openAIKey.isEmpty)
        ? 'OPENAI_API_KEY not set'
        : claudeCredentials == null
        ? 'CLAUDE_CODE_CREDENTIALS not set'
        : null,
  );

  test(
    'E2E: streaming exposes Anthropic cache token fields in toJson usage',
    () async {
      final client = ClaudeCodeOpenAIClient(
        credentials: claudeCredentials,
        bodyTransformer: (body) {
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
        },
      );

      final systemPrompt = largeSystemPrompt();

      final request = oai.ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-20250514',
        messages: [
          oai.ChatMessage.system(systemPrompt),
          oai.ChatMessage.user('What is 2+2? One word.'),
        ],
        maxCompletionTokens: 10,
      );

      // Make two requests. Between previous test runs and this one, the cache
      // may already be warm, so we accept either creation or read tokens.
      // The key assertion: at least one Anthropic-specific cache field appears
      // in the toJson() output.
      for (int i = 0; i < 2; i++) {
        int? creation;
        int? read;
        await for (final chunk in client.chat.completions.createStream(request)) {
          if (chunk.usage != null) {
            final json = chunk.toJson();
            final usageJson = json['usage'] as Map<String, dynamic>?;
            creation = usageJson?['cache_creation_input_tokens'] as int?;
            read = usageJson?['cache_read_input_tokens'] as int?;
          }
        }

        print('Streaming request ${i + 1} - creation: $creation, read: $read');
        final hasCache = (creation ?? 0) > 0 || (read ?? 0) > 0;
        expect(hasCache, isTrue,
            reason: 'Streaming request ${i + 1} should expose cache tokens in toJson. '
                'creation: $creation, read: $read');
      }

      client.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: claudeCredentials == null ? 'CLAUDE_CODE_CREDENTIALS not set' : null,
  );

  test(
    'E2E: responseBodyTransformer receives Anthropic cache token fields (non-streaming)',
    () async {
      int? capturedCreation;
      int? capturedRead;

      final client = ClaudeCodeOpenAIClient(
        credentials: claudeCredentials,
        bodyTransformer: (body) {
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
        },
        responseBodyTransformer: (json) {
          final usageJson = json['usage'] as Map<String, dynamic>?;
          capturedCreation = usageJson?['cache_creation_input_tokens'] as int?;
          capturedRead = usageJson?['cache_read_input_tokens'] as int?;
        },
      );

      final systemPrompt = largeSystemPrompt();

      final request = oai.ChatCompletionCreateRequest(
        model: 'claude-sonnet-4-20250514',
        messages: [
          oai.ChatMessage.system(systemPrompt),
          oai.ChatMessage.user('What is 3+3? One word.'),
        ],
        maxCompletionTokens: 10,
      );

      // Two requests — verify responseBodyTransformer captures cache fields.
      for (int i = 0; i < 2; i++) {
        capturedCreation = null;
        capturedRead = null;
        await client.chat.completions.create(request);
        print('responseBodyTransformer request ${i + 1} - creation: $capturedCreation, read: $capturedRead');

        final hasCache = (capturedCreation ?? 0) > 0 || (capturedRead ?? 0) > 0;
        expect(hasCache, isTrue,
            reason: 'responseBodyTransformer should receive cache tokens on request ${i + 1}. '
                'creation: $capturedCreation, read: $capturedRead');
      }

      client.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: claudeCredentials == null ? 'CLAUDE_CODE_CREDENTIALS not set' : null,
  );
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
