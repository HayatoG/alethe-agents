#!/usr/bin/env bash
# Builds the native app. Usage: Scripts/build.sh [Debug|Release]
# Output: build/DerivedData/Build/Products/<Configuration>/Alethe.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${1:-Debug}"
xcodebuild \
  -project AletheNative.xcodeproj \
  -scheme Alethe \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/DerivedData \
  -quiet \
  build
echo "Built: $(pwd)/build/DerivedData/Build/Products/$CONFIGURATION/Alethe.app"
