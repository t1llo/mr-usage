#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
# Synthetic snapshots and isolated defaults; no credentials or provider requests.
swiftc -target "$(uname -m)-apple-macos13.0" -o build/ClaudePollingTests \
  Sources/Usage.swift Sources/ClaudePolling.swift Sources/Store.swift Tests/ClaudePollingTests.swift
build/ClaudePollingTests
