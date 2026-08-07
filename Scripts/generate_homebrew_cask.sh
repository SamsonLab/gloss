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
REPOSITORY="${6:-${GLOSS_RELEASE_REPOSITORY:-SunChJ/gloss-releases}}"
ARM64_ARCHIVE="${7:-Gloss-macos-arm64.zip}"
X86_64_ARCHIVE="${8:-Gloss-macos-x86_64.zip}"
DOWNLOAD_BASE_URL="${GLOSS_CASK_DOWNLOAD_BASE_URL:-}"
CASK_TOKEN="${GLOSS_CASK_TOKEN:-gloss}"
BUNDLES_CODEX="${GLOSS_CASK_BUNDLES_CODEX:-false}"
if [[ -z "$DOWNLOAD_BASE_URL" ]]; then
  DOWNLOAD_BASE_URL="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG"
fi

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){2}([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid cask version: $VERSION" >&2
  exit 65
fi
case "$CASK_TOKEN:$BUNDLES_CODEX" in
  gloss:false)
    CONFLICTING_CASK="gloss-with-codex"
    CASK_NAME="Gloss"
    CASK_DESCRIPTION="Context-aware text and document translation"
    ;;
  gloss-with-codex:true)
    CONFLICTING_CASK="gloss"
    CASK_NAME="Gloss with Codex"
    CASK_DESCRIPTION="Context-aware translation with a bundled Codex runtime"
    ;;
  *)
    echo "Unsupported Gloss cask variant: $CASK_TOKEN (bundles Codex: $BUNDLES_CODEX)" >&2
    exit 65
    ;;
esac
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
if [[ "$RELEASE_TAG" != "v$VERSION" ]]; then
  echo "Release tag $RELEASE_TAG does not match version $VERSION." >&2
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
cask "$CASK_TOKEN" do
  version "$VERSION"

  on_arm do
    sha256 "$ARM64_SHA256"

    url "$DOWNLOAD_BASE_URL/$ARM64_ARCHIVE"
  end
  on_intel do
    sha256 "$X86_64_SHA256"

    url "$DOWNLOAD_BASE_URL/$X86_64_ARCHIVE"
  end

  name "$CASK_NAME"
  desc "$CASK_DESCRIPTION"
  homepage "https://github.com/$REPOSITORY"

  conflicts_with cask: "$CONFLICTING_CASK"
  depends_on macos: :sonoma

  app "Gloss.app"
  binary "#{appdir}/Gloss.app/Contents/Helpers/gloss-cli", target: "gloss-cli"

  postflight do
    app_path = "#{appdir}/Gloss.app"
    entitlement_paths = [app_path]
    entitlements_before = entitlement_paths.map do |code_path|
      system_command("/usr/bin/codesign",
                     args:         ["--display", "--entitlements", "-", code_path],
                     sudo:         false,
                     must_succeed: true,
                     print_stderr: false).stdout
    end
    code_paths = [
      "#{app_path}/Contents/Helpers/gloss-codex-app-server",
      "#{app_path}/Contents/Helpers/gloss-cli",
      "#{app_path}/Contents/Helpers/gloss-update-helper",
      app_path,
    ]
    code_paths.select! { |code_path| File.exist?(code_path) }
    code_paths.each do |code_path|
      system_command "/usr/bin/codesign",
                     args:         [
                       "--force",
                       "--sign",
                       "-",
                       "--preserve-metadata=identifier,entitlements,requirements,flags,runtime",
                       code_path,
                     ],
                     sudo:         false,
                     must_succeed: true
    end
    entitlements_after = entitlement_paths.map do |code_path|
      system_command("/usr/bin/codesign",
                     args:         ["--display", "--entitlements", "-", code_path],
                     sudo:         false,
                     must_succeed: true,
                     print_stderr: false).stdout
    end
    raise "Gloss code-signing entitlements changed during installation" if entitlements_after != entitlements_before

    system_command "/usr/bin/xattr",
                   args:         ["-dr", "com.apple.quarantine", app_path],
                   sudo:         false,
                   must_succeed: true
    remaining_attributes = system_command "/usr/bin/xattr",
                                          args:         ["-lr", app_path],
                                          sudo:         false,
                                          must_succeed: true,
                                          print_stderr: false
    if remaining_attributes.stdout.include?("com.apple.quarantine")
      raise "Gloss quarantine attribute remains after installation"
    end

    system_command "/usr/bin/codesign",
                   args:         ["--verify", "--deep", "--strict", app_path],
                   sudo:         false,
                   must_succeed: true
  end

  uninstall quit: "com.samsoncj.gloss"

  zap trash: [
    "~/Library/Application Support/Gloss",
    "~/Library/Caches/Gloss",
    "~/Library/Logs/Gloss",
    "~/Library/Preferences/com.samsoncj.gloss.plist",
  ]

  caveats <<~EOS
    Gloss uses an ad-hoc code signature and is not Apple-notarized. This custom
    tap re-signs the installed app and removes its quarantine attribute.
$(if [[ "$BUNDLES_CODEX" == "true" ]]; then
    cat <<'EOF'
    This variant bundles the Codex app-server runtime. Do not install it together
    with the standard gloss cask.
EOF
  else
    cat <<'EOF'
    ChatGPT translation requires a separately installed Codex CLI with
    the app-server subcommand; Gloss does not bundle Codex.
EOF
  fi)
  EOS
end
RUBY

echo "$OUTPUT_PATH"
