#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
# Requires a logged-in macOS desktop; briefly opens a synthetic menu-bar panel.
swiftc -target "$(uname -m)-apple-macos13.0" -o build/PanelLayoutTests \
  Sources/MenuBarPanel.swift Sources/PanelLayout.swift Tests/PanelLayoutTests.swift
build/PanelLayoutTests
