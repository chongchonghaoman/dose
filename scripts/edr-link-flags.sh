#!/bin/bash
# Shared linkage for checks compiled outside SwiftPM. No private source required.
EDR_PACKAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EDR_FRAMEWORK_ROOT="$EDR_PACKAGE_ROOT/Binaries/LightTableEDR.xcframework/macos-arm64_x86_64"
if [[ ! -d "$EDR_FRAMEWORK_ROOT/LightTableEDR.framework" ]]; then
    printf '%s\n' 'Missing LightTableEDR binary component.' >&2
    exit 1
fi
EDR_SWIFT_FLAGS=(-F "$EDR_FRAMEWORK_ROOT" -framework LightTableEDR
                 -Xlinker -rpath -Xlinker "$EDR_FRAMEWORK_ROOT")
