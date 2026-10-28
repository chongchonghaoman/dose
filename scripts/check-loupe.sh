#!/bin/bash
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$PACKAGE_ROOT/scripts/edr-link-flags.sh"
CHECKS_DIR="$PACKAGE_ROOT/.build/loupe-checks"
mkdir -p "$CHECKS_DIR"
xcrun swiftc "${EDR_SWIFT_FLAGS[@]}" -swift-version 5 -parse-as-library -module-name LightTableCore \
  -emit-module -emit-module-path "$CHECKS_DIR/LightTableCore.swiftmodule" -emit-object \
  "$PACKAGE_ROOT/Sources/LightTableCore/LightResponse.swift" -o "$CHECKS_DIR/LightTableCore.o"
xcrun swiftc "${EDR_SWIFT_FLAGS[@]}" -swift-version 5 -parse-as-library -I "$CHECKS_DIR" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoStore.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/LoupeRenderer.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/LoupeTextureCache.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoOptics.swift" \
  "$PACKAGE_ROOT/Tests/LoupeChecks.swift" "$CHECKS_DIR/LightTableCore.o" \
  -o "$CHECKS_DIR/LoupeChecks"
"$CHECKS_DIR/LoupeChecks"
