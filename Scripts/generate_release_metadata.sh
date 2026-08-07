#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 7 || $# -gt 9 ]]; then
  echo "Usage: $0 <arm64-zip> <x86_64-zip> <arm64-with-codex-zip> <x86_64-with-codex-zip> <version> <output-directory> <release-tag> [repository] [asset-base-url]" >&2
  exit 64
fi

ARM64_ARCHIVE="$1"
X86_64_ARCHIVE="$2"
ARM64_CODEX_ARCHIVE="$3"
X86_64_CODEX_ARCHIVE="$4"
VERSION="$5"
OUTPUT_DIRECTORY="$6"
RELEASE_TAG="$7"
REPOSITORY="${8:-${GLOSS_RELEASE_REPOSITORY:-SunChJ/gloss-releases}}"
ASSET_BASE_URL="${9:-https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG}"

ARCHIVES=(
  "$ARM64_ARCHIVE"
  "$X86_64_ARCHIVE"
  "$ARM64_CODEX_ARCHIVE"
  "$X86_64_CODEX_ARCHIVE"
)
EXPECTED_NAMES=(
  "Gloss-macos-arm64.zip"
  "Gloss-macos-x86_64.zip"
  "Gloss-macos-arm64-with-codex.zip"
  "Gloss-macos-x86_64-with-codex.zip"
)
for index in "${!ARCHIVES[@]}"; do
  archive="${ARCHIVES[$index]}"
  if [[ ! -f "$archive" ]]; then
    echo "Release archive not found: $archive" >&2
    exit 66
  fi
  if [[ "$(basename "$archive")" != "${EXPECTED_NAMES[$index]}" ]]; then
    echo "Unexpected release archive name: $(basename "$archive")" >&2
    exit 65
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
if [[ "$RELEASE_TAG" != "v$VERSION" ]]; then
  echo "Release tag $RELEASE_TAG does not match version $VERSION." >&2
  exit 65
fi
ASSET_URL_PATTERN='^https://[^[:space:]"\\]+$'
if [[ ! "$ASSET_BASE_URL" =~ $ASSET_URL_PATTERN ]]; then
  echo "Invalid HTTPS asset base URL: $ASSET_BASE_URL" >&2
  exit 65
fi

mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY_ABSOLUTE="$(cd "$OUTPUT_DIRECTORY" && pwd -P)"
for index in "${!ARCHIVES[@]}"; do
  archive="${ARCHIVES[$index]}"
  name="${EXPECTED_NAMES[$index]}"
  source_absolute="$(cd "$(dirname "$archive")" && pwd -P)/$name"
  output="$OUTPUT_DIRECTORY_ABSOLUTE/$name"
  if [[ "$source_absolute" != "$output" ]]; then
    cp "$source_absolute" "$output"
  fi
done

ARM64_NAME="${EXPECTED_NAMES[0]}"
X86_64_NAME="${EXPECTED_NAMES[1]}"
ARM64_CODEX_NAME="${EXPECTED_NAMES[2]}"
X86_64_CODEX_NAME="${EXPECTED_NAMES[3]}"
ARM64_OUTPUT="$OUTPUT_DIRECTORY_ABSOLUTE/$ARM64_NAME"
X86_64_OUTPUT="$OUTPUT_DIRECTORY_ABSOLUTE/$X86_64_NAME"
ARM64_CODEX_OUTPUT="$OUTPUT_DIRECTORY_ABSOLUTE/$ARM64_CODEX_NAME"
X86_64_CODEX_OUTPUT="$OUTPUT_DIRECTORY_ABSOLUTE/$X86_64_CODEX_NAME"
ARM64_SHA256="$(shasum -a 256 "$ARM64_OUTPUT" | awk '{print $1}')"
X86_64_SHA256="$(shasum -a 256 "$X86_64_OUTPUT" | awk '{print $1}')"
ARM64_CODEX_SHA256="$(shasum -a 256 "$ARM64_CODEX_OUTPUT" | awk '{print $1}')"
X86_64_CODEX_SHA256="$(shasum -a 256 "$X86_64_CODEX_OUTPUT" | awk '{print $1}')"
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

GLOSS_CASK_DOWNLOAD_BASE_URL="$ASSET_BASE_URL" \
GLOSS_CASK_TOKEN="gloss" \
GLOSS_CASK_BUNDLES_CODEX="false" \
  bash "$(dirname "$0")/generate_homebrew_cask.sh" \
  "$VERSION" "$ARM64_SHA256" "$X86_64_SHA256" \
  "$OUTPUT_DIRECTORY/gloss.rb" "$RELEASE_TAG" "$REPOSITORY" \
  "$ARM64_NAME" "$X86_64_NAME"
bash "$(dirname "$0")/validate_homebrew_cask.sh" \
  "$OUTPUT_DIRECTORY/gloss.rb" standard

GLOSS_CASK_DOWNLOAD_BASE_URL="$ASSET_BASE_URL" \
GLOSS_CASK_TOKEN="gloss-with-codex" \
GLOSS_CASK_BUNDLES_CODEX="true" \
  bash "$(dirname "$0")/generate_homebrew_cask.sh" \
  "$VERSION" "$ARM64_CODEX_SHA256" "$X86_64_CODEX_SHA256" \
  "$OUTPUT_DIRECTORY/gloss-with-codex.rb" "$RELEASE_TAG" "$REPOSITORY" \
  "$ARM64_CODEX_NAME" "$X86_64_CODEX_NAME"
bash "$(dirname "$0")/validate_homebrew_cask.sh" \
  "$OUTPUT_DIRECTORY/gloss-with-codex.rb" with-codex

CASK_PATH="$OUTPUT_DIRECTORY/gloss.rb"
CASK_SHA256="$(shasum -a 256 "$CASK_PATH" | awk '{print $1}')"
CASK_SIZE="$(stat -f '%z' "$CASK_PATH")"
CASK_URL="$ASSET_BASE_URL/gloss.rb"
CODEX_CASK_PATH="$OUTPUT_DIRECTORY/gloss-with-codex.rb"
CODEX_CASK_SHA256="$(shasum -a 256 "$CODEX_CASK_PATH" | awk '{print $1}')"

python3 - \
  "$MANIFEST_PATH" "$VERSION" "$RELEASE_TAG" "$PUBLISHED_AT" "$ASSET_BASE_URL" \
  "$ARM64_NAME" "$ARM64_SHA256" "$ARM64_SIZE" \
  "$X86_64_NAME" "$X86_64_SHA256" "$X86_64_SIZE" \
  "$CASK_URL" "$CASK_SHA256" "$CASK_SIZE" <<'PY'
import json
import pathlib
import sys

(
    output, version, release_tag, published_at, asset_base_url,
    arm64_name, arm64_sha256, arm64_size,
    x86_64_name, x86_64_sha256, x86_64_size,
    cask_url, cask_sha256, cask_size,
) = sys.argv[1:]
manifest = {
    "schemaVersion": 2,
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
    "homebrewCask": {
        "token": "sunchj/tap/gloss",
        "url": cask_url,
        "sha256": cask_sha256,
        "size": int(cask_size),
    },
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
  printf '%s  %s\n' "$ARM64_CODEX_SHA256" "$ARM64_CODEX_NAME"
  printf '%s  %s\n' "$X86_64_CODEX_SHA256" "$X86_64_CODEX_NAME"
  printf '%s  %s\n' "$CASK_SHA256" "gloss.rb"
  printf '%s  %s\n' "$CODEX_CASK_SHA256" "gloss-with-codex.rb"
  printf '%s  %s\n' "$MANIFEST_SHA256" "$(basename "$MANIFEST_PATH")"
} >"$CHECKSUMS_PATH"

echo "$MANIFEST_PATH"
echo "$CHECKSUMS_PATH"
