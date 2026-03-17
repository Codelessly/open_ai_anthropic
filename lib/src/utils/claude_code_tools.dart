/// Claude Code 2.x canonical tool names.
/// Source: https://cchistory.mariozechner.at/data/prompts-2.1.11.md
const List<String> _claudeCodeTools = [
  'Read', 'Write', 'Edit', 'Bash', 'Grep', 'Glob',
  'AskUserQuestion', 'EnterPlanMode', 'ExitPlanMode', 'KillShell',
  'NotebookEdit', 'Skill', 'Task', 'TaskOutput', 'TodoWrite',
  'WebFetch', 'WebSearch',
];

final Map<String, String> _ccToolLookup = {
  for (final name in _claudeCodeTools) name.toLowerCase(): name,
};

/// Converts a tool name to Claude Code canonical casing (case-insensitive).
/// Returns the original name if no match is found.
String toClaudeCodeName(String name) =>
    _ccToolLookup[name.toLowerCase()] ?? name;

/// Reverse-maps a Claude Code tool name back to the original tool name
/// by doing a case-insensitive match against the provided tool name list.
/// Returns the CC name if no match is found.
String fromClaudeCodeName(String name, List<String>? originalToolNames) {
  if (originalToolNames == null || originalToolNames.isEmpty) return name;
  final lowerName = name.toLowerCase();
  for (final toolName in originalToolNames) {
    if (toolName.toLowerCase() == lowerName) return toolName;
  }
  return name;
}

/// Normalizes a tool call ID to match Anthropic's required pattern.
/// Pattern: `^[a-zA-Z0-9_-]+$`, max 64 characters.
String normalizeToolCallId(String id) {
  final sanitized = id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  return sanitized.length > 64 ? sanitized.substring(0, 64) : sanitized;
}
