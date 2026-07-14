#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/CodexRuntime.lock"

case "${GLOSS_CODEX_RUNTIME_ARCH:-$(uname -m)}" in
  arm64|aarch64)
    TARGET="aarch64-apple-darwin"
    ARCHIVE_SHA256="$CODEX_RUNTIME_AARCH64_SHA256"
    ;;
  x86_64|amd64)
    TARGET="x86_64-apple-darwin"
    ARCHIVE_SHA256="$CODEX_RUNTIME_X86_64_SHA256"
    ;;
  *)
    echo "Unsupported Codex runtime architecture: ${GLOSS_CODEX_RUNTIME_ARCH:-$(uname -m)}" >&2
    exit 1
    ;;
esac

CACHE_ROOT="${GLOSS_CODEX_RUNTIME_CACHE:-$HOME/Library/Caches/GlossBuild/codex-app-server}"
CACHE_DIR="$CACHE_ROOT/$CODEX_RUNTIME_VERSION/$TARGET/$ARCHIVE_SHA256"
RUNTIME_PATH="$CACHE_DIR/codex-app-server"
ARCHIVE_PATH="$CACHE_DIR/codex-app-server.tar.gz"
LICENSE_PATH="$CACHE_DIR/Codex-LICENSE.txt"
ARCHIVE_URL="https://github.com/openai/codex/releases/download/$CODEX_RUNTIME_TAG/codex-app-server-$TARGET.tar.gz"
LICENSE_URL="https://raw.githubusercontent.com/openai/codex/$CODEX_RUNTIME_TAG/LICENSE"

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

verify_official_signature() {
  local file="$1"
  local team_id
  codesign --verify --strict "$file" >/dev/null 2>&1
  team_id="$(codesign -dvv "$file" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$team_id" == "$CODEX_RUNTIME_TEAM_ID" ]]
}

verify_runtime() {
  local file="$1"
  verify_official_signature "$file" \
    && [[ "$("$file" --version)" == "codex-app-server $CODEX_RUNTIME_VERSION" ]]
}

mkdir -p "$CACHE_DIR"
if [[ ! -f "$ARCHIVE_PATH" ]] || ! verify_sha256 "$ARCHIVE_PATH" "$ARCHIVE_SHA256"; then
  partial="$ARCHIVE_PATH.partial"
  rm -f "$partial"
  curl --fail --location --retry 3 --output "$partial" "$ARCHIVE_URL"
  if ! verify_sha256 "$partial" "$ARCHIVE_SHA256"; then
    rm -f "$partial"
    echo "Codex runtime checksum verification failed." >&2
    exit 1
  fi
  mv "$partial" "$ARCHIVE_PATH"
fi

if [[ ! -f "$LICENSE_PATH" ]] || ! verify_sha256 "$LICENSE_PATH" "$CODEX_RUNTIME_LICENSE_SHA256"; then
  partial="$LICENSE_PATH.partial"
  rm -f "$partial"
  curl --fail --location --retry 3 --output "$partial" "$LICENSE_URL"
  if ! verify_sha256 "$partial" "$CODEX_RUNTIME_LICENSE_SHA256"; then
    rm -f "$partial"
    echo "Codex license checksum verification failed." >&2
    exit 1
  fi
  mv "$partial" "$LICENSE_PATH"
fi

if [[ ! -x "$RUNTIME_PATH" ]] || ! verify_runtime "$RUNTIME_PATH"; then
  extract_dir="$(mktemp -d "$CACHE_DIR/extract.XXXXXX")"
  trap 'rm -rf "$extract_dir"' EXIT
  expected_name="codex-app-server-$TARGET"
  archive_entries="$(tar -tzf "$ARCHIVE_PATH" | sed '/\/$/d')"
  if [[ "$archive_entries" != "$expected_name" ]]; then
    echo "Codex runtime archive has an unexpected layout." >&2
    exit 1
  fi
  tar -xzf "$ARCHIVE_PATH" -C "$extract_dir"
  candidate="$extract_dir/$archive_entries"
  if ! verify_runtime "$candidate"; then
    echo "Codex runtime signature or version verification failed." >&2
    exit 1
  fi
  install -m 755 "$candidate" "$RUNTIME_PATH"
fi

echo "$RUNTIME_PATH"
