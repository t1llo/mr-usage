# Repository instructions

## Build and verification

- Build on macOS with `./scripts/build.sh`: Swift Package Manager compiles `Sources/*.swift` targeting macOS 13 with pinned Sparkle 2.10.0, then packages `build/Mr. Usage.app` and signs its nested helpers inside out.
- Fast verification: `swift build --product ClaudeUsageBar`. Run isolated tests with `sh scripts/test-leaderboard.sh` and `sh scripts/test-openai-credits.sh` when present.
- Run `sh scripts/test-panel-layout.sh` from a logged-in macOS desktop for native popup changes. It opens a synthetic panel and uses no provider credentials or logs.
- Launch with `open 'build/Mr. Usage.app'`. Quit the running app before checking a rebuild: `Sources/main.swift` rejects additional instances to prevent duplicate polling.
- Local builds are ad-hoc signed and timestamp their build number so Sparkle does not replace them with an older release. Distribution builds use `MR_USAGE_UNIVERSAL=1` and `MR_USAGE_SIGN_IDENTITY`. Credentials and Sparkle private keys stay in Keychain; only public verification keys belong in this repository.

## Runtime invariants

- Claude authentication reads `Claude Code-credentials` through `/usr/bin/security`; direct Keychain API access reintroduces prompts after token rotation. Keep this blocking read off the main thread and preserve `Store.cachedToken` across temporary read failures.
- Claude custom profiles use their path-hashed Keychain service; explicit Claude Code/OpenCode/Pi selections must not fall through to another account. Automatic pins its resolved tool. Profile changes clear old readings, not the global gate/backoff. Account metadata and source labels are local; never persist OAuth tokens or token-derived identifiers.
- `ClaudePollingState` saves the last good limits, request-start gate and learned backoff in local defaults, never credentials. Preserve them across launches, honor both seconds and HTTP-date `Retry-After` values, and verify changes with `sh scripts/test-claude-polling.sh`.
- `Sources/OpenAIUsage.swift` prefers an unexpired Codex `auth.json` token, then OpenCode's OAuth token. Never refresh OAuth tokens here: Codex/OpenCode own the single-use refresh tokens, and consuming them would invalidate those tools' saved logins.
- Claude refresh triggers use `Store.tick()` and its `nextFetchAt` gate: the timer checks every 15 seconds, requests start at 60-second intervals. `TokenStore` separately scans local logs every 60 seconds and gates OpenAI live limits at 120 seconds; successful plan-history fetches defer another history request for 600 seconds.
- Both live-limit pollers double their intervals on HTTP 429/5xx up to 600 seconds and honor longer `Retry-After` delays. Success does **not** reset the intervals. Preserve in-flight guards and last good data on request failure; manual refresh must respect these gates.
- OpenAI limits use the newer of the live result and Codex's logged snapshot. Display through `CodexLimits.current(now:)`, which clears windows whose reset time has passed.
- "Open at login" registers the current app bundle path via `SMAppService.mainApp`; move the bundle to its intended location before enabling it.

## Data and cross-file coupling

- `Sources/main.swift` creates `Store` (`Sources/Store.swift`, Claude limits) and `TokenStore` (`Sources/TokenLog.swift`, token logs plus OpenAI limits/history), with an explicit top-level `ClaudeUsageBarApp.main()` call rather than `@main`.
- `MenuBarApplication` runs the AppKit lifecycle without SwiftUI window scenes and discards legacy window restoration. Settings belongs inside `UsagePanel`; do not add an empty `Settings` scene, which can produce a blank standalone window.
- `MenuBarPanelController` owns the popup's native frame, anchored to the status button's screen. Keep `NSHostingView.sizingOptions` empty: `PanelViewport` measures content and supplies the size. Provider/theme popovers taking focus must not reset its position or dismiss it. Preserve the `Item-0` status-item autosave name to retain the user's menu-bar position.
- Page changes and sharing disclosures are immediate: do not animate content into a differently sized native panel. `StatusItemReadout` labels the first two server-defined windows in a template image; keep full provider/window descriptions accessible. `scripts/build-icons.sh` packages the light/dark artwork from `docs/assets/`.
- Data roots: Claude transcripts in `~/.claude/projects`; Codex auth/logs under `$CODEX_HOME` (default `~/.codex`, including `sessions` and `archived_sessions`); OpenCode auth/databases under `$XDG_DATA_HOME/opencode` (default `~/.local/share/opencode`). Counts cover local logs; OpenAI plan history is remote and daily-aggregated.
- Also read the selected Claude custom profile's `projects` folder and Pi sessions under `$PI_CODING_AGENT_DIR/sessions` (default `~/.pi/agent/sessions`). Pi rereads mutable session trees and deduplicates copied assistant messages. Its input excludes cache and its output already includes reasoning. Keep Claude's reported lifetime `stats-cache.json` separate from deduplicated transcript/chart/sharing totals; the cache may include repeated response blocks.
- Claude/Codex scanners consume complete JSONL lines incrementally and deduplicate copied/streamed responses; Codex per-response records supersede running totals. OpenCode re-reads its 31-day horizon because rows change or disappear, deduplicating forks by content. Preserve these distinctions when changing readers.
- `Sources/OpenCodeLog.swift` queries all `opencode*.db` files through SQLite to include WAL data. Its read-write fallback only runs SELECTs but allows missing WAL/SHM files to be recreated.
- OpenAI All devices and subscription leaderboard totals replace complete reported UTC days, across all models; local Codex/OpenCode logs fill only unreported days. Never add account and local totals for the same day. Preserve archived account estimates during fetch failures, including explicit zero-day coverage. API-billed sharing uses only local records.
- `TokenRecord.input` excludes cache reads/writes; output includes reasoning. Codex requires subtracting cached/write input; OpenCode requires adding reasoning to output. Costs are recomputed from `Sources/Pricing.swift` in USD; unknown models remain unpriced, not guessed.
- Limit order matters: `Sources/Views.swift` puts the first limit in the session card, and menu titles show the first two. Pace uses `Limit.window` in seconds; OpenAI windows are server-defined.
- Live usage is already a percentage; plan-history basis points divide by 100. Claude extra-usage credits are cents, unlike token API costs in USD. OpenAI credit balances are credit units; preserve their own snapshot time when newer limit snapshots omit credits.
