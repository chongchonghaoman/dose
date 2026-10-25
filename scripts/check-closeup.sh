#!/bin/bash
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKS_DIR="$PACKAGE_ROOT/.build/closeup-checks"
mkdir -p "$CHECKS_DIR"
xcrun swiftc -swift-version 5 -parse-as-library -module-name LightTableCore -emit-module -emit-library \
  "$PACKAGE_ROOT/Sources/LightTableCore/TableLayout.swift" \
  "$PACKAGE_ROOT/Sources/LightTableCore/AlbumPage.swift" \
  "$PACKAGE_ROOT/Sources/LightTableCore/LightResponse.swift" \
  -emit-module-path "$CHECKS_DIR/LightTableCore.swiftmodule" -o "$CHECKS_DIR/libLightTableCore.dylib"
sources=()
for source in "$PACKAGE_ROOT"/Sources/LightTableApp/*.swift; do
  if [[ "$source" != */LightTableApp.swift ]]; then sources+=("$source"); fi
done
xcrun swiftc -swift-version 5 -parse-as-library -I "$CHECKS_DIR" -L "$CHECKS_DIR" -lLightTableCore \
  -Xlinker -rpath -Xlinker "$CHECKS_DIR" "${sources[@]}" \
  "$PACKAGE_ROOT/Tests/CloseupChecks.swift" -o "$CHECKS_DIR/CloseupChecks"
"$CHECKS_DIR/CloseupChecks"
