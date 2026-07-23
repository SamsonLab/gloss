#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <cask.rb>" >&2
  exit 64
fi

CASK_PATH="$1"
if [[ ! -f "$CASK_PATH" ]]; then
  echo "Cask not found: $CASK_PATH" >&2
  exit 66
fi

ruby -c "$CASK_PATH"
ruby - "$CASK_PATH" <<'RUBY'
path = ARGV.fetch(0)
content = File.read(path, encoding: "UTF-8")
required = [
  /^cask "gloss" do$/,
  /^  version "[^"]+"$/,
  /^  on_arm do$/,
  /^  on_intel do$/,
  /^    sha256 "[0-9a-f]{64}"$/,
  %r{^    url "https://[^"]+/Gloss-macos-arm64\.zip"$},
  %r{^    url "https://[^"]+/Gloss-macos-x86_64\.zip"$},
  /^  app "Gloss\.app"$/,
]
missing = required.reject { |pattern| content.match?(pattern) }
abort "Cask is missing required declarations: #{missing.join(", ")}" unless missing.empty?
RUBY
