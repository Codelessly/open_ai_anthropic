// Probes whether Anthropic's OpenAI-compat layer at /v1/chat/completions
// honors cache_control markers in the OpenAI-format body that
// agent_kit's `addCacheBreakpointsAnthropic` produces.
//
// This mimics what the bench's `OpenAIClientWrapperExtension.createChatCompletionStreamExtended`
// actually puts on the wire (vs the Anthropic-native /v1/messages path my converter targets).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

String _massiveSystem() {
  final buf = StringBuffer();
  buf.writeln('You are an expert.');
  for (int i = 0; i < 200; i++) {
    buf.writeln('## Section $i - parameter ${i}_alpha = ${i * 17 + 42}.');
    buf.writeln('Component ${i}_beta calibration: threshold ${i * 31 + 7}.');
    buf.writeln('Cross-reference section ${i + 1}.');
    buf.writeln();
  }
  return buf.toString();
}

String? _apiKey() {
  final f = File('/Users/saadardati/IdeaProjects/llmcouncil/server/.env');
  for (final l in f.readAsLinesSync()) {
    if (l.startsWith('ANTHROPIC_API_KEY=')) {
      var v = l.substring('ANTHROPIC_API_KEY='.length).trim();
      if (v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
      return v;
    }
  }
  return null;
}

Future<void> _runOne({
  required String label,
  required Map<String, dynamic> body,
  required String apiKey,
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('https://api.anthropic.com/v1/chat/completions'));
    req.headers.set('content-type', 'application/json');
    req.headers.set('x-api-key', apiKey);
    req.headers.set('anthropic-version', '2023-06-01');
    req.write(jsonEncode(body));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      print('$label HTTP ${resp.statusCode}: $text');
      return;
    }
    final json = jsonDecode(text) as Map<String, dynamic>;
    final usage = json['usage'] as Map<String, dynamic>?;
    print('$label: usage=$usage');
  } finally {
    client.close();
  }
}

Future<void> main() async {
  final apiKey = _apiKey()!;
  final system = _massiveSystem();
  print('System: ${system.length} chars');

  // Variant 1: OpenAI-format body WITHOUT cache_control anywhere.
  await _runOne(
    label: 'V1 oai-format, no cache_control',
    apiKey: apiKey,
    body: {
      'model': 'claude-haiku-4-5',
      'max_tokens': 64,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': 'Echo OK. nonce ${DateTime.now().microsecondsSinceEpoch}'},
      ],
    },
  );

  // Variant 2: OpenAI-format body with cache_control mirroring what
  // `addCacheBreakpointsAnthropic` does — system + last user message as blocks.
  Map<String, dynamic> withCC() => {
    'model': 'claude-haiku-4-5',
    'max_tokens': 64,
    'messages': [
      {
        'role': 'system',
        'content': [
          {
            'type': 'text',
            'text': system,
            'cache_control': {'type': 'ephemeral'},
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {
            'type': 'text',
            'text': 'Echo OK. nonce ${DateTime.now().microsecondsSinceEpoch}',
            'cache_control': {'type': 'ephemeral'},
          },
        ],
      },
    ],
  };

  await _runOne(label: 'V2.a oai-format + cache_control (warm 1)', apiKey: apiKey, body: withCC());
  await _runOne(label: 'V2.b oai-format + cache_control (warm 2)', apiKey: apiKey, body: withCC());
}
