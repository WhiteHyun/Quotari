# Poll provider usage endpoints instead of CLI-provided channels

Quotari reads quota by polling `api.anthropic.com/api/oauth/usage` and
`chatgpt.com/backend-api/wham/usage`, the endpoints the official CLIs use, even
though neither is publicly documented. The documented alternatives cover less or
cost more:

- The `rate_limits` object that Claude Code passes to statusline scripts carries
  only the 5-hour and 7-day windows, and it arrives only while a session is
  running.
- The Codex app-server's `account/rateLimits/read` requires Quotari to launch
  and manage a `codex` process.

The open-source Codex client is the reference for the `wham/usage` response
schema, including its reset credits and additional limits. The app-server
remains the fallback if that endpoint changes incompatibly.
