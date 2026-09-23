#!/usr/bin/env bash
# Runs the UI test suite (hit-target harness and interaction tests). XCUITest brings the app to the
# front and clicks inside its window; do not use the Mac while it runs.
#   Scripts/uitest.sh [-only-testing:AletheUITests/<Class>/<test>]
set -euo pipefail
cd "$(dirname "$0")/.."
Vendor/ghostty/build.sh >/dev/null
SIGN_IDENTITY="$(Scripts/dev-signing.sh)"
# Each UI test launches the app against a throwaway /private/tmp/alethe-uitest-* data folder.
trap 'rm -rf /private/tmp/alethe-uitest-*' EXIT
xcodebuild \
  -project AletheNative.xcodeproj \
  -scheme Alethe \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "build/UITests-$(date +%Y%m%d-%H%M%S).xcresult" \
  ALETHE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  "$@" \
  test
# Interactions XCUITest cannot synthesize (real mouse drags); skipped when running a subset.
if [[ $# -eq 0 ]]; then
  Scripts/smoke/sidebar-drag.sh
  Scripts/smoke/pane-drag.sh
fi
