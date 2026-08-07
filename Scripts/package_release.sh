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
VARIANT="${GLOSS_RELEASE_VARIANT:-standard}"
case "$VARIANT" in
  standard)
    ARCHIVE_SUFFIX=""
    if [[ -e "$APP_PATH/Contents/Helpers/gloss-codex-app-server" ]]; then
      echo "Standard release must not bundle the Codex app-server." >&2
      exit 65
    fi
    ;;
  with-codex)
    ARCHIVE_SUFFIX="-with-codex"
    for bundled_file in \
      "$APP_PATH/Contents/Helpers/gloss-codex-app-server" \
      "$APP_PATH/Contents/Resources/Codex-LICENSE.txt" \
      "$APP_PATH/Contents/Resources/CodexRuntime.lock"; do
      if [[ ! -f "$bundled_file" ]]; then
        echo "Codex release is missing bundled file: $bundled_file" >&2
        exit 65
      fi
    done
    ;;
  *)
    echo "Unsupported release variant: $VARIANT" >&2
    exit 65
    ;;
esac
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
ARCHIVE_PATH="$OUTPUT_DIRECTORY/Gloss-macos-$ARCHITECTURE$ARCHIVE_SUFFIX.zip"

mkdir -p "$OUTPUT_DIRECTORY"
rm -f "$ARCHIVE_PATH"
codesign --verify --deep --strict "$APP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
printf '%s\n' "$VERSION" >"$OUTPUT_DIRECTORY/version.txt"
echo "$ARCHIVE_PATH"
