<div align="center">
  <img src="Resources/GlossIcon.png" width="144" alt="Gloss icon">
  <h1>Gloss</h1>
  <p><strong>Native macOS translation for the browser and layout-preserving PDFs.</strong></p>
  <p>
    <a href="README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a>
  </p>
  <p>
    <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white">
    <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
    <a href="LICENSE"><img alt="PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-2563EB"></a>
  </p>
</div>

Gloss is a native macOS translation app built around complete workflows rather
than a collection of disconnected utilities. The current release focuses on
two scenarios: translating browser content and translating PDFs while
preserving their layout.

The app and `gloss-cli` share the same capability registry, translation
providers, cache, and scheduling layer. You can use an installed, ChatGPT-connected
Codex CLI or keep translation on-device with `llama.cpp`.

## Highlights

| Workflow | What Gloss provides |
| --- | --- |
| Browser translation | A local, authenticated bridge and a bundled Chrome extension. Apple-signed builds can also include Safari. |
| PDF translation | An approximately 230 MB signed BabelDOC runtime installed on demand, with layout preservation, batch queues, rollback, and safe uninstall. |
| Translation providers | ChatGPT sign-in through an installed Codex CLI, or a local `llama.cpp` server with Hy-MT2. |
| Automation | `gloss-cli` commands for capabilities, browser text, PDFs, plain text, and diagnostics. |

Gloss is written in Swift, uses Apple Vision for local OCR, and keeps its
browser bridge on `127.0.0.1` behind a per-device token.

## Install

Gloss requires **macOS 14 or newer**.

```bash
brew install --cask sunchj/tap/gloss
```

Gloss checks the signed release channel after launch, at most once every 24
hours. When an update is available it presents an actionable reminder; official
Homebrew installations can update and restart directly from that prompt. You
can also update manually with:

```bash
brew update
brew upgrade --cask sunchj/tap/gloss
```

The Homebrew build is ad-hoc signed rather than Apple-notarized. Its cask
re-signs the app locally, removes quarantine, and verifies the installed
bundle. Public binaries and signed update metadata are published in
[`SunChJ/gloss-releases`](https://github.com/SunChJ/gloss-releases/releases/latest).

## Quick start

1. Open Gloss. The main panel starts with browser translation status and extension actions.
2. Use the top-right settings button or `⌘,` to select a translation provider and the `System / Light / Dark` appearance.
3. For GPT translation, select **Sign in with ChatGPT**. No separate API key is
   required by Gloss.
4. For local translation, install `llama.cpp` with
   `brew install llama.cpp`, then choose **Local Model**. The first run downloads
   an approximately 1.1 GB quantized model.
5. For Chrome, choose **Show Extension** from the main panel or Gloss settings and load the shown
   directory from `chrome://extensions` in Developer mode.
6. Install the PDF component on first use, then select or drop one or more files and choose an output
   directory.

Safari support is available only in an Apple-signed build that includes the
Safari App Extension and matching App Group entitlement. It is intentionally
absent from the Homebrew build.

## Command line

The Homebrew cask links `gloss-cli` into its `bin` directory:

```bash
# Inspect the capabilities included in this build
gloss-cli capabilities --json

# Translate browser content extracted by another tool
gloss-cli browser --target 'Chinese (Simplified)' 'Translate this webpage.'

# Translate one or more PDFs
gloss-cli pdf paper-a.pdf paper-b.pdf \
  --output ./translated \
  --target 'Chinese (Simplified)' \
  --mode bilingual

# Derive reusable reading copies from a bilingual master without translating again
./Scripts/export_pdf_side_by_side.sh translated/paper-a-gloss-dual.pdf
./Scripts/export_pdf_translation_only.sh translated/paper-a-gloss-dual.pdf

# Translate plain text locally
gloss-cli text --provider llama \
  --target 'Chinese (Simplified)' \
  'Translate locally.'
```

`browser` accepts text from arguments or stdin; it does not automate browser
UI. `pdf` reports progress on stderr and writes the final artifact paths as
JSON on stdout, which makes it suitable for scripts.

The bilingual PDF is the reusable master: source and translated pages alternate.
The two export scripts create a permanent left/right spread or a translation-only
PDF without another translation pass. They derive output names beside the input;
pass an explicit output path as the second argument, or `--force` to replace an
existing derivative.

## Privacy and security

- Local-model translation keeps source text and translations on the device.
- OCR is performed locally with Apple Vision before recognized text is sent to
  the selected translation provider.
- The browser bridge listens only on localhost and requires a random
  per-device token.
- Runtime logs do not record source text or translations and are stored with
  `0600` permissions in `~/Library/Logs/Gloss/`.
- BabelDOC packages and app-update manifests are signature-verified before
  installation; release artifacts are also checksum-pinned.

## Development

You need macOS 14+, Xcode Command Line Tools, and Swift 6.

```bash
swift test --parallel
swift run Gloss
swift run gloss-cli capabilities --json
```

Build a distributable app with:

```bash
./Scripts/build_app.sh
open dist/Gloss.app
```

The packaging script expects the companion browser-extension source in a
sibling checkout and deliberately does not bundle Codex. Install Codex first,
or set `GLOSS_CODEX_BIN`; `./Scripts/build_app_without_bundled_codex.sh` is the
explicit equivalent of the default lightweight build. If the extension is not
a sibling checkout, set `GLOSS_BROWSER_EXTENSION_SOURCE` to its directory.

## Repository layout

| Path | Responsibility |
| --- | --- |
| `Sources/GlossCore/` | Providers, translation models, caching, dispatch, BabelDOC, updates, and the local bridge |
| `Sources/GlossOCR/` | Apple Vision OCR and reading-order recovery |
| `Sources/Gloss/` | macOS app, settings, panels, PDF workflow, and browser integration |
| `Sources/GlossCLI/` | Browser, PDF, and text commands |
| `Sources/GlossUpdateHelper/` | Verified Homebrew update handoff |

For distribution internals and trust boundaries, see
[`docs/runtime-distribution.md`](docs/runtime-distribution.md). Release-specific
changes are recorded in [`docs/release-notes/`](docs/release-notes/).

## License

Gloss is **source-available** under the
[PolyForm Noncommercial License 1.0.0](LICENSE).

You may use, study, modify, and distribute Gloss only for purposes permitted by
that license. **Commercial use is not permitted without a separate written
license from SamsonLab.** This is not an OSI-approved open-source license.

Third-party components and runtime dependencies remain under their respective
licenses.
