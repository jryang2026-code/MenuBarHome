/**
 * Semantic icon id → the symbol name the Windows card and UI already resolve into their own SVG
 * glyphs (`deviceViews.ts` `SF_ICONS`). `Shared/deviceLabels.json` stores only the neutral id; this
 * table is Windows' own mapping, mirroring `DeviceIconSymbols` on macOS.
 *
 * The values deliberately stay in the existing vocabulary: `applianceOrGenericIcon` and the
 * assistant category checks match substrings such as `water.waves`, so a card keeps its glyph.
 * `scripts/check_device_rules.py` proves both ends map exactly the ids the shared file uses.
 */
export const DEVICE_ICON_SYMBOLS: Readonly<Record<string, string>> = {
  bed: "bed.double.fill",
  bike: "bicycle",
  "car-seat": "car.fill",
  clock: "clock.fill",
  coffee: "cup.and.saucer.fill",
  drop: "drop.fill",
  fish: "fish.fill",
  generic: "square.grid.2x2",
  location: "location.fill",
  lock: "lock.fill",
  mirror: "rectangle.portrait.fill",
  pawprint: "pawprint.fill",
  projector: "projector.fill",
  scale: "scalemass.fill",
  seat: "chair.lounge.fill",
  toothbrush: "mouth.fill",
  treadmill: "figure.run",
  tv: "tv",
  watch: "applewatch",
  water: "water.waves",
  wifi: "wifi",
};

/** Fallback for an icon id a future document adds before this table does. */
export const DEFAULT_DEVICE_ICON_SYMBOL = "square.grid.2x2";
