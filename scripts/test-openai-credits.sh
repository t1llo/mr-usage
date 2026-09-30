#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
# Keep assertions enabled and exclude the app entry point; tests never create a live token store.
swiftc -target "$(uname -m)-apple-macos13.0" -o build/OpenAICreditsTests \
  Sources/Usage.swift Sources/TokenLog.swift Sources/CodexLog.swift \
  Sources/OpenCodeLog.swift Sources/OpenAIUsage.swift Sources/Pricing.swift \
  Tests/OpenAICreditsTests.swift
build/OpenAICreditsTests
