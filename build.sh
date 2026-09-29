#!/bin/sh
# Builds Mr. Usage with its pinned Sparkle updater and packages a standalone app.
set -eu
cd "$(dirname "$0")"
set -- --configuration "${CONFIGURATION:-release}" --product ClaudeUsageBar --disable-keychain
if [ "${MR_USAGE_UNIVERSAL:-0}" = 1 ]; then set -- "$@" --arch arm64 --arch x86_64; fi
swift build "$@"
BIN_DIR="$(swift build "$@" --show-bin-path)"
APP='build/Mr. Usage.app'
STAGING='build/.Mr. Usage.staging.app'
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Frameworks" "$STAGING/Contents/Resources"
cp "$BIN_DIR/ClaudeUsageBar" "$STAGING/Contents/MacOS/ClaudeUsageBar"
cp Info.plist "$STAGING/Contents/Info.plist"
SPARKLE='.build/artifacts/sparkle/Sparkle'
ditto "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$STAGING/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE/LICENSE" "$STAGING/Contents/Resources/Sparkle-LICENSE.txt"
bash scripts/sign-app.sh "$STAGING" "${MR_USAGE_SIGN_IDENTITY:--}"
rm -rf "$APP"
mv "$STAGING" "$APP"
echo "Built $APP  (run: open '$APP')"
