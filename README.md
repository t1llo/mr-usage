# ClaudeUsageBar

A very small macOS menu bar app that shows what `/usage` shows in Claude Code (session limit,
weekly limit, extra usage credits) and the same for a ChatGPT plan used through Codex CLI, plus
token counts and their API-price equivalent for Claude Code, Codex and OpenCode.

## How it gets the data

It reuses your existing Claude Code login. `claude login` stores an OAuth token in the
macOS Keychain (item "Claude Code-credentials"). The app reads that token and calls the
same usage endpoint Claude Code calls for `/usage`. There is nothing to configure.

It reads the item through `/usr/bin/security` rather than the Keychain API. Claude Code
writes the item with that same tool, so `security` is already allowed to read it and there is
no password prompt. (The earlier version asked for the Keychain password again every time
Claude Code refreshed its token, because each refresh rewrites the item and resets its access
list. That is also why signing the app, with `make-cert.sh` or an Apple Developer ID, could not
fix it.) `make-cert.sh` is no longer needed.

### OpenAI (Codex CLI and OpenCode)

Pick **OpenAI** in the dropdown next to the title. Nothing to configure either:

- **Limits** come live from the endpoint Codex's `/status` uses (`chatgpt.com/backend-api/wham/usage`),
  with the access token `codex login` stored in `~/.codex/auth.json` (or `$CODEX_HOME`), or else
  the one OpenCode's ChatGPT login stored in `~/.local/share/opencode/auth.json`. The app never
  refreshes these tokens: refresh tokens are single-use, so doing it here would sign those tools
  out. When both have expired, or Codex keeps its login in the Keychain
  (`cli_auth_credentials_store = "keyring"`), the panel shows the last snapshot Codex wrote to its
  session logs instead, marked with its time. A window whose reset time has passed shows as empty.
- **Tokens** come from Codex's session logs (`~/.codex/sessions/**/rollout-*.jsonl`, one usage
  record per API response; older logs are counted from their running totals) and from OpenCode's
  database (`~/.local/share/opencode/opencode.db`). OpenCode messages from the `openai` provider
  (API key or ChatGPT login) count under OpenAI, those from `anthropic` under Claude. Forked
  sessions are counted once. When both tools have data, the model list tags each row with the tool.
- **API cost** uses OpenAI's Standard-tier list prices for prompts under 272K tokens (as of
  2026-09-29), in `Sources/Pricing.swift`. OpenCode logs a ChatGPT login's cost as 0, so the cost
  is recomputed from the token counts.

Token counts only exist once a tool has made a request: Codex writes its session log after the
first message, so a fresh install shows no token counts until then. Above them, the OpenAI Tokens
tab shows **Plan usage**: the plan's recent weekly windows with the share of each used and the
split by model, from the same endpoint as Codex's `/usage`
(`wham/usage/plan_limit_history`). That covers every surface (CLI, IDE, cloud, OpenCode) but
is aggregated daily by OpenAI, so the current window can lag the live limit by up to a day. Codex logs compressed to `.jsonl.zst` (an experimental Codex setting)
are skipped.

## Build and run

```sh
./build.sh
open build/ClaudeUsageBar.app
```

Click the percentages in the menu bar to open the panel. It has two tabs:

- **Limits**: the five-hour session as a ring with a countdown to its reset, then the weekly
  limits and extra-usage credits as bars. Each rolling window has a marker for where usage would
  be at an even pace, and says whether you are ahead of it, on it, or under it.
- **Tokens**: input, output, cache-write and cache-read tokens over the last 24 hours, 7 days or
  30 days, as a bar chart plus totals and a per-model split. Click a total to chart it. The
  counts come from Claude Code's transcripts in `~/.claude/projects` (plus OpenCode, see above),
  so they cover this Mac only (not claude.ai or other machines). Responses that appear on several lines or
  in several files are counted once.
- **API cost**: what the same usage would cost on the Anthropic API at list prices, priced per
  response from its model, cache writes (5-minute at 1.25x input, 1-hour at 2x), cache reads and
  fast mode. It is the default chart. Prices live in `Sources/Pricing.swift` (as of 2026-09-25);
  a model missing from that table is left out of the cost and named under the chart.

The menu bar shows the selected provider's percentages. The palette button in the header
switches between Tokyo Night (default), Catppuccin Mocha and Catppuccin Latte. Refreshes every minute and when you open the panel.

If a refresh fails, the last good numbers stay on screen and a status line says why and
when the next attempt is. On HTTP 429 (rate limited) or a server error the polling interval
doubles (1, 2, 4 ... up to 10 minutes) and stays there, and the app also waits at least the
server's Retry-After. Manual Refresh and menu opens follow the same schedule, so they cannot
push the request rate above it. Only one instance runs at a time.
If the Keychain read fails momentarily (Claude Code rewrites the item when it refreshes
the token), the last seen token is reused.

To start it automatically, tick "Open at Login" in the menu. It registers the app bundle
at its current path, so keep `build/ClaudeUsageBar.app` where it is (or move it to
`/Applications` first, then tick the item).

## Layout

- `Sources/main.swift`: app entry, SwiftUI `MenuBarExtra`
- `Sources/Views.swift`: the panel and the Limits tab
- `Sources/TokensView.swift`: the Tokens tab
- `Sources/TokenLog.swift`: Claude Code transcript reader, the token store, aggregation
- `Sources/CodexLog.swift`: Codex session log reader (tokens and logged limits)
- `Sources/OpenCodeLog.swift`: OpenCode database reader
- `Sources/OpenAIUsage.swift`: live ChatGPT plan limits with Codex's login
- `Sources/Pricing.swift`: Anthropic and OpenAI price tables and per-response cost
- `Sources/Theme.swift`: color themes and the pill segmented control
- `Sources/Store.swift`: polling schedule and backoff
- `Sources/Usage.swift`: token read, API call, parsing, formatting
- `Info.plist`: marks it as a menu-bar-only app (`LSUIElement`)
- `build.sh`: compiles with `swiftc` into `build/ClaudeUsageBar.app`
