## 0.3.0

- Add short-lived and long-lived OAuth2 credentials with auto-detection and refresh logic.
- Add OAuth token generation and redirection server.
- Port the original Claude Code cache breakpoint strategy.
- Support adaptive thinking and output configuration in API requests.
- Improve JSON schema tool choice compatibility with adaptive thinking for OAuth; disable thinking for JSON schema output to avoid forced `tool_choice` conflicts.
- Update `openai_dart` to `^4.0.0`.
- Fix generate script.
