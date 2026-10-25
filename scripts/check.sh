#!/bin/bash
set -euo pipefail

# Resolve paths from this script, so it works from either repository or package root.
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKS_DIR="$PACKAGE_ROOT/.build/checks"
mkdir -p "$CHECKS_DIR"

xcrun swiftc -swift-version 5 -parse-as-library \
  "$PACKAGE_ROOT/Sources/LightTableCore/TableLayout.swift" \
  "$PACKAGE_ROOT/Sources/LightTableCore/AlbumPage.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoStore.swift" \
  "$PACKAGE_ROOT/Tests/SmokeChecks.swift" \
  -o "$CHECKS_DIR/SmokeChecks"

"$CHECKS_DIR/SmokeChecks"
