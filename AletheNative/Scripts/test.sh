#!/usr/bin/env bash
# Runs the whole suite from a clean checkout: package unit tests, then an app build.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/AletheKit --scratch-path build/AletheKit
Scripts/build.sh Debug
