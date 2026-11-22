import { nextSize, type TileSize } from "./panelPrefs.js";

export const PANEL_THEMES = ["classic", "fluent"] as const;
export type PanelTheme = (typeof PANEL_THEMES)[number];
export const DEFAULT_PANEL_THEME: PanelTheme = "classic";

export type PanelShellLayout = "dualIsland" | "unifiedPopover";
export type DrawerPresentation = "subpage" | "inlineAccordion";
export type TileChromeStyle = "fluentSplitPill" | "classicBento";
export type SliderChromeStyle = "fluentRange" | "liquidGlassPill";
export type TabIndicatorStyle = "underlinePill" | "glassCapsule";
export type MotionFamily = "fluent" | "appleSpring";

export interface PanelThemeProfile {
  readonly id: PanelTheme;
  readonly mainWidthPx: 380 | 440;
  readonly panelInsetPx: 16;
  readonly windowWidthPx: 412 | 472;
  readonly flyoutRadiusPx: 12 | 22;
  readonly shellLayout: PanelShellLayout;
  readonly drawerPresentation: DrawerPresentation;
  readonly tileChrome: TileChromeStyle;
  readonly sliderChrome: SliderChromeStyle;
  readonly tabIndicator: TabIndicatorStyle;
  readonly motionFamily: MotionFamily;
  readonly showsBottomSliderDeck: boolean;
}

export const PANEL_THEME_PROFILES: Readonly<Record<PanelTheme, PanelThemeProfile>> = {
  fluent: {
    id: "fluent",
    mainWidthPx: 380,
    panelInsetPx: 16,
    windowWidthPx: 412,
    flyoutRadiusPx: 12,
    shellLayout: "dualIsland",
    drawerPresentation: "subpage",
    tileChrome: "fluentSplitPill",
    sliderChrome: "fluentRange",
    tabIndicator: "underlinePill",
    motionFamily: "fluent",
    showsBottomSliderDeck: true,
  },
  classic: {
    id: "classic",
    mainWidthPx: 440,
    panelInsetPx: 16,
    windowWidthPx: 472,
    flyoutRadiusPx: 22,
    shellLayout: "unifiedPopover",
    drawerPresentation: "inlineAccordion",
    tileChrome: "classicBento",
    sliderChrome: "liquidGlassPill",
    tabIndicator: "glassCapsule",
    motionFamily: "appleSpring",
    showsBottomSliderDeck: false,
  },
};

export function normalizePanelTheme(raw: unknown): PanelTheme {
  return raw === "fluent" ? "fluent" : "classic";
}

export function getPanelThemeProfile(theme: PanelTheme): PanelThemeProfile {
  return PANEL_THEME_PROFILES[normalizePanelTheme(theme)];
}

export type TileRenderMode =
  | "smallOrb"
  | "fluentCapsule"
  | "fluentSubpage"
  | "bentoCard"
  | "bentoHero"
  | "bentoFull";

export interface ResolvedTilePresentation {
  readonly mode: TileRenderMode;
  readonly cssColumnSpan: 3 | 6 | 12;
  readonly cssRowSpan: 1 | 2;
  readonly mountsSubpage: boolean;
  readonly spansFullRow: boolean;
}

export function resolveTilePresentation(input: {
  readonly theme: PanelTheme;
  readonly size: Exclude<TileSize, "auto">;
  readonly isExpanded: boolean;
  readonly hasDrawer: boolean;
  readonly isCompactGridMode?: boolean;
}): ResolvedTilePresentation {
  const isCompactGridMode = input.isCompactGridMode ?? true;
  if (!input.isExpanded && input.size === "small") {
    return { mode: "smallOrb", cssColumnSpan: 3, cssRowSpan: 1, mountsSubpage: false, spansFullRow: false };
  }
  if (input.theme === "fluent") {
    if (input.isExpanded && input.size !== "panel" && input.hasDrawer) {
      return { mode: "fluentSubpage", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: true, spansFullRow: true };
    }
    if (!input.isExpanded && isCompactGridMode && input.size === "half") {
      return { mode: "fluentCapsule", cssColumnSpan: 6, cssRowSpan: 1, mountsSubpage: false, spansFullRow: false };
    }
    return { mode: "bentoFull", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: false, spansFullRow: true };
  }
  if (input.isExpanded || !isCompactGridMode || input.size === "full" || input.size === "panel") {
    return { mode: "bentoFull", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: false, spansFullRow: true };
  }
  if (input.size === "hero") {
    return { mode: "bentoHero", cssColumnSpan: 6, cssRowSpan: 2, mountsSubpage: false, spansFullRow: false };
  }
  return { mode: "bentoCard", cssColumnSpan: 6, cssRowSpan: 1, mountsSubpage: false, spansFullRow: false };
}

export function nextSizeForTheme(
  current: Exclude<TileSize, "auto">,
  theme: PanelTheme,
): Exclude<TileSize, "auto"> {
  if (theme === "classic") {
    switch (current) {
      case "small": return "half";
      case "half": return "hero";
      case "hero": return "full";
      case "full": return "panel";
      case "panel": return "small";
    }
  }
  return nextSize(current);
}
