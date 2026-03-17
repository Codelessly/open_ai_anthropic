import 'package:test/test.dart';

import 'package:open_ai_anthropic/src/utils/claude_code_tools.dart';

void main() {
  group('toClaudeCodeName', () {
    test('maps known tools case-insensitively', () {
      expect(toClaudeCodeName('bash'), 'Bash');
      expect(toClaudeCodeName('READ'), 'Read');
      expect(toClaudeCodeName('write'), 'Write');
      expect(toClaudeCodeName('Edit'), 'Edit');
      expect(toClaudeCodeName('grep'), 'Grep');
      expect(toClaudeCodeName('glob'), 'Glob');
      expect(toClaudeCodeName('webfetch'), 'WebFetch');
      expect(toClaudeCodeName('websearch'), 'WebSearch');
      expect(toClaudeCodeName('todowrite'), 'TodoWrite');
      expect(toClaudeCodeName('notebookedit'), 'NotebookEdit');
    });

    test('passes through unknown tool names unchanged', () {
      expect(toClaudeCodeName('my_custom_tool'), 'my_custom_tool');
      expect(toClaudeCodeName('mcp__server__tool'), 'mcp__server__tool');
    });
  });

  group('fromClaudeCodeName', () {
    test('maps back to original name via tool name list', () {
      final toolNames = ['my_bash', 'read_files'];
      expect(fromClaudeCodeName('my_bash', toolNames), 'my_bash');
    });

    test('returns CC name when no matching original tool', () {
      expect(fromClaudeCodeName('Read', null), 'Read');
      expect(fromClaudeCodeName('Read', []), 'Read');
      expect(fromClaudeCodeName('Bash', ['unrelated']), 'Bash');
    });
  });

  group('normalizeToolCallId', () {
    test('strips invalid characters', () {
      expect(normalizeToolCallId('call|123'), 'call_123');
      expect(normalizeToolCallId('call 123'), 'call_123');
      expect(normalizeToolCallId('a.b.c'), 'a_b_c');
    });

    test('truncates to 64 chars', () {
      final long = 'a' * 100;
      expect(normalizeToolCallId(long).length, 64);
    });

    test('passes through valid IDs unchanged', () {
      expect(normalizeToolCallId('call_abc-123'), 'call_abc-123');
      expect(normalizeToolCallId('toolu_01abc'), 'toolu_01abc');
    });
  });
}
