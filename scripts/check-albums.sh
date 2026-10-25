#!/bin/bash
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKS_DIR="$PACKAGE_ROOT/.build/album-checks"
mkdir -p "$CHECKS_DIR"
xcrun swiftc -swift-version 5 -parse-as-library -whole-module-optimization -module-name LightTableCore \
  -emit-module -emit-module-path "$CHECKS_DIR/LightTableCore.swiftmodule" -emit-object \
  "$PACKAGE_ROOT"/Sources/LightTableCore/*.swift -o "$CHECKS_DIR/LightTableCore.o"
xcrun swiftc -swift-version 5 -parse-as-library -I "$CHECKS_DIR" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoStore.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoDrag.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/AlbumDrag.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/AlbumSurface.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/LoupeRenderer.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/PhotoOptics.swift" \
  "$PACKAGE_ROOT/Sources/LightTableApp/TableModel.swift" \
  "$PACKAGE_ROOT/Tests/AlbumChecks.swift" "$CHECKS_DIR/LightTableCore.o" -o "$CHECKS_DIR/AlbumChecks"
"$CHECKS_DIR/AlbumChecks"
