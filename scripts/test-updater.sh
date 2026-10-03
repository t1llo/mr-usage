#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if [ ! -d "$SPARKLE/Sparkle.framework" ]; then swift build --product ClaudeUsageBar; fi
# Requires a logged-in macOS desktop. Only synthetic callbacks/windows, no update requests.
swiftc -target "$(uname -m)-apple-macos13.0" -F "$SPARKLE" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$SPARKLE" -o build/UpdateServiceTests \
  Sources/Usage.swift Sources/Theme.swift Sources/StatusItemReadout.swift \
  Sources/MenuBarApplication.swift Sources/MenuBarPanel.swift Sources/UpdateService.swift Tests/UpdateServiceTests.swift
build/UpdateServiceTests
