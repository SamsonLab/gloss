#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 8 ]]; then
  echo "Usage: $0 <version> <arm64-sha256> <x86_64-sha256> <output> [release-tag] [repository] [arm64-archive] [x86_64-archive]" >&2
  exit 64
fi

VERSION="$1"
ARM64_SHA256="$2"
X86_64_SHA256="$3"
OUTPUT_PATH="$4"
RELEASE_TAG="${5:-v$VERSION}"
REPOSITORY="${6:-${GITHUB_REPOSITORY:-SunChJ/gloss}}"
ARM64_ARCHIVE="${7:-Gloss-macos-arm64.zip}"
X86_64_ARCHIVE="${8:-Gloss-macos-x86_64.zip}"
DOWNLOAD_BASE_URL="${GLOSS_CASK_DOWNLOAD_BASE_URL:-}"
if [[ -z "$DOWNLOAD_BASE_URL" ]]; then
  DOWNLOAD_BASE_URL="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG"
fi

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){2}([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid cask version: $VERSION" >&2
  exit 65
fi
for checksum in "$ARM64_SHA256" "$X86_64_SHA256"; do
  if [[ ! "$checksum" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "Invalid cask SHA-256: $checksum" >&2
    exit 65
  fi
done
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid GitHub repository: $REPOSITORY" >&2
  exit 65
fi
if [[ ! "$RELEASE_TAG" =~ ^v[0-9A-Za-z][0-9A-Za-z.+_-]*$ ]]; then
  echo "Invalid release tag: $RELEASE_TAG" >&2
  exit 65
fi
for archive in "$ARM64_ARCHIVE" "$X86_64_ARCHIVE"; do
  if [[ "$archive" == *"/"* || -z "$archive" ]]; then
    echo "Invalid archive name: $archive" >&2
    exit 65
  fi
done
DOWNLOAD_URL_PATTERN='^https://[^[:space:]"\\]+$'
if [[ ! "$DOWNLOAD_BASE_URL" =~ $DOWNLOAD_URL_PATTERN ]]; then
  echo "Invalid HTTPS download base URL: $DOWNLOAD_BASE_URL" >&2
  exit 65
fi

ARM64_SHA256="$(printf '%s' "$ARM64_SHA256" | tr '[:upper:]' '[:lower:]')"
X86_64_SHA256="$(printf '%s' "$X86_64_SHA256" | tr '[:upper:]' '[:lower:]')"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL%/}"
mkdir -p "$(dirname "$OUTPUT_PATH")"
cat >"$OUTPUT_PATH" <<RUBY
cask "gloss" do
  version "$VERSION"

  on_arm do
    sha256 "$ARM64_SHA256"
    url "$DOWNLOAD_BASE_URL/$ARM64_ARCHIVE"
  end

  on_intel do
    sha256 "$X86_64_SHA256"
    url "$DOWNLOAD_BASE_URL/$X86_64_ARCHIVE"
  end

  name "Gloss"
  desc "Native, context-aware translation for macOS"
  homepage "https://github.com/$REPOSITORY"

  depends_on macos: ">= :sonoma"

  app "Gloss.app"

  uninstall quit: "com.samsoncj.gloss"

  zap trash: [
    "~/Library/Application Support/Gloss",
    "~/Library/Caches/Gloss",
    "~/Library/Logs/Gloss",
    "~/Library/Preferences/com.samsoncj.gloss.plist",
  ]
end
RUBY

echo "$OUTPUT_PATH"
