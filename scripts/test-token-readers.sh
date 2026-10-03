#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -target "$(uname -m)-apple-macos13.0" -o build/TokenReadersTests \
  Sources/Usage.swift Sources/TokenLog.swift Sources/CodexLog.swift \
  Sources/OpenCodeLog.swift Sources/OpenAIUsage.swift Sources/Pricing.swift Tests/TokenReadersTests.swift
build/TokenReadersTests
