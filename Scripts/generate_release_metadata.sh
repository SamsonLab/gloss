#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 || $# -gt 7 ]]; then
  echo "Usage: $0 <arm64-zip> <x86_64-zip> <version> <output-directory> <release-tag> [repository] [asset-base-url]" >&2
  exit 64
fi

ARM64_ARCHIVE="$1"
X86_64_ARCHIVE="$2"
VERSION="$3"
OUTPUT_DIRECTORY="$4"
RELEASE_TAG="$5"
REPOSITORY="${6:-${GITHUB_REPOSITORY:-SunChJ/gloss}}"
ASSET_BASE_URL="${7:-https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG}"

for archive in "$ARM64_ARCHIVE" "$X86_64_ARCHIVE"; do
  if [[ ! -f "$archive" ]]; then
    echo "Release archive not found: $archive" >&2
    exit 66
  fi
done
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){2}([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid release version: $VERSION" >&2
  exit 65
fi
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid GitHub repository: $REPOSITORY" >&2
  exit 65
fi
if [[ ! "$RELEASE_TAG" =~ ^v[0-9A-Za-z][0-9A-Za-z.+_-]*$ ]]; then
  echo "Invalid release tag: $RELEASE_TAG" >&2
  exit 65
fi
ASSET_URL_PATTERN='^https://[^[:space:]"\\]+$'
if [[ ! "$ASSET_BASE_URL" =~ $ASSET_URL_PATTERN ]]; then
  echo "Invalid HTTPS asset base URL: $ASSET_BASE_URL" >&2
  exit 65
fi

mkdir -p "$OUTPUT_DIRECTORY"
ARM64_NAME="$(basename "$ARM64_ARCHIVE")"
X86_64_NAME="$(basename "$X86_64_ARCHIVE")"
if [[ "$ARM64_NAME" != "Gloss-macos-arm64.zip" ]]; then
  echo "Unexpected arm64 archive name: $ARM64_NAME" >&2
  exit 65
fi
if [[ "$X86_64_NAME" != "Gloss-macos-x86_64.zip" ]]; then
  echo "Unexpected x86_64 archive name: $X86_64_NAME" >&2
  exit 65
fi

OUTPUT_DIRECTORY_ABSOLUTE="$(cd "$OUTPUT_DIRECTORY" && pwd -P)"
ARM64_SOURCE_ABSOLUTE="$(cd "$(dirname "$ARM64_ARCHIVE")" && pwd -P)/$ARM64_NAME"
X86_64_SOURCE_ABSOLUTE="$(cd "$(dirname "$X86_64_ARCHIVE")" && pwd -P)/$X86_64_NAME"
ARM64_OUTPUT="$OUTPUT_DIRECTORY_ABSOLUTE/$ARM64_NAME"
X86_64_OUTPUT="$OUTPUT_DIRECTORY_ABSOLUTE/$X86_64_NAME"
if [[ "$ARM64_SOURCE_ABSOLUTE" != "$ARM64_OUTPUT" ]]; then
  cp "$ARM64_SOURCE_ABSOLUTE" "$ARM64_OUTPUT"
fi
if [[ "$X86_64_SOURCE_ABSOLUTE" != "$X86_64_OUTPUT" ]]; then
  cp "$X86_64_SOURCE_ABSOLUTE" "$X86_64_OUTPUT"
fi

ARM64_SHA256="$(shasum -a 256 "$ARM64_OUTPUT" | awk '{print $1}')"
X86_64_SHA256="$(shasum -a 256 "$X86_64_OUTPUT" | awk '{print $1}')"
ARM64_SIZE="$(stat -f '%z' "$ARM64_OUTPUT")"
X86_64_SIZE="$(stat -f '%z' "$X86_64_OUTPUT")"
PUBLISHED_AT="$(
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    date -u -r "$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u '+%Y-%m-%dT%H:%M:%SZ'
  fi
)"
MANIFEST_PATH="$OUTPUT_DIRECTORY/gloss-release-manifest.json"
CHECKSUMS_PATH="$OUTPUT_DIRECTORY/SHA256SUMS"

ASSET_BASE_URL="${ASSET_BASE_URL%/}"
python3 - \
  "$MANIFEST_PATH" \
  "$VERSION" \
  "$RELEASE_TAG" \
  "$PUBLISHED_AT" \
  "$ASSET_BASE_URL" \
  "$ARM64_NAME" \
  "$ARM64_SHA256" \
  "$ARM64_SIZE" \
  "$X86_64_NAME" \
  "$X86_64_SHA256" \
  "$X86_64_SIZE" <<'PY'
import json
import pathlib
import sys

(
    output,
    version,
    release_tag,
    published_at,
    asset_base_url,
    arm64_name,
    arm64_sha256,
    arm64_size,
    x86_64_name,
    x86_64_sha256,
    x86_64_size,
) = sys.argv[1:]
manifest = {
    "schemaVersion": 1,
    "channel": "stable",
    "version": version,
    "releaseTag": release_tag,
    "publishedAt": published_at,
    "minimumMacOSVersion": "14.0",
    "assets": [
        {
            "operatingSystem": "macos",
            "architecture": "arm64",
            "url": f"{asset_base_url}/{arm64_name}",
            "sha256": arm64_sha256,
            "size": int(arm64_size),
        },
        {
            "operatingSystem": "macos",
            "architecture": "x86_64",
            "url": f"{asset_base_url}/{x86_64_name}",
            "sha256": x86_64_sha256,
            "size": int(x86_64_size),
        },
    ],
}
pathlib.Path(output).write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

MANIFEST_SHA256="$(shasum -a 256 "$MANIFEST_PATH" | awk '{print $1}')"
{
  printf '%s  %s\n' "$ARM64_SHA256" "$ARM64_NAME"
  printf '%s  %s\n' "$X86_64_SHA256" "$X86_64_NAME"
  printf '%s  %s\n' "$MANIFEST_SHA256" "$(basename "$MANIFEST_PATH")"
} >"$CHECKSUMS_PATH"

GLOSS_CASK_DOWNLOAD_BASE_URL="$ASSET_BASE_URL" \
  "$(dirname "$0")/generate_homebrew_cask.sh" \
  "$VERSION" \
  "$ARM64_SHA256" \
  "$X86_64_SHA256" \
  "$OUTPUT_DIRECTORY/Casks/gloss.rb" \
  "$RELEASE_TAG" \
  "$REPOSITORY" \
  "$ARM64_NAME" \
  "$X86_64_NAME"
"$(dirname "$0")/validate_homebrew_cask.sh" \
  "$OUTPUT_DIRECTORY/Casks/gloss.rb"

echo "$MANIFEST_PATH"
echo "$CHECKSUMS_PATH"
