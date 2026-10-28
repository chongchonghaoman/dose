#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "${ROOT}/scripts/edr-link-flags.sh"
CHECKS="$ROOT/.build/tray-return-checks"
mkdir -p "$CHECKS"
xcrun swiftc "${EDR_SWIFT_FLAGS[@]}" -swift-version 5 -parse-as-library -module-name LightTableCore \
  -whole-module-optimization -emit-module -emit-module-path "$CHECKS/LightTableCore.swiftmodule" -emit-object \
  "$ROOT/Sources/LightTableCore/TableLayout.swift" "$ROOT/Sources/LightTableCore/AlbumPage.swift" \
  -o "$CHECKS/LightTableCore.o"
xcrun swiftc "${EDR_SWIFT_FLAGS[@]}" -swift-version 5 -parse-as-library -I "$CHECKS" \
  "$ROOT/Sources/LightTableApp/PhotoStore.swift" "$ROOT/Sources/LightTableApp/PhotoDrag.swift" \
  "$ROOT/Sources/LightTableApp/AlbumDrag.swift" "$ROOT/Sources/LightTableApp/TableModel.swift" \
  "$ROOT/Sources/LightTableApp/TrayAvailability.swift" "$ROOT/Tests/TrayReturnChecks.swift" \
  "$CHECKS/LightTableCore.o" -o "$CHECKS/TrayReturnChecks"
"$CHECKS/TrayReturnChecks"
