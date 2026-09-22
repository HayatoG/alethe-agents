#!/usr/bin/env bash
# Runs the UI test suite (hit-target harness and interaction tests). XCUITest brings the app to the
# front and clicks inside its window; do not use the Mac while it runs.
#   Scripts/uitest.sh [-only-testing:AletheUITests/<Class>/<test>]
set -euo pipefail
cd "$(dirname "$0")/.."
Vendor/ghostty/build.sh >/dev/null
SIGN_IDENTITY="$(Scripts/dev-signing.sh)"
xcodebuild \
  -project AletheNative.xcodeproj \
  -scheme Alethe \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "build/UITests-$(date +%Y%m%d-%H%M%S).xcresult" \
  ALETHE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  "$@" \
  test
