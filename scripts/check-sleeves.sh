#!/bin/bash
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKS_DIR="$PACKAGE_ROOT/.build/sleeve-checks"
mkdir -p "$CHECKS_DIR"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$PACKAGE_ROOT/Sources/LightTableApp/SleeveMotion.swift" \
  "$PACKAGE_ROOT/Tests/SleeveChecks.swift" -o "$CHECKS_DIR/SleeveChecks"
"$CHECKS_DIR/SleeveChecks"
