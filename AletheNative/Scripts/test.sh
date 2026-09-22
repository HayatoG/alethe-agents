#!/usr/bin/env bash
# Runs the whole suite from a clean checkout: string-catalog gate, package unit tests, app build.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/check-strings.py
swift test --package-path Packages/AletheKit --scratch-path build/AletheKit
Scripts/build.sh Debug
