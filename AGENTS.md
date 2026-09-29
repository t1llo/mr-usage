# Repository instructions

## Build and verification

- Build on macOS with `./build.sh`: Swift Package Manager compiles `Sources/*.swift` targeting macOS 13 with pinned Sparkle 2.10.0, then packages `build/Mr. Usage.app` and signs its nested helpers inside out.
- Fast verification: `swift build --product ClaudeUsageBar`. Run isolated leaderboard tests with `sh test-leaderboard.sh` when present.
- Launch with `open 'build/Mr. Usage.app'`. Quit the running app before checking a rebuild: `Sources/main.swift` rejects additional instances to prevent duplicate polling.
- Local builds are ad-hoc signed. Distribution builds use `MR_USAGE_UNIVERSAL=1` and `MR_USAGE_SIGN_IDENTITY`. Credentials and Sparkle private keys stay in Keychain; only public verification keys belong in this repository.

## Runtime invariants

- Claude authentication reads `Claude Code-credentials` through `/usr/bin/security`; direct Keychain API access reintroduces prompts after token rotation. Keep this blocking read off the main thread and preserve `Store.cachedToken` across temporary read failures.
- `Sources/OpenAIUsage.swift` prefers an unexpired Codex `auth.json` token, then OpenCode's OAuth token. Never refresh OAuth tokens here: Codex/OpenCode own the single-use refresh tokens, and consuming them would invalidate those tools' saved logins.
- Claude refresh triggers use `Store.tick()` and its `nextFetchAt` gate: the timer checks every 15 seconds, requests start at 60-second intervals. `TokenStore` separately scans local logs every 60 seconds and gates OpenAI live limits at 120 seconds; successful plan-history fetches defer another history request for 600 seconds.
- Both live-limit pollers double their intervals on HTTP 429/5xx up to 600 seconds and honor longer `Retry-After` delays. Success does **not** reset the intervals. Preserve in-flight guards and last good data on request failure; manual refresh must respect these gates.
- OpenAI limits use the newer of the live result and Codex's logged snapshot. Display through `CodexLimits.current(now:)`, which clears windows whose reset time has passed.
- "Open at login" registers the current app bundle path via `SMAppService.mainApp`; move the bundle to its intended location before enabling it.

## Data and cross-file coupling

- `Sources/main.swift` creates `Store` (`Sources/Store.swift`, Claude limits) and `TokenStore` (`Sources/TokenLog.swift`, token logs plus OpenAI limits/history), with an explicit top-level `ClaudeUsageBarApp.main()` call rather than `@main`.
- Data roots: Claude transcripts in `~/.claude/projects`; Codex auth/logs under `$CODEX_HOME` (default `~/.codex`, including `sessions` and `archived_sessions`); OpenCode auth/databases under `$XDG_DATA_HOME/opencode` (default `~/.local/share/opencode`). Counts cover local logs; OpenAI plan history is remote and daily-aggregated.
- Claude/Codex scanners consume complete JSONL lines incrementally and deduplicate copied/streamed responses; Codex per-response records supersede running totals. OpenCode re-reads its 31-day horizon because rows change or disappear, deduplicating forks by content. Preserve these distinctions when changing readers.
- `Sources/OpenCodeLog.swift` queries all `opencode*.db` files through SQLite to include WAL data. Its read-write fallback only runs SELECTs but allows missing WAL/SHM files to be recreated.
- `TokenRecord.input` excludes cache reads/writes; output includes reasoning. Codex requires subtracting cached/write input; OpenCode requires adding reasoning to output. Costs are recomputed from `Sources/Pricing.swift` in USD; unknown models remain unpriced, not guessed.
- Limit order matters: `Sources/Views.swift` puts the first limit in the session card, and menu titles show the first two. Pace uses `Limit.window` in seconds; OpenAI windows are server-defined.
- Live usage is already a percentage; plan-history basis points divide by 100. Extra-usage credits are cents, unlike token API costs in USD.
