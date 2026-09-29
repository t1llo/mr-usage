# ClaudeUsageBar

A very small macOS menu bar app that shows what `/usage` shows in Claude Code:
session limit, weekly limit, and extra usage credits.

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

## Build and run

```sh
./build.sh
open build/ClaudeUsageBar.app
```

Click the percentages in the menu bar to open the overview: the five-hour session as a ring
with a countdown to its reset, then the weekly limits and extra-usage credits as bars. Bars turn
orange from 75% and red from 90%. Refreshes every minute and when you open the panel.

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
- `Sources/Views.swift`: the overview panel
- `Sources/Store.swift`: polling schedule and backoff
- `Sources/Usage.swift`: token read, API call, parsing, formatting
- `Info.plist`: marks it as a menu-bar-only app (`LSUIElement`)
- `build.sh`: compiles with `swiftc` into `build/ClaudeUsageBar.app`
