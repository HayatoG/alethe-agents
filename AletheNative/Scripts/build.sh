#!/usr/bin/env bash
# Builds the native app. Usage: Scripts/build.sh [Debug|Release]
# Output: build/DerivedData/Build/Products/<Configuration>/Alethe.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${1:-Debug}"
SIGN_IDENTITY="$(Scripts/dev-signing.sh)"
Vendor/ghostty/build.sh >/dev/null  # libghostty + wrapper package; no-op once built
xcodebuild \
  -project AletheNative.xcodeproj \
  -scheme Alethe \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/DerivedData \
  -quiet \
  ALETHE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  build
echo "Built: $(pwd)/build/DerivedData/Build/Products/$CONFIGURATION/Alethe.app"
