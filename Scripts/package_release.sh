#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${GLOSS_APP_PATH:-$ROOT_DIR/dist/Gloss.app}"
OUTPUT_DIRECTORY="${GLOSS_RELEASE_OUTPUT:-$ROOT_DIR/dist/release}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Gloss.app not found: $APP_PATH" >&2
  echo "Run Scripts/build_app.sh first." >&2
  exit 66
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ARCHITECTURE="${GLOSS_RELEASE_ARCHITECTURE:-$(uname -m)}"
case "$ARCHITECTURE" in
  arm64|aarch64)
    ARCHITECTURE="arm64"
    ;;
  x86_64|amd64)
    ARCHITECTURE="x86_64"
    ;;
  *)
    echo "Unsupported release architecture: $ARCHITECTURE" >&2
    exit 65
    ;;
esac
ARCHIVE_PATH="$OUTPUT_DIRECTORY/Gloss-macos-$ARCHITECTURE.zip"

mkdir -p "$OUTPUT_DIRECTORY"
rm -f "$ARCHIVE_PATH"
codesign --verify --deep --strict "$APP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
printf '%s\n' "$VERSION" >"$OUTPUT_DIRECTORY/version.txt"
echo "$ARCHIVE_PATH"
