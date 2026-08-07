#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <cask.rb> [standard|with-codex]" >&2
  exit 64
fi

CASK_PATH="$1"
VARIANT="${2:-standard}"
if [[ ! -f "$CASK_PATH" ]]; then
  echo "Cask not found: $CASK_PATH" >&2
  exit 66
fi
case "$VARIANT" in
  standard)
    CASK_TOKEN="gloss"
    CONFLICTING_CASK="gloss-with-codex"
    ARCHIVE_SUFFIX=""
    ;;
  with-codex)
    CASK_TOKEN="gloss-with-codex"
    CONFLICTING_CASK="gloss"
    ARCHIVE_SUFFIX="-with-codex"
    ;;
  *)
    echo "Unsupported cask variant: $VARIANT" >&2
    exit 65
    ;;
esac

ruby -c "$CASK_PATH"
ruby - "$CASK_PATH" "$CASK_TOKEN" "$CONFLICTING_CASK" "$ARCHIVE_SUFFIX" "$VARIANT" <<'RUBY'
path, cask_token, conflicting_cask, archive_suffix, variant = ARGV
content = File.read(path, encoding: "UTF-8")
required = [
  /^cask "#{Regexp.escape(cask_token)}" do$/,
  /^  version "[^"]+"$/,
  /^  on_arm do$/,
  /^  on_intel do$/,
  /^    sha256 "[0-9a-f]{64}"$/,
  %r{^    url "https://[^"]+/Gloss-macos-arm64#{Regexp.escape(archive_suffix)}\.zip"$},
  %r{^    url "https://[^"]+/Gloss-macos-x86_64#{Regexp.escape(archive_suffix)}\.zip"$},
  /^  conflicts_with cask: "#{Regexp.escape(conflicting_cask)}"$/,
  /^  app "Gloss\.app"$/,
  %r{^  binary "#\{appdir\}/Gloss\.app/Contents/Helpers/gloss-cli", target: "gloss-cli"$},
  /^  postflight do$/,
  %r{^    system_command "/usr/bin/codesign",$},
  %r{^      system_command "/usr/bin/codesign",$},
  %r{#\{app_path\}/Contents/Helpers/gloss-codex-app-server},
  %r{#\{app_path\}/Contents/Helpers/gloss-cli},
  %r{#\{app_path\}/Contents/Helpers/gloss-update-helper},
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
required << if variant == "with-codex"
  /This variant bundles the Codex app-server runtime/
else
  /Gloss does not bundle Codex/
end
missing = required.reject { |pattern| content.match?(pattern) }
abort "Cask is missing required declarations: #{missing.join(", ")}" unless missing.empty?
if content.include?("Gloss Extension.appex")
  abort "Ad-hoc Homebrew cask must not contain a Safari App Extension"
end

code_paths = content.match(%r{^    code_paths = \[$(.*?)^    \]$}m)&.[](1)
abort "Cask explicit signing paths are missing" unless code_paths
expected_order = [
  '"#{app_path}/Contents/Helpers/gloss-codex-app-server",',
  '"#{app_path}/Contents/Helpers/gloss-cli",',
  '"#{app_path}/Contents/Helpers/gloss-update-helper",',
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
