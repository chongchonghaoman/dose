#!/bin/bash
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKS_DIR="$PACKAGE_ROOT/.build/optics-checks"
mkdir -p "$CHECKS_DIR"
xcrun swiftc -swift-version 5 -parse-as-library -module-name LightTableCore \
  -emit-module -emit-module-path "$CHECKS_DIR/LightTableCore.swiftmodule" -emit-object \
  "$PACKAGE_ROOT/Sources/LightTableCore/LightResponse.swift" -o "$CHECKS_DIR/LightTableCore.o"
xcrun swiftc -swift-version 5 -parse-as-library -I "$CHECKS_DIR" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoStore.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoOptics.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/OpticalDisplay.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/LoupeRenderer.swift" \
  "$PACKAGE_ROOT/Tests/OpticsChecks.swift" "$CHECKS_DIR/LightTableCore.o" -o "$CHECKS_DIR/OpticsChecks"
"$CHECKS_DIR/OpticsChecks"
