#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Gloss.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
PLUGIN_DIR="$ROOT_DIR/../personal-immersive-translator"
BROWSER_EXTENSION_DIR="$PLUGIN_DIR/.output/chrome-mv3"
SAFARI_PROJECT="$PLUGIN_DIR/safari/Gloss/Gloss.xcodeproj"
SAFARI_BUILD_DIR="$PLUGIN_DIR/safari/build"
SAFARI_EXTENSION="$SAFARI_BUILD_DIR/Build/Products/Release/Gloss Extension.appex"
SAFARI_ENTITLEMENTS="$PLUGIN_DIR/safari/Gloss/Gloss Extension/Gloss Extension.entitlements"
APP_ENTITLEMENTS="$ROOT_DIR/Resources/Gloss.entitlements"
CODEX_RUNTIME="$($ROOT_DIR/Scripts/prepare_codex_runtime.sh)"
CODEX_LICENSE="$(dirname "$CODEX_RUNTIME")/Codex-LICENSE.txt"
SIGN_IDENTITY="${GLOSS_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning \
      | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' \
      | sed -n '1p'
  )"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ ! -x "$PLUGIN_DIR/node_modules/.bin/wxt" ]]; then
  npm --prefix "$PLUGIN_DIR" ci
fi
npm --prefix "$PLUGIN_DIR" run build
xcodebuild \
  -project "$SAFARI_PROJECT" \
  -scheme Gloss \
  -configuration Release \
  -derivedDataPath "$SAFARI_BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build \
  -quiet

cd "$ROOT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
if [[ ! -f "$BROWSER_EXTENSION_DIR/manifest.json" ]]; then
  echo "Browser extension not found: $BROWSER_EXTENSION_DIR" >&2
  exit 1
fi
if [[ ! -d "$SAFARI_EXTENSION" ]]; then
  echo "Safari extension not found: $SAFARI_EXTENSION" >&2
  exit 1
fi

install -d "$MACOS_DIR" "$HELPERS_DIR" "$RESOURCES_DIR" "$PLUGINS_DIR"
install -m 755 "$BIN_DIR/Gloss" "$MACOS_DIR/Gloss"
install -m 755 "$BIN_DIR/gloss-cli" "$HELPERS_DIR/gloss-cli"
install -m 755 "$CODEX_RUNTIME" "$HELPERS_DIR/gloss-codex-app-server"
install -m 644 "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
install -m 644 "$ROOT_DIR/Resources/Gloss.icns" "$RESOURCES_DIR/Gloss.icns"
install -m 644 "$CODEX_LICENSE" "$RESOURCES_DIR/Codex-LICENSE.txt"
install -m 644 "$ROOT_DIR/CodexRuntime.lock" "$RESOURCES_DIR/CodexRuntime.lock"
/usr/bin/ditto "$BROWSER_EXTENSION_DIR" "$RESOURCES_DIR/BrowserExtension"
/usr/bin/ditto "$SAFARI_EXTENSION" "$PLUGINS_DIR/Gloss Extension.appex"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
else
  echo "Warning: Safari pairing requires an Apple Development or distribution signature." >&2
fi

codesign "${SIGN_ARGS[@]}" --entitlements "$SAFARI_ENTITLEMENTS" "$PLUGINS_DIR/Gloss Extension.appex"
codesign "${SIGN_ARGS[@]}" "$HELPERS_DIR/gloss-codex-app-server"
codesign "${SIGN_ARGS[@]}" "$HELPERS_DIR/gloss-cli"
codesign "${SIGN_ARGS[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP_DIR"
codesign --verify --strict "$HELPERS_DIR/gloss-codex-app-server"
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
