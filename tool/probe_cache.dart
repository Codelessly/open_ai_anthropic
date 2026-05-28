// Direct-API caching probe: builds a 30k-token system prompt, sends through
// the converter to api.anthropic.com via ApiKeyVisa, and prints actual usage.
// Usage: ANTHROPIC_API_KEY=sk-ant-... dart run tool/probe_cache.dart
import 'dart:io';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:openai_dart/openai_dart.dart' as oai;

String _massiveSystemPrompt() {
  final buf = StringBuffer();
  buf.writeln('You are an expert assistant with encyclopedic knowledge.');
  for (int i = 0; i < 200; i++) {
    buf.writeln('## Section $i: Advanced Systems Theory');
    buf.writeln('Parameter ${i}_alpha (value ${i * 17 + 42}) governs ${i}_beta.');
    buf.writeln('Threshold ${i}_gamma is ${i * 31 + 7} units. Frequency ${i * 3.14159} Hz.');
    buf.writeln('Section ${i + 1} through ${i + 5}; error tolerance ${1.0 / (i + 1)}%.');
    buf.writeln('Pressure ${(i * 1.5) + 100} kPa, flow ${i * 0.75 + 10} L/min.');
    buf.writeln('Redundancy ${(i % 4) + 1}; safety margin ${((i % 10) + 1) * 0.1}.');
    buf.writeln();
  }
  return buf.toString();
}

String? _apiKey() {
  final env = Platform.environment['ANTHROPIC_API_KEY'];
  if (env != null && env.isNotEmpty) return env;
  // Fallback: read from server/.env
  final envFile = File('/Users/saadardati/IdeaProjects/llmcouncil/server/.env');
  if (!envFile.existsSync()) return null;
  for (final line in envFile.readAsLinesSync()) {
    if (line.startsWith('ANTHROPIC_API_KEY=')) {
      var v = line.substring('ANTHROPIC_API_KEY='.length).trim();
      if (v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
      if (v.startsWith("'") && v.endsWith("'")) v = v.substring(1, v.length - 1);
      return v;
    }
  }
  return null;
}

Future<void> _runOne({
  required String label,
  required String model,
  required AnthropicOpenAIClient client,
  required String systemPrompt,
  required String userMsg,
  bool withSchemaAndTools = false,
}) async {
  // Optionally mirror the bench: lots of tools + forced JSON-schema output.
  // This reproduces the bench's `sendMessageWithSchema` request shape.
  final tools = !withSchemaAndTools
      ? null
      : List<oai.Tool>.generate(
          77,
          (i) => oai.Tool.function(
            name: 'probe_tool_$i',
            description: 'Tool #$i used to bulk up the prefix to match the bench setup.',
            parameters: {
              'type': 'object',
              'additionalProperties': false,
              'properties': {
                'arg': {'type': 'string', 'description': 'arg for tool $i'},
              },
            },
          ),
        );
  final responseFormat = !withSchemaAndTools
      ? null
      : oai.ResponseFormat.jsonSchema(
          name: 'BenchReply',
          strict: true,
          schema: {
            'type': 'object',
            'additionalProperties': false,
            'required': ['acknowledged', 'model_name'],
            'properties': {
              'acknowledged': {'type': 'boolean'},
              'model_name': {'type': 'string'},
            },
          },
        );

  final request = oai.ChatCompletionCreateRequest(
    model: model,
    messages: [
      oai.ChatMessage.system(systemPrompt),
      oai.ChatMessage.user(userMsg),
    ],
    maxCompletionTokens: 256,
    tools: tools,
    toolChoice: tools == null ? null : oai.ToolChoice.auto(),
    responseFormat: responseFormat,
  );

  print('--- $label ---');
  int? prompt, completion, cacheRead, cacheCreate;
  await for (final chunk in client.chat.completions.createStream(request)) {
    if (chunk.usage != null) {
      prompt = chunk.usage!.promptTokens;
      completion = chunk.usage!.completionTokens;
      final usage = chunk.toJson()['usage'] as Map<String, dynamic>?;
      cacheCreate = usage?['cache_creation_input_tokens'] as int?;
      cacheRead = usage?['cache_read_input_tokens'] as int?;
    }
  }
  print(
    '$label result: prompt=$prompt, completion=$completion, '
    'cache_creation=$cacheCreate, cache_read=$cacheRead',
  );
}

Future<void> main() async {
  final apiKey = _apiKey();
  if (apiKey == null) {
    stderr.writeln('No ANTHROPIC_API_KEY available.');
    exit(1);
  }
  final systemPrompt = _massiveSystemPrompt();
  print('System prompt: ${systemPrompt.length} chars');

  final client = AnthropicOpenAIClient(apiKey: apiKey);

  // Variant A: bare (no tools, no schema) — known good per first run.
  await _runOne(
    label: 'A1 bare turn 1 (haiku 4.5)',
    model: 'claude-haiku-4-5',
    client: client,
    systemPrompt: systemPrompt,
    userMsg: 'Bare nonce ${DateTime.now().microsecondsSinceEpoch}. Reply OK.',
  );
  await _runOne(
    label: 'A2 bare turn 2 (haiku 4.5)',
    model: 'claude-haiku-4-5',
    client: client,
    systemPrompt: systemPrompt,
    userMsg: 'Bare nonce ${DateTime.now().microsecondsSinceEpoch}+1. Reply OK.',
  );

  // Variant B: 77 tools + jsonSchema response format — mirrors the bench shape.
  await _runOne(
    label: 'B1 tools+schema turn 1 (haiku 4.5)',
    model: 'claude-haiku-4-5',
    client: client,
    systemPrompt: systemPrompt,
    userMsg: 'Schema nonce ${DateTime.now().microsecondsSinceEpoch}. Acknowledge.',
    withSchemaAndTools: true,
  );
  await _runOne(
    label: 'B2 tools+schema turn 2 (haiku 4.5)',
    model: 'claude-haiku-4-5',
    client: client,
    systemPrompt: systemPrompt,
    userMsg: 'Schema nonce ${DateTime.now().microsecondsSinceEpoch}+1. Acknowledge.',
    withSchemaAndTools: true,
  );

  client.close();
}
