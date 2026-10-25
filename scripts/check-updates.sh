#!/bin/bash
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PACKAGE_ROOT"
swift package resolve
FRAMEWORKS="$PACKAGE_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
CHECKS_DIR="$PACKAGE_ROOT/.build/update-checks"
mkdir -p "$CHECKS_DIR"
xcrun swiftc -swift-version 5 -parse-as-library \
    -F "$FRAMEWORKS" -framework Sparkle -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    Sources/LightTableApp/UpdateConfiguration.swift Sources/LightTableApp/AppUpdater.swift Tests/UpdateChecks.swift \
    -o "$CHECKS_DIR/UpdateChecks"
"$CHECKS_DIR/UpdateChecks" Configuration/Updates.plist
