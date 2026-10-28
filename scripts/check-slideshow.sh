#!/bin/bash
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$PACKAGE_ROOT/scripts/edr-link-flags.sh"
CHECKS_DIR="$PACKAGE_ROOT/.build/slideshow-checks"
mkdir -p "$CHECKS_DIR"
for sound in ShutterClick ShutterClickRoom ShutterArrivalRoom; do
  cp "$PACKAGE_ROOT/Sources/LightTableApp/Resources/$sound.wav" "$CHECKS_DIR/$sound.wav"
done
xcrun swiftc "${EDR_SWIFT_FLAGS[@]}" -swift-version 5 -parse-as-library -module-name LightTableCore -emit-module -emit-library \
  "$PACKAGE_ROOT/Sources/LightTableCore/TableLayout.swift" \
  "$PACKAGE_ROOT/Sources/LightTableCore/AlbumPage.swift" \
  "$PACKAGE_ROOT/Sources/LightTableCore/LightResponse.swift" \
  "$PACKAGE_ROOT/Sources/LightTableCore/StartupPresentationProgress.swift" \
  -emit-module-path "$CHECKS_DIR/LightTableCore.swiftmodule" -o "$CHECKS_DIR/libLightTableCore.dylib"
sources=()
for source in "$PACKAGE_ROOT"/Sources/LightTableApp/*.swift; do
  if [[ "$source" != */LightTableApp.swift ]]; then sources+=("$source"); fi
done
xcrun swiftc "${EDR_SWIFT_FLAGS[@]}" -swift-version 5 -parse-as-library -I "$CHECKS_DIR" -L "$CHECKS_DIR" -lLightTableCore \
  -Xlinker -rpath -Xlinker "$CHECKS_DIR" "${sources[@]}" \
  "$PACKAGE_ROOT/Tests/SlideshowChecks.swift" -o "$CHECKS_DIR/SlideshowChecks"
"$CHECKS_DIR/SlideshowChecks"
