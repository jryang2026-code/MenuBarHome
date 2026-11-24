import type { PanelTheme } from "./panelTheme.js";

export interface WinAccentPalette {
  readonly accent: string;
  readonly accentHover: string;
  readonly accentPressed: string;
  readonly textOnAccent: string;
}

export interface WinThemeSnapshot {
  readonly windowsBuild: number;
  readonly supportsSystemBackdrop: boolean;
  readonly appsUseLightTheme: boolean;
  readonly systemUsesLightTheme: boolean;
  readonly enableTransparency: boolean;
  readonly accentDark: WinAccentPalette | null;
  readonly accentLight: WinAccentPalette | null;
}

const ACCENT_CSS_VARS = [
  "--win-accent",
  "--win-accent-hover",
  "--win-accent-pressed",
  "--win-text-on-accent",
  "--text-on-accent",
] as const;

export function parseWinThemeSnapshot(raw: unknown): WinThemeSnapshot | null {
  if (!raw || typeof raw !== "object") return null;
  const record = raw as Record<string, unknown>;
  const windowsBuild = typeof record.windowsBuild === "number" && Number.isFinite(record.windowsBuild)
    ? record.windowsBuild
    : 0;
  const parsePalette = (val: unknown): WinAccentPalette | null => {
    if (!val || typeof val !== "object") return null;
    const p = val as Record<string, unknown>;
    if (
      typeof p.accent !== "string" ||
      typeof p.accentHover !== "string" ||
      typeof p.accentPressed !== "string" ||
      typeof p.textOnAccent !== "string"
    ) {
      return null;
    }
    return {
      accent: p.accent,
      accentHover: p.accentHover,
      accentPressed: p.accentPressed,
      textOnAccent: p.textOnAccent,
    };
  };
  return {
    windowsBuild,
    supportsSystemBackdrop: Boolean(record.supportsSystemBackdrop),
    appsUseLightTheme: Boolean(record.appsUseLightTheme),
    systemUsesLightTheme: Boolean(record.systemUsesLightTheme),
    enableTransparency: Boolean(record.enableTransparency),
    accentDark: parsePalette(record.accentDark),
    accentLight: parsePalette(record.accentLight),
  };
}

export function applyWinThemeToDom(
  root: HTMLElement,
  docEl: HTMLElement | null,
  snapshot: WinThemeSnapshot | null,
  opts: {
    readonly panelTheme: PanelTheme;
    readonly effectiveAppearance: "light" | "dark";
    readonly isStandaloneSettingsWindow: boolean;
  },
): void {
  const palette = snapshot
    ? (opts.effectiveAppearance === "light" ? snapshot.accentLight : snapshot.accentDark)
    : null;
  const styleTarget = docEl ?? root;
  if (palette) {
    styleTarget.style.setProperty("--win-accent", palette.accent);
    styleTarget.style.setProperty("--win-accent-hover", palette.accentHover);
    styleTarget.style.setProperty("--win-accent-pressed", palette.accentPressed);
    styleTarget.style.setProperty("--win-text-on-accent", palette.textOnAccent);
    styleTarget.style.setProperty("--text-on-accent", palette.textOnAccent);
  } else {
    for (const cssVar of ACCENT_CSS_VARS) {
      styleTarget.style.removeProperty(cssVar);
    }
  }

  const supportsBackdrop = Boolean(snapshot?.supportsSystemBackdrop);
  if (opts.isStandaloneSettingsWindow) {
    delete root.dataset.nativeBackdrop;
    if (docEl) {
      if (supportsBackdrop) {
        docEl.dataset.nativeBackdrop = "mica";
      } else {
        delete docEl.dataset.nativeBackdrop;
      }
    }
    return;
  }

  if (docEl) {
    delete docEl.dataset.nativeBackdrop;
  }
  // Never apply native DWM Acrylic to the Fluent two-island flyout.
  if (opts.panelTheme === "classic" && supportsBackdrop) {
    root.dataset.nativeBackdrop = "acrylic";
  } else {
    delete root.dataset.nativeBackdrop;
  }
}
