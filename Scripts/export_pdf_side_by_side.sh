#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec /usr/bin/env swift \
  "$SCRIPT_DIRECTORY/pdf_dual_export.swift" \
  side-by-side \
  "$@"
