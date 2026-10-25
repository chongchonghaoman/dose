#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/feature-guide-checks"
xcrun swiftc -swift-version 5 -parse-as-library \
    "$ROOT/Sources/LightTableApp/FeatureGuideState.swift" "$ROOT/Tests/FeatureGuideChecks.swift" \
    -o "$ROOT/.build/feature-guide-checks/FeatureGuideChecks"
"$ROOT/.build/feature-guide-checks/FeatureGuideChecks"
