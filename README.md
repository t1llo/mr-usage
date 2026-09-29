# Mr. Usage

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
first message, so a fresh install shows no token counts until then.

With a ChatGPT login the OpenAI tabs also show the account-wide numbers Codex's `/usage` shows,
which cover every surface (CLI, IDE, app, cloud, OpenCode) on every machine:

- **Tokens** (the "All devices" view) looks like the Claude one: tokens per day over 7 or 30
  days, the API cost, input, output and cache totals, the split by model, plus lifetime tokens,
  peak day, streak and chat count. The account reports only total tokens per day
  (`wham/profiles/me`) and each model's share of each day (`wham/usage/daily-token-usage-breakdown`),
  so the split into input, cache reads and output, and with it the API cost, is an **estimate**:
  from this Mac's Codex logs when they hold at least 1M tokens, else a typical Codex session
  (88% cache reads, 10% uncached input, 2% output). "This Mac" shows the exact counts from the
  logs, when there are any.
- **Limits** adds the plan's recent weekly windows with the share of each used and the split by
  model (`wham/usage/plan_limit_history`).

OpenAI aggregates the account numbers daily, so today is missing and the current window can lag
the live limit by up to a day. Codex logs compressed to `.jsonl.zst` (an experimental Codex
setting) are skipped.

## Build and run

```sh
./build.sh
open 'build/Mr. Usage.app'
```

The build requires Swift 6+ and macOS 13+, resolves the pinned Sparkle 2.10.0 package, and packages a standalone app. Local builds are ad-hoc signed; published downloads are Developer ID-signed and notarized.

### Automatic app updates

Install **Mr. Usage.app** in Applications. Sparkle checks for new releases hourly and automatically downloads signed updates, which install when the app quits. You can also choose **Install and Relaunch** when offered. The footer's download-circle menu provides **Check for Updates…** and toggles for automatic checks and installation.

The app verifies both update feeds and archives with an embedded public EdDSA key. Private signing keys stay in the release Mac's Keychain. The feed is `https://github.com/t1llo/mr-usage/releases/latest/download/appcast.xml`; downloads work once this repository is public. Older app builds without Sparkle need a one-time manual upgrade.

Click the percentages in the menu bar to open the panel. Both providers have two tabs:

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
shows color previews for Tokyo Night (default), Catppuccin Mocha and Catppuccin Latte.
The gear beside Refresh opens **Settings**, where you can save your leaderboard name and
billing preferences. The **Limits** and **Tokens** tabs stay visible in Settings; click either
tab, click **×**, or press **Escape** to return to usage. The panel keeps the same size while switching
pages, with scrollbar-free scrolling for longer content. Refreshes every minute and when you open the panel.

If a refresh fails, the last good numbers stay on screen and a status line says why and
when the next attempt is. On HTTP 429 (rate limited) or a server error the polling interval
doubles (1, 2, 4 ... up to 10 minutes) and stays there, and the app also waits at least the
server's Retry-After. Manual Refresh and menu opens follow the same schedule, so they cannot
push the request rate above it. Only one instance runs at a time.
If the Keychain read fails momentarily (Claude Code rewrites the item when it refreshes
the token), the last seen token is reused.

To start it automatically, tick "Open at Login" in the menu. It registers the app bundle
at its current path, so keep `build/Mr. Usage.app` where it is (or move it to
`/Applications` first, then tick the item).

## Leaderboard

The production website is [usage.beffa.xyz](https://usage.beffa.xyz), hard-coded through
`LeaderboardConfiguration.origin` in `Sources/Leaderboard.swift`. Names and billing preferences
can be saved locally before turning on sharing.

1. Open **Settings** using the gear beside Refresh.
2. Enter your display name.
3. For **Claude Code** and **Codex**, choose **Subscription**, **API billed**, or **Not shared**.
   Historical logs cannot reliably identify billing. The selection applies to all retained
   shared history for that tool; leave mixed/unknown history unshared.
4. Click **Save profile**, turn on **Share on leaderboard**, and use **Open leaderboard**
   to visit the rankings.

Sharing is **off by default**. **Exactly what gets shared**, directly below the sharing toggle,
lists the complete upload: your chosen display name and rows containing the UTC date, tool,
model ID, billing category, uncached input tokens, output tokens (including reasoning), cache-read
tokens, and separate 5-minute and 1-hour cache-write counts. Requests also send a dedicated
leaderboard authentication token, data-format version, sharing-consent flag and app identifier;
the server sees your connection's IP address. Dollar estimates are calculated by the website.

Prompts, conversations, source code, provider API keys, OAuth tokens, project paths, session IDs,
plan limits and payment details are not uploaded. OpenCode remains in the local charts and is not
uploaded by this integration. The new OpenAI **All devices** estimates also remain local: the
leaderboard uses exact **This Mac** log categories, avoiding double-counting account totals.

The subscription board displays **estimated API-equivalent value**, not your subscription
bill. API-billed usage is also a standard-rate estimate, not a verified provider invoice.
The website calculates prices independently from its versioned price list; its estimates
can differ from the app’s per-response costs, which also account for fast mode.

The first sync includes the most recent **30 UTC days**. Older shared daily aggregates are
retained locally so the leaderboard’s all-time total can grow beyond the scanners’ 31-day
window. Recent days are replaced, never incremented twice. Sync runs every five minutes,
including while the panel is closed, with backoff and Retry-After handling on errors.

Turn sharing off to delete the public profile and all its usage. An in-flight upload finishes
before the removal request; offline removals persist and retry after reconnection or restart.
Existing profiles keep their original service address for updates and removal. All-time aggregate
history is cleared on successful removal. Sharing again requires another explicit opt-in.

A dedicated random leaderboard credential and aggregate history are stored in
`~/Library/Application Support/ClaudeUsageBar/leaderboard.json` (owner-only file permissions,
inside an owner-only directory). This is separate from provider authentication. Local HTTP
origins (`localhost`, `127.0.0.1`, `::1`) are accepted for development; remote sites require HTTPS.
Redirects are refused so credentials stay on the configured origin.

Run isolated sharing checks with `sh test-leaderboard.sh`. To also test native Swift upload,
server-side pricing and removal against the website's local preview:

```sh
LEADERBOARD_TEST_ORIGIN=http://127.0.0.1:4173 sh test-leaderboard.sh
```

These tests use synthetic counts and a temporary state file; they do not read provider logs.

## Layout

- `Sources/main.swift`: app entry, SwiftUI `MenuBarExtra`
- `Sources/Views.swift`: the panel and the Limits tab
- `Sources/TokensView.swift`: the Tokens tab
- `Sources/TokenLog.swift`: Claude Code transcript reader, the token store, aggregation
- `Sources/Leaderboard.swift`: opt-in state, aggregate archive, sync and removal
- `Sources/LeaderboardView.swift`: leaderboard profile and sharing settings
- `Sources/CodexLog.swift`: Codex session log reader (tokens and logged limits)
- `Sources/OpenCodeLog.swift`: OpenCode database reader
- `Sources/OpenAIUsage.swift`: live ChatGPT plan limits with Codex's login
- `Sources/Pricing.swift`: Anthropic and OpenAI price tables and per-response cost
- `Sources/Theme.swift`: color themes, appearance picker, toolbar buttons and the pill segmented control
- `Sources/Store.swift`: polling schedule and backoff
- `Sources/Usage.swift`: token read, API call, parsing, formatting
- `Info.plist`: marks it as a menu-bar-only app (`LSUIElement`)
- `Package.swift`: app target and pinned Sparkle updater dependency
- `Sources/UpdateService.swift`: automatic updates and update menu
- `build.sh`: builds and packages `build/Mr. Usage.app`, including Sparkle and its license
