**Comparison Target**

- Source visual truth: `docs/design-qa/gloss-settings-reference-dark.png`
- Implementation: `docs/design-qa/gloss-settings-dark.jpeg`
- Full-view comparison: `docs/design-qa/settings-comparison-dark.png`
- Additional product view: `docs/design-qa/gloss-main-dark.jpeg`
- Viewport: native macOS settings window, 940 × 712 points, dark appearance
- Pixels and density: source 1680 × 1360 px; implementation 940 × 712 px; the combined comparison fits each capture into an equal 930 × 760 point region while preserving aspect ratio. The source includes a larger reference window and more settings content, so density and feature-count differences were treated as intentional rather than pixel-exact drift.
- State: General / 通用 selected, Dark / 深色 selected, launch at login off

**Findings**

- No actionable P0, P1, or P2 mismatches remain.
- The implementation intentionally uses Gloss-specific navigation and a quieter first-version content density. It preserves the reference's native split-view hierarchy, blue selected sidebar row, three-card appearance selector, restrained dark surfaces, and bottom-aligned version label.

**Required Fidelity Surfaces**

- Fonts and typography: native San Francisco system typography, weights, line heights, and label hierarchy are consistent with the macOS reference. Chinese labels remain legible without truncation.
- Spacing and layout rhythm: the 220-point sidebar, page insets, card gaps, radii, and vertical rhythm preserve the reference's structure while leaving room for future settings rows.
- Colors and visual tokens: semantic AppKit colors respond to System/Light/Dark; the selected navigation row and appearance card use the current system accent color with sufficient contrast.
- Image quality and asset fidelity: Gloss uses its existing crisp brand mark and native SF Symbols. The reference's miniature window illustrations were not copied because they describe another product; native symbols are an intentional Gloss-specific substitution, not placeholders.
- Copy and content: labels describe Gloss capabilities directly. Browser translation is identified as the default capability and PDF translation as an optional component.

**Full-view Evidence**

- The side-by-side image shows the same major-region composition: fixed navigation sidebar, focused settings canvas, appearance section first, and selected state communicated with system blue.
- The implementation has no clipped controls, accidental overflow, illegible secondary text, or inconsistent alignment at the tested window size.

**Focused Region Evidence**

- A separate crop was not needed: the 3800 × 1640 combined image keeps the sidebar selection, appearance cards, selected border, labels, and launch-at-login row large enough for direct inspection.

**Comparison History**

- Earlier pass — P2: the selected sidebar row did not have a persistent blue fill, and the chosen appearance card relied only on control state. Fix: added semantic accent fill to the active sidebar item and a 2-point accent border plus accent icon/title tint to the selected appearance card.
- Post-fix evidence: `docs/design-qa/gloss-settings-dark.jpeg` and `docs/design-qa/settings-comparison-dark.png` show both selected states clearly in the same dark appearance used by the reference.

**Primary Interactions Tested**

- Open Settings from the main-window gear button.
- Open Settings with Command–Comma.
- Switch among System, Light, and Dark appearance choices and observe the app update live.
- Navigate the settings sidebar, including PDF Component.
- Verify the PDF component install/start and uninstall entry states without confirming a destructive uninstall.

**Open Questions**

- None blocking the first release.

**Implementation Checklist**

- [x] Native split-view settings window
- [x] Independent theme control and System/Light/Dark settings
- [x] Gloss-specific functional grouping
- [x] Keyboard and button settings entry points
- [x] Stable selected and disabled states

**Follow-up Polish**

- P3: richer miniature previews could be added to the three appearance cards in a later release if stronger visual demonstration becomes more valuable than the current compact native treatment.

final result: passed
