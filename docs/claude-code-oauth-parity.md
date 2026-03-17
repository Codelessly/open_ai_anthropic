# Claude Code OAuth Parity

**Date:** 2026-03-17

## Summary

OAuth tokens (`sk-ant-oat01-*`) from Claude Code subscriptions require specific request formatting to access Sonnet and Opus models via `api.anthropic.com/v1/messages`. Without this, the API returns `400 invalid_request_error: Error` — Haiku works but all higher-tier models are blocked.

The fix was discovered by analyzing [pi-mono](https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/providers/anthropic.ts), a confirmed-working open-source implementation. Three other projects were also analyzed:
- **craft-agents-oss** — spawns the Claude Code CLI binary (doesn't make direct HTTP calls)
- **openclaw** — uses closed-source `pi-ai` library with identical beta headers
- **opencode** — had OAuth support but was forced to remove it after Anthropic legal demands

## Root Cause

The API requires a **Claude Code identity system prompt** as the first system block:

```json
{
  "system": [
    {
      "type": "text",
      "text": "You are Claude Code, Anthropic's official CLI for Claude.",
      "cache_control": {"type": "ephemeral"}
    }
  ]
}
```

This single change turns 400 → 200 for Sonnet/Opus with OAuth tokens.

## What Was Implemented (P0)

All changes match pi-mono's confirmed-working behavior:

### 1. Claude Code Identity System Prompt
When `isOAuth` is true, the request converter prepends the identity block before the user's system prompt. Both blocks get `cache_control: {type: "ephemeral"}`.

### 2. OAuth Headers
```
Authorization: Bearer sk-ant-oat01-...
anthropic-beta: oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14
user-agent: claude-cli/2.1.75
x-app: cli
accept: application/json
anthropic-dangerous-direct-browser-access: true
```

### 3. Adaptive Thinking for 4.6 Models
For `claude-sonnet-4-6` and `claude-opus-4-6`, the request includes `thinking: {type: "adaptive"}`. Temperature is stripped when thinking is active (they're incompatible).

### 4. Tool Name Remapping
Tools matching Claude Code's canonical names are remapped case-insensitively:
`bash` → `Bash`, `read` → `Read`, `write` → `Write`, etc. Unknown tool names pass through unchanged.

### 5. Automatic Cache Breakpoints
- System prompt blocks: `cache_control: {type: "ephemeral"}` on every block
- Last user message: `cache_control` on the last content block
- These are applied automatically for OAuth; API key clients use `bodyTransformer` for manual control

### 6. Higher Default max_tokens
OAuth mode defaults to `16384` (vs `4096` for API key mode), closer to pi-mono's `modelMaxTokens / 3`.

### 7. Tool Call ID Normalization
IDs are sanitized to `[a-zA-Z0-9_-]`, max 64 chars, for cross-provider compatibility.

## Files Changed

| File | Change |
|------|--------|
| `lib/src/client/client.dart` | Added `isOAuth` field, threaded through resource chain |
| `lib/src/client/claude_code_client.dart` | Set `isOAuth: true`, added OAuth headers |
| `lib/src/converters/request/chat_completion_request_converter.dart` | System prompt, thinking, temperature guard, cache control, max_tokens |
| `lib/src/mappers/tool_mapper.dart` | Tool name remapping for OAuth, tool call ID normalization |
| `lib/src/utils/claude_code_tools.dart` | **New** — CC tool name mapping utility |

## Remaining Differences (P1/P2)

See the full 23-item diff below for items not yet implemented. Key ones:

- **Conditional interleaved-thinking beta** — pi-mono skips it for 4.6 models
- **Orphaned tool call synthetic results** — insert error results for unanswered tool calls
- **Thinking block signature handling** — convert missing-signature thinking to plain text
- **Redacted thinking passthrough** — forward `redacted_thinking` blocks
- **Unicode surrogate sanitization** — strip lone surrogates from text content
- **Cache TTL** — `ttl: "1h"` for long retention on `api.anthropic.com`

---

## Full pi-mono Diff (23 Items)

### P0 — Implemented

| # | Item | Status |
|---|------|--------|
| 1 | System prompt with Claude Code identity | Done |
| 2 | Full OAuth headers | Done |
| 3 | Tool name remapping | Done |
| 4 | Thinking configuration (adaptive for 4.6) | Done |
| 5 | Temperature + thinking guard | Done |
| 6 | Max tokens default | Done |
| 7 | Cache control on system prompt | Done |
| 8 | Cache control on last user message | Done |
| 10 | Tool call ID normalization | Done |

### P1 — Not Yet Implemented

| # | Item |
|---|------|
| 9 | Cache TTL for long retention (`ttl: "1h"`) |
| 15 | Conditional interleaved-thinking beta header for 4.6 models |
| 16 | Orphaned tool call synthetic error results |
| 19 | API key client beta headers |

### P2 — Not Yet Implemented

| # | Item |
|---|------|
| 11 | Thinking blocks with missing/empty signatures → plain text |
| 12 | Redacted thinking block passthrough |
| 13 | Empty text block filtering |
| 14 | Consecutive toolResult merging (already implemented) |
| 17 | Errored/aborted assistant message skipping |
| 18 | Unicode surrogate sanitization |
| 20 | Reverse tool name remapping in responses |
| 21 | Metadata user_id forwarding |
| 22 | Image-only content placeholder |
| 23 | Empty user message filtering |
