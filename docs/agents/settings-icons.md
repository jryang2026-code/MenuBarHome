# Settings icons

The settings window uses native SwiftUI paths in `SettingsIconTiles.swift` for its six coloured category badges. They scale between the sidebar and pane header without image decoding or an additional runtime.

## kubai-icons evaluation

Upstream: https://github.com/kubai087/kubai-icons

The upstream `LICENSING.md` places `icons/`, `badges/`, and **all of `packages/`** under MIT. This includes the core package and the `kubai-icons-static` package with static SVGs. These may be reused, modified, and distributed with the copyright and permission notice. Using upstream icons does not inherently require the separately licensed skill engine.

The skill (`SKILL.md`, `PROMPT.md`, `src/engine.js` and related skill files) has separate source-available terms. Website and documentation content also have separate terms. Do not conflate those with the MIT artwork and packages.

## Current choice

This change ships independently authored native category glyphs, with no copied upstream artwork or code. The native paths suit the small settings badges and avoid a JavaScript runtime for hover effects. Static upstream SVGs remain a viable future option, provided the MIT notice accompanies any copied assets.

Device icons retain the existing `DeviceIconOrb` state-driven bounce, family colour, and Reduce Motion behaviour. No continuous animation was added: device state should remain readable while the menu-bar panel is idle.
