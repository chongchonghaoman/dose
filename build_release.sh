#!/bin/bash
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
exec /bin/zsh "$PACKAGE_ROOT/scripts/build-app.sh" "$@"
