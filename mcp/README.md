# Chorus MCP server

Lets a coding agent (Claude Code, Codex…) put a question to the AI web panels open in Chorus and
read every answer back — through the user's own subscriptions, with no API billing, and reaching
the live-search / deep-research modes those web UIs have but their APIs don't.

## Setup

1. Chorus → Settings → **Coding-agent access** → on. (Off by default.)
2. Register the server once, globally:

   ```bash
   claude mcp add chorus --scope user -- node ~/.chorus-mcp/server.mjs
   ```

   (Copy `server.mjs` to `~/.chorus-mcp/` first, or point the command at this file.)

The token is read from the app's own defaults, so there's nothing to paste. `CHORUS_TOKEN`
overrides it if you'd rather be explicit.

## Tool

`ask_other_ais(prompt)` → each open panel's answer, raw and unsummarized.

Answers are NOT synthesized on purpose: the reason to ask several AIs is to see where they
disagree, and a summary flattens exactly that.

## Limits (by design, not by accident)

- One question per 30s. Consumer web UIs flag superhuman cadence, and these are the user's real
  logged-in accounts — the bridge stays human-paced no matter what loop the caller is in.
- Only the panels the user currently has on screen; a caller can't name providers or wake hidden
  ones.
- Chorus must be running and logged in. Every question appears in its window, where the user can
  watch it and stop it.
