#!/bin/sh
# Builds build/ClaudeUsageBar.app with the system Swift compiler. No downloads, no Xcode project.
set -eu
cd "$(dirname "$0")"
APP=build/ClaudeUsageBar.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/ClaudeUsageBar" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
# Sign with the stable "ClaudeUsageBar" certificate if make-cert.sh created it, else ad-hoc.
if security find-identity -v -p codesigning | grep -q '"ClaudeUsageBar"'; then
  codesign --force --sign ClaudeUsageBar "$APP"
else
  codesign --force --sign - "$APP"
  echo "note: signed ad-hoc, so the Keychain prompt returns after each rebuild. Run ./make-cert.sh once to fix that."
fi
echo "Built $APP  (run: open $APP)"
