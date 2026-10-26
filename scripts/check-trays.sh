#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKS="$ROOT/.build/tray-checks"
mkdir -p "$CHECKS"
xcrun swiftc -swift-version 5 -parse-as-library -module-name LightTableCore \
  -whole-module-optimization -emit-module -emit-module-path "$CHECKS/LightTableCore.swiftmodule" -emit-object \
  "$ROOT/Sources/LightTableCore/TableLayout.swift" "$ROOT/Sources/LightTableCore/AlbumPage.swift" -o "$CHECKS/LightTableCore.o"
xcrun swiftc -swift-version 5 -parse-as-library -I "$CHECKS" \
  "$ROOT/Sources/LightTableApp/PhotoStore.swift" "$ROOT/Sources/LightTableApp/PhotoDrag.swift" \
  "$ROOT/Sources/LightTableApp/AlbumDrag.swift" "$ROOT/Sources/LightTableApp/TableModel.swift" \
  "$ROOT/Tests/TrayChecks.swift" "$CHECKS/LightTableCore.o" -o "$CHECKS/TrayChecks"
"$CHECKS/TrayChecks"
