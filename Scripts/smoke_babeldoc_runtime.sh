#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    Resources/Info.plist
)"

GLOSS_RUN_BABELDOC_RUNTIME_SMOKE=1 \
  GLOSS_RUNTIME_SMOKE_APP_VERSION="$APP_VERSION" \
  swift test \
    --filter BabelDOCRuntimeDistributionTests/publicRuntimeReleaseInstallsEndToEnd
