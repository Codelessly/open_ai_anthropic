// Shared helper for dual-mode e2e tests.
//
// Each test iterates over every available [AnthropicMode] so the same
// behavioral assertions cover both:
//   * OAuth   — `ClaudeCodeOpenAIClient` (CLAUDE_CODE_CREDENTIALS env or .env)
//   * direct  — `AnthropicOpenAIClient`  (ANTHROPIC_API_KEY env or .env)
//
// Modes are loaded from `Platform.environment` first, then fall back to a
// `.env` file in the current working directory. Tests are skipped when
// their mode has no credentials wired.
import 'dart:io';

import 'package:open_ai_anthropic/open_ai_anthropic.dart';
import 'package:openai_dart/openai_dart.dart' as oai;

/// Identity of an Anthropic auth path.
enum AnthropicMode {
  oauth('OAuth (ClaudeCodeOpenAIClient)'),
  directApiKey('Direct API key (AnthropicOpenAIClient)');

  const AnthropicMode(this.label);
  final String label;
}

/// Bundle of credentials + factory for one [AnthropicMode].
class ModeFixture {
  final AnthropicMode mode;
  final oai.OpenAIClient Function({BodyTransformer? bodyTransformer, BodyTransformer? responseBodyTransformer})
  buildClient;

  const ModeFixture({required this.mode, required this.buildClient});

  String get label => mode.label;
}

/// Loaded once at file scope: every mode for which credentials exist.
List<ModeFixture> loadAvailableModes() {
  final List<ModeFixture> out = [];

  final creds = _loadClaudeCodeCredentials();
  if (creds != null) {
    out.add(
      ModeFixture(
        mode: AnthropicMode.oauth,
        buildClient: ({bodyTransformer, responseBodyTransformer}) => ClaudeCodeOpenAIClient(
          credentials: creds,
          bodyTransformer: bodyTransformer,
          responseBodyTransformer: responseBodyTransformer,
        ),
      ),
    );
  }

  final apiKey = _loadAnthropicApiKey();
  if (apiKey != null) {
    out.add(
      ModeFixture(
        mode: AnthropicMode.directApiKey,
        buildClient: ({bodyTransformer, responseBodyTransformer}) => AnthropicOpenAIClient(
          apiKey: apiKey,
          bodyTransformer: bodyTransformer,
          responseBodyTransformer: responseBodyTransformer,
        ),
      ),
    );
  }

  return out;
}

ClaudeCodeCredentials? _loadClaudeCodeCredentials() {
  final envVar = Platform.environment['CLAUDE_CODE_CREDENTIALS'];
  if (envVar != null && envVar.isNotEmpty) {
    return ClaudeCodeCredentials.fromJsonString(envVar);
  }
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

String? _loadAnthropicApiKey() {
  final fromEnv = Platform.environment['ANTHROPIC_API_KEY'];
  if (fromEnv != null && fromEnv.isNotEmpty) return _stripQuotes(fromEnv);
  final envFile = File('.env');
  if (!envFile.existsSync()) return null;
  for (final line in envFile.readAsLinesSync()) {
    if (line.startsWith('ANTHROPIC_API_KEY=')) {
      return _stripQuotes(line.substring('ANTHROPIC_API_KEY='.length).trim());
    }
  }
  return null;
}

String _stripQuotes(String value) {
  var v = value.trim();
  if (v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
  if (v.startsWith("'") && v.endsWith("'")) v = v.substring(1, v.length - 1);
  return v;
}

/// Convenience: read OPENAI_API_KEY (used by cross-provider tests).
String? loadOpenAiApiKey() {
  final fromEnv = Platform.environment['OPENAI_API_KEY'];
  if (fromEnv != null && fromEnv.isNotEmpty) return _stripQuotes(fromEnv);
  final envFile = File('.env');
  if (!envFile.existsSync()) return null;
  for (final line in envFile.readAsLinesSync()) {
    if (line.startsWith('OPENAI_API_KEY=')) {
      return _stripQuotes(line.substring('OPENAI_API_KEY='.length).trim());
    }
  }
  return null;
}
