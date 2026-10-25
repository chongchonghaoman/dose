#!/bin/bash
set -euo pipefail

# Compile independently of SwiftPM so these checks do not compete for its lock.
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKS_DIR="$PACKAGE_ROOT/.build/drop-checks"
mkdir -p "$CHECKS_DIR"

xcrun swiftc -swift-version 5 -parse-as-library -module-name LightTableCore \
  -whole-module-optimization -emit-module -emit-module-path "$CHECKS_DIR/LightTableCore.swiftmodule" -emit-object \
  "$PACKAGE_ROOT/Sources/LightTableCore/TableLayout.swift" \
  "$PACKAGE_ROOT/Sources/LightTableCore/AlbumPage.swift" -o "$CHECKS_DIR/LightTableCore.o"

xcrun swiftc -swift-version 5 -parse-as-library -I "$CHECKS_DIR" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoStore.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoDrag.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/AlbumDrag.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/TableModel.swift" \
  "$PACKAGE_ROOT/Tests/DropChecks.swift" "$CHECKS_DIR/LightTableCore.o" \
  -o "$CHECKS_DIR/DropChecks"

"$CHECKS_DIR/DropChecks"
