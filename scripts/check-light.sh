#!/bin/bash
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKS_DIR="$PACKAGE_ROOT/.build/light-checks"
mkdir -p "$CHECKS_DIR"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$PACKAGE_ROOT/Sources/LightTableCore/LightResponse.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoStore.swift" \
  "$PACKAGE_ROOT/Tests/LightChecks.swift" -o "$CHECKS_DIR/LightChecks"
"$CHECKS_DIR/LightChecks"
