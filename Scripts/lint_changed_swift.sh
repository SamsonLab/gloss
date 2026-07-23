#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [base-revision]" >&2
  exit 64
fi

if [[ $# -eq 1 ]]; then
  BASE_REVISION="$1"
elif git rev-parse --verify HEAD^ >/dev/null 2>&1; then
  BASE_REVISION="HEAD^"
else
  BASE_REVISION=""
fi

SWIFT_FILES=()
if [[ -n "$BASE_REVISION" ]]; then
  while IFS= read -r path; do
    [[ -n "$path" && -f "$path" ]] && SWIFT_FILES+=("$path")
  done < <(
    git diff \
      --name-only \
      --diff-filter=ACMR \
      "$BASE_REVISION...HEAD" \
      -- '*.swift'
  )
  if ! git diff --quiet "$BASE_REVISION...HEAD" -- Package.swift; then
    SWIFT_FILES+=("Package.swift")
  fi
else
  while IFS= read -r path; do
    SWIFT_FILES+=("$path")
  done < <(git ls-files '*.swift')
  SWIFT_FILES+=("Package.swift")
fi

if [[ ${#SWIFT_FILES[@]} -eq 0 ]]; then
  echo "No changed Swift files to lint."
  exit 0
fi

printf 'Linting %s\n' "${SWIFT_FILES[@]}"
swift format lint --strict "${SWIFT_FILES[@]}"
