# Accessibility Statement

This page describes the accessibility goals, current support, known limitations, and barrier-reporting process for MenuBarHome.

MenuBarHome is a desktop smart-home control center for macOS (native SwiftUI and AppKit) and Windows 11 (Tauri v2). Its core goal is fast, keyboard-first and assistive-technology-friendly control of your home devices from your computer.

> **Language:** This statement is written in English to match [README.md](README.md) and [SECURITY.md](SECURITY.md). A Chinese overview of keyboard shortcuts is in [README.zh-CN.md](README.zh-CN.md), and you can report accessibility barriers in Chinese or English via our [accessibility issue form](https://github.com/jryang2026-code/MenuBarHome/issues/new?template=accessibility.yml).

## Supported environments and current capabilities

MenuBarHome implements the following accessibility support across its desktop clients:

- **Keyboard-first control:**
  - Open or close the panel globally with `⌥M` on macOS or `Alt+M` on Windows.
  - Type immediately to search by device name, room name, or pinyin initials.
  - Navigate matches with `↑` / `↓`, toggle or expand with `Return` / `Space`, adjust numeric controls with `←` / `→`, and step back with `Esc` (respecting IME composition before clearing search or dismissing). On macOS, `Tab` cycles through room tabs.
- **Screen-reader and semantic metadata:**
  - **macOS:** Core control-center cards, sliders (`accessibilityAdjustableAction`), camera/climate controls, assistant bar actions, and settings headers expose SwiftUI accessibility labels, values, hints, traits, and grouped containers.
  - **Windows:** Panel controls, filter pills, activity cards, and keyboard-selected tiles expose semantic HTML / ARIA attributes (`aria-label`, `aria-pressed`, `aria-expanded`, `aria-current`, `aria-activedescendant`), with decorative SVG icons marked `aria-hidden="true"`.
- **Reduced motion and visual adaptation:**
  - **macOS:** Panel chrome and `AppleMotion` tokens follow `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` / `effectiveReduceMotion` and `effectiveReduceTransparency`.
  - **Windows:** Panel transitions and animations respect `@media (prefers-reduced-motion: reduce)` and `window.matchMedia("(prefers-reduced-motion: reduce)")`.

## Known limitations

MenuBarHome has **not** yet completed a formal WCAG conformance audit or a full end-to-end screen-reader verification pass across VoiceOver, Narrator, and NVDA. The following gaps are currently known:

- **Screen-reader coverage gaps:** Some custom cards, expanded detail drawers, and live status updates may lack complete spoken state announcements or focus preservation during background device refreshes.
- **Reduced-motion gaps on macOS:** While main panel presentation respects reduced motion, the Settings window and some subcomponents still contain direct spring or symbol-bounce animations not yet uniformly gated by `effectiveReduceMotion`.
- **Cross-platform keyboard parity:** Some navigation behaviors (such as `Tab` room switching on macOS) and complex multi-control drawers differ between macOS and Windows.
- **Camera live feeds and event stills:** Camera previews are visual-only and do not generate automated audio or text descriptions.

## Reporting an accessibility barrier

If something blocks you from using MenuBarHome with a keyboard, screen reader, magnification, or reduced-motion/contrast setting:

1. Open an issue using the [Accessibility Barrier template](https://github.com/jryang2026-code/MenuBarHome/issues/new?template=accessibility.yml) (it applies the `accessibility` label automatically).
2. For general usage questions or discussion, you can also post in [GitHub Discussions](https://github.com/jryang2026-code/MenuBarHome/discussions).

You do **not** need to disclose a disability, and screenshots or screen recordings are **optional**. Including the details below helps us reproduce and fix the barrier faster:

- Platform (`macOS` or `Windows`) and OS / app version (visible in **Settings → About**).
- Input method or assistive technology in use (for example: keyboard-only, VoiceOver, Narrator, NVDA, Zoom, Reduce Motion).
- Which screen or action you were trying to complete, what happened, and what you expected to happen.

## Response process

- Accessibility reports are triaged under the [`accessibility`](https://github.com/jryang2026-code/MenuBarHome/labels/accessibility) label.
- Because MenuBarHome is maintained by a small open-source community, there is no fixed turnaround SLA; we aim to acknowledge reports, share workarounds when available, link tracking work on the issue, and ask the reporter to verify fixes when a new release ships.

## Expectations for contributors and coding agents

When modifying UI code or adding new views, please follow [CODING_STANDARDS.md](CODING_STANDARDS.md) and keep these baseline checks in mind:

- **macOS (`Sources/MenuBarMijiaApp/`):** Provide clear `.accessibilityLabel` (and `.accessibilityValue` / `.accessibilityAdjustableAction` for custom controls), combine or hide decorative subviews appropriately, and route new animations through `AppleMotion.resolve(..., reduceMotion: reduceMotion)`.
- **Windows (`windows/src/ui/`):** Keep keyboard routing in `windows/src/ui/panelKeyboard.ts` intact, use native `<button>` / semantic controls with accurate `aria-*` states, mark decorative icons `aria-hidden="true"`, and respect `prefers-reduced-motion: reduce`.
- **Verification:** Include a brief note in your pull request or commit summary describing how keyboard navigation or assistive metadata was checked for UI changes.

## Maintenance and feedback

This statement is maintained by [@jryang2026-code](https://github.com/jryang2026-code) and updated as accessibility coverage improves. To suggest corrections or additions, please open an issue or pull request.
