# ClaudeUsageBar

A very small macOS menu bar app that shows what `/usage` shows in Claude Code:
session limit, weekly limit, and extra usage credits.

## How it gets the data

It reuses your existing Claude Code login. `claude login` stores an OAuth token in the
macOS Keychain (item "Claude Code-credentials"). The app reads that token and calls the
same usage endpoint Claude Code calls for `/usage`. There is nothing to configure.

The first launch shows a macOS Keychain prompt asking to allow ClaudeUsageBar to read
that item. Choose "Always Allow".

To make that approval survive rebuilds, run `./make-cert.sh` once first. It creates a
self-signed code-signing certificate so every build has the same identity. Without it the
app is signed ad-hoc, which changes identity on every build, and the prompt comes back.

## Build and run

```sh
./build.sh
open build/ClaudeUsageBar.app
```

Refreshes every minute and when you open the menu. Quit from the menu.

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

- `Sources/main.swift`: the whole app (AppKit + Security, no dependencies)
- `Info.plist`: marks it as a menu-bar-only app (`LSUIElement`)
- `build.sh`: compiles with `swiftc` into `build/ClaudeUsageBar.app`
