#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
# Keep assertions enabled. The app entry point is excluded to avoid starting
# scanners or reading any provider credentials during verification.
swiftc -target "$(uname -m)-apple-macos13.0" -o build/LeaderboardTests \
  Sources/Usage.swift Sources/TokenLog.swift Sources/CodexLog.swift \
  Sources/OpenCodeLog.swift Sources/OpenAIUsage.swift Sources/Pricing.swift \
  Sources/Leaderboard.swift Tests/LeaderboardTests.swift
build/LeaderboardTests
