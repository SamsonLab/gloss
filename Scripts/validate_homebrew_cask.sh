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
  /^  postflight do$/,
  %r{^    system_command "/usr/bin/codesign",$},
  %r{^      system_command "/usr/bin/codesign",$},
  %r{#\{app_path\}/Contents/PlugIns/Gloss Extension\.appex},
  %r{#\{app_path\}/Contents/Helpers/gloss-codex-app-server},
  %r{#\{app_path\}/Contents/Helpers/gloss-cli},
  /^    code_paths\.each do \|code_path\|$/,
  /entitlements_before = entitlement_paths\.map/,
  /entitlements_after = entitlement_paths\.map/,
  /Gloss code-signing entitlements changed during installation/,
  /"--preserve-metadata=identifier,entitlements,requirements,flags,runtime"/,
  %r{^    system_command "/usr/bin/xattr",$},
  /\["-dr", "com\.apple\.quarantine", app_path\]/,
  /\["-lr", app_path\]/,
  /Gloss quarantine attribute remains after installation/,
  /\["--verify", "--deep", "--strict", app_path\]/,
  /^\s+must_succeed: true$/,
  /^  caveats <<~EOS$/,
]
missing = required.reject { |pattern| content.match?(pattern) }
abort "Cask is missing required declarations: #{missing.join(", ")}" unless missing.empty?

code_paths = content.match(%r{^    code_paths = \[$(.*?)^    \]$}m)&.[](1)
abort "Cask explicit signing paths are missing" unless code_paths
expected_order = [
  "extension_path,",
  '"#{app_path}/Contents/Helpers/gloss-codex-app-server",',
  '"#{app_path}/Contents/Helpers/gloss-cli",',
  "app_path,",
]
cursor = -1
expected_order.each do |entry|
  position = code_paths.index(entry)
  abort "Cask signing order is invalid: #{entry}" unless position && position > cursor

  cursor = position
end

signing_section = content.match(
  %r{^    code_paths\.each do \|code_path\|$(.*?)^    entitlements_after =}m,
)&.[](1)
abort "Cask signing section is missing" unless signing_section
abort "Cask must sign nested code explicitly, without --deep" if signing_section.include?('"--deep"')
RUBY
