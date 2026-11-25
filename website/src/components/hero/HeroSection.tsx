import {
  Component,
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useRef,
  useState,
  type ErrorInfo,
  type ReactNode,
} from 'react';
import { ArrowDownToLine, ArrowLeft, Download, Mic, Monitor, Star, X } from 'lucide-react';
import { kelvinToHex, useHomeStore } from '../../store/homeStore';
import { formatStatCount, useGitHubStats } from '../../hooks/useGitHubStats';
import { playTactileSound } from '../../utils/tactileSound';
import {
  RELEASE_URLS,
  type Locale,
  type PlatformOS,
  type SiteDictionary,
} from '../../content/siteCopy';
import { FancyStarButton } from '../shared/FancyStarButton';
import { MenuBarPopover } from './MenuBarPopover';
import { CameraLiveDrawer } from './CameraLiveDrawer';
import { DoorbellPiPCard, SmokedGlassHud } from './SmokedGlassHud';
import { NATIVE_POPOVER_COPY } from './nativePopoverCopy';

const StudyScene3D = lazy(() => import('./StudyScene3D'));

interface WebGLBoundaryProps {
  onError: () => void;
  children: ReactNode;
}

class WebGLErrorBoundary extends Component<WebGLBoundaryProps, { hasError: boolean }> {
  state = { hasError: false };
  static getDerivedStateFromError() {
    return { hasError: true };
  }
  componentDidCatch(_err: Error, _info: ErrorInfo) {
    this.props.onError();
  }
  render() {
    if (this.state.hasError) return null;
    return this.props.children;
  }
}

interface HeroSectionProps {
  copy: SiteDictionary;
  locale: Locale;
  onToggleLocale: () => void;
  os: PlatformOS;
  onChangeOs: (os: PlatformOS) => void;
  reducedMotion: boolean;
}

function canUseWebGL(): boolean {
  if (typeof window === 'undefined' || typeof document === 'undefined') return false;
  try {
    const conn = (navigator as Navigator & { connection?: { saveData?: boolean } }).connection;
    if (conn?.saveData) return false;
    const canvas = document.createElement('canvas');
    const gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
    if (!gl) return false;
    const ext = gl.getExtension('WEBGL_lose_context');
    if (ext) ext.loseContext();
    return true;
  } catch {
    return false;
  }
}

export function HeroSection({
  copy,
  locale,
  onToggleLocale,
  os,
  onChangeOs,
  reducedMotion,
}: HeroSectionProps) {
  const heroRef = useRef<HTMLElement>(null);
  const searchInputRef = useRef<HTMLInputElement>(null);

  const [inViewport, setInViewport] = useState(true);
  const [isMobile, setIsMobile] = useState(false);
  const [mount3D, setMount3D] = useState(false);
  const [sceneReady, setSceneReady] = useState(false);
  const [webglFallback, setWebglFallback] = useState(false);

  const lampOn = useHomeStore((s) => s.lampOn);
  const lampBrightness = useHomeStore((s) => s.lampBrightness);
  const lampKelvin = useHomeStore((s) => s.lampKelvin);
  const ceilingOn = useHomeStore((s) => s.ceilingOn);
  const ceilingBrightness = useHomeStore((s) => s.ceilingBrightness);
  const curtainOpen = useHomeStore((s) => s.curtainOpen);
  const cameraFocus = useHomeStore((s) => s.cameraFocus);
  const cameraOpen = useHomeStore((s) => s.cameraOpen);
  const pipPinned = useHomeStore((s) => s.pipPinned);
  const voiceHudMessage = useHomeStore((s) => s.voiceHudMessage);
  const exitFocus = useHomeStore((s) => s.exitFocus);
  const toggleCameraFocus = useHomeStore((s) => s.toggleCameraFocus);

  const isFocused = cameraFocus === 'imac';
  const nativeCopy = NATIVE_POPOVER_COPY[locale];
  const { stars, downloads } = useGitHubStats();

  const focusSearch = useCallback(() => {
    searchInputRef.current?.focus();
  }, []);

  useEffect(() => {
    const mq = window.matchMedia('(max-width: 767px)');
    const sync = () => setIsMobile(mq.matches);
    sync();
    mq.addEventListener('change', sync);
    return () => mq.removeEventListener('change', sync);
  }, []);

  // Pause R3F frameloop completely when Hero scrolls out of view
  useEffect(() => {
    const el = heroRef.current;
    if (!el || typeof IntersectionObserver === 'undefined') return;
    const obs = new IntersectionObserver(
      ([entry]) => {
        setInViewport(entry.isIntersecting);
      },
      { threshold: 0.02 }
    );
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  // Lazy-mount 3D engine after LCP still paints (idle <= 900ms) on desktop/tablet
  useEffect(() => {
    if (isMobile) return;
    if (!canUseWebGL()) {
      setWebglFallback(true);
      return;
    }
    let cancelled = false;
    const activate = () => {
      if (!cancelled) setMount3D(true);
    };
    const ric = (
      window as Window & {
        requestIdleCallback?: (cb: () => void, opts?: { timeout: number }) => number;
        cancelIdleCallback?: (id: number) => void;
      }
    ).requestIdleCallback;

    if (ric) {
      const id = ric(activate, { timeout: 900 });
      return () => {
        cancelled = true;
        (window as Window & { cancelIdleCallback?: (id: number) => void }).cancelIdleCallback?.(id);
      };
    }
    const timer = window.setTimeout(activate, 350);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [isMobile]);

  // Native Keyboard-First Parity (PanelKeyRouter.swift):
  // - Layered Esc dismiss: Camera -> Quick Drawer -> Search -> Expanded Drawer -> Exit iMac Focus
  // - ⌥M / Alt+M focuses iMac + search
  // - ⌘K / Ctrl+K toggles Quick Scenes & For You drawer when focused
  // - ←/→ dims active light; typing `sftd` jumps directly to Desk Lamp
  useEffect(() => {
    let buffer = '';
    let bufTimer: number | undefined;

    const onKeyDown = (e: KeyboardEvent) => {
      if (!inViewport) return;
      const target = e.target as HTMLElement | null;
      const inInput = target?.tagName === 'INPUT' || target?.tagName === 'TEXTAREA';

      if (e.key === 'Escape') {
        const store = useHomeStore.getState();
        if (store.cameraOpen) {
          e.preventDefault();
          store.closeCamera();
          playTactileSound('tick', store.soundEnabled);
          return;
        }
        if (store.quickDrawerOpen) {
          e.preventDefault();
          store.setQuickDrawerOpen(false);
          playTactileSound('tick', store.soundEnabled);
          return;
        }
        if (store.searchQuery) {
          e.preventDefault();
          store.setSearchQuery('');
          playTactileSound('tick', store.soundEnabled);
          return;
        }
        if (store.expandedDevice) {
          e.preventDefault();
          store.setExpandedDevice(null);
          playTactileSound('tick', store.soundEnabled);
          return;
        }
        if (!inInput && store.cameraFocus === 'imac') {
          store.exitFocus();
          playTactileSound('tick', store.soundEnabled);
          return;
        }
      }

      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        const store = useHomeStore.getState();
        if (store.cameraFocus === 'imac') {
          e.preventDefault();
          store.toggleQuickDrawer();
          playTactileSound('tick', store.soundEnabled);
          return;
        }
      }

      if (e.altKey && (e.key.toLowerCase() === 'm' || e.code === 'KeyM')) {
        e.preventDefault();
        const store = useHomeStore.getState();
        store.focusImac();
        store.flashKeycap('optM');
        playTactileSound('click', store.soundEnabled);
        window.setTimeout(focusSearch, 220);
        return;
      }

      if (inInput) return;

      if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
        const store = useHomeStore.getState();
        store.flashKeycap('arrows');
        store.stepActiveLightBrightness(e.key === 'ArrowRight' ? 10 : -10);
        playTactileSound('tick', store.soundEnabled);
        return;
      }

      if (e.key.length === 1 && /^[a-z]$/i.test(e.key) && !e.metaKey && !e.ctrlKey && !e.altKey) {
        buffer = (buffer + e.key.toLowerCase()).slice(-4);
        window.clearTimeout(bufTimer);
        bufTimer = window.setTimeout(() => {
          buffer = '';
        }, 1200);
        if (buffer === 'sftd') {
          const store = useHomeStore.getState();
          store.focusImac();
          store.flashKeycap('sftd');
          store.setSearchQuery('sftd');
          playTactileSound('click', store.soundEnabled);
          window.setTimeout(focusSearch, 220);
          buffer = '';
        }
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.clearTimeout(bufTimer);
    };
  }, [inViewport, focusSearch]);

  const primaryHref = os === 'macos' ? RELEASE_URLS.macDmg : RELEASE_URLS.winExe;
  const primaryLabel = os === 'macos' ? copy.hero.downloadMac : copy.hero.downloadWin;
  const lampHex = kelvinToHex(lampKelvin);
  const lampRatio = lampOn ? lampBrightness / 100 : 0;
  const ceilingRatio = ceilingOn ? ceilingBrightness / 100 : 0;
  const sunRatio = curtainOpen / 100;

  return (
    <section
      id="top"
      ref={heroRef}
      data-enter="hero"
      className="relative flex min-h-[100svh] w-full flex-col justify-between overflow-hidden bg-[#e8dccb]"
      onPointerEnter={() => {
        if (!isMobile && !mount3D && !webglFallback && canUseWebGL()) {
          setMount3D(true);
        }
      }}
    >
      {/* ===== Layer 0 + 1: Interactive 3D Golden-Hour Study + Instant Pre-LCP Static Fallback ===== */}
      <div
        data-fx="golden-hour-study-3d"
        data-fx-mounted={sceneReady && !webglFallback ? 'true' : undefined}
        data-fx-fallback={webglFallback || (!sceneReady && isMobile) ? 'true' : undefined}
        className="absolute inset-0 overflow-hidden"
      >
        <picture className="pointer-events-none block h-full w-full">
          <source media="(max-width: 767px)" srcSet="./media/hero-poster-mobile.webp" type="image/webp" />
          <img
            src="./media/hero-poster.webp"
            alt="Warm golden-hour study with a Blue M4 iMac on an Apple Store oak table beside Mi Home lamps, wall AC, and motorized sunset curtains"
            width={1600}
            height={1000}
            fetchPriority="high"
            decoding="async"
            className="pointer-events-none h-full w-full object-cover object-[50%_46%] transition-[filter,opacity] duration-500"
            style={{
              filter: `brightness(${0.66 + sunRatio * 0.22 + lampRatio * 0.1 + ceilingRatio * 0.1}) saturate(${0.92 + sunRatio * 0.14})`,
            }}
          />
        </picture>

        {/* Reactive 2D golden sunset & warm lamp spill for instant mobile/fallback feedback */}
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 transition-opacity duration-300"
          style={{
            opacity: lampOn ? 0.14 + lampRatio * 0.26 : 0,
            background: `radial-gradient(48% 44% at 30% 54%, ${lampHex}44 0%, ${lampHex}12 46%, transparent 78%)`,
          }}
        />
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 transition-opacity duration-300"
          style={{
            opacity: 0.08 + sunRatio * 0.34,
            background:
              'radial-gradient(50% 62% at 88% 36%, rgba(245, 168, 86, 0.42) 0%, rgba(245, 158, 72, 0.12) 48%, transparent 80%)',
          }}
        />

        {/* Single Lazy-Loaded 3D WebGL Canvas */}
        {mount3D && !webglFallback && (
          <div
            className="absolute inset-0 z-10 transition-opacity duration-500"
            style={{
              opacity: sceneReady ? 1 : 0,
              touchAction: 'pan-y',
            }}
          >
            <WebGLErrorBoundary
              onError={() => {
                setWebglFallback(true);
                setSceneReady(false);
              }}
            >
              <Suspense fallback={null}>
                <StudyScene3D
                  visible={inViewport}
                  reducedMotion={reducedMotion}
                  onReady={() => setSceneReady(true)}
                  onFallback={() => {
                    setWebglFallback(true);
                    setSceneReady(false);
                  }}
                  onFocusSearch={focusSearch}
                />
              </Suspense>
            </WebGLErrorBoundary>
          </div>
        )}
      </div>

      {/* ===== Layer 2: Delicate Warm Cream Scrim (retreats softly in iMac Focus Mode) ===== */}
      <div
        className="hero-warm-scrim pointer-events-none absolute inset-0 z-20 transition-opacity duration-400"
        style={{ opacity: isFocused ? 0.22 : 1 }}
        aria-hidden="true"
      />

      {/* ===== Top Editorial Navigation Bar ===== */}
      <header className="hero-chrome relative z-30 w-full">
        <div className="mx-auto flex h-16 max-w-[1080px] items-center justify-between gap-1.5 px-5 sm:h-[72px] sm:gap-2 sm:px-10">
          <a
            href="#top"
            className="site-brand inline-flex min-h-[44px] shrink-0 items-center gap-2 text-[14px] font-semibold tracking-[-0.015em] text-[#1e1a16] sm:gap-2.5 sm:text-[15px]"
          >
            <img
              src="./media/logo-dark.svg"
              alt=""
              width={28}
              height={28}
              className="size-6.5 rounded-[23%] shadow-xs sm:size-7"
            />
            <span>MenuBarHome</span>
          </a>

          <nav aria-label="Primary" className="flex items-center gap-1.5 sm:gap-4">
            <a
              href="#features"
              className="hidden min-h-[44px] items-center text-[13px] font-medium text-[#3b332b] transition-colors duration-150 hover:text-[#1e1a16] sm:inline-flex"
            >
              {copy.nav.features}
            </a>
            <a
              href="#shortcuts"
              className="hidden min-h-[44px] items-center text-[13px] font-medium text-[#3b332b] transition-colors duration-150 hover:text-[#1e1a16] sm:inline-flex"
            >
              {copy.nav.shortcuts}
            </a>

            <FancyStarButton
              variant="nav"
              label={copy.nav.star}
              starredLabel={copy.nav.starred}
              locale={locale}
              href={RELEASE_URLS.repo}
            />

            <button
              type="button"
              onClick={onToggleLocale}
              aria-label={copy.nav.langAria}
              className="btn-tactile inline-flex min-h-[44px] min-w-[44px] items-center justify-center rounded-full px-2 text-[12.5px] font-medium text-[#4a4239] hover:bg-[#1e1a16]/[0.07] hover:text-[#1e1a16] sm:min-h-[36px] sm:min-w-[40px] sm:px-2.5"
            >
              {copy.nav.langToggle}
            </button>

            <a
              href="#download"
              className="glass-pill-warm btn-tactile inline-flex min-h-[44px] shrink-0 items-center rounded-full px-3 text-[12.5px] font-semibold text-[#1e1a16] sm:h-9 sm:min-h-0 sm:px-4 sm:text-[13px]"
            >
              {copy.nav.download}
            </a>
          </nav>
        </div>
      </header>

      {/* Floating Focus-Mode Pill cleanly aligned above the Blue iMac */}
      {isFocused && (
        <div className="pointer-events-auto absolute top-[72px] left-5 z-30 hidden sm:left-10 md:block">
          <div className="warm-hud inline-flex items-center gap-2.5 rounded-full px-3.5 py-1.5 text-[12px] whitespace-nowrap text-[#1e1a16]">
            <span className="size-2 shrink-0 rounded-full bg-[#4a78ab]" aria-hidden="true" />
            <span className="font-medium text-[#3b332b]">{copy.hero.focusBannerHint}</span>
            <button
              type="button"
              onClick={() => {
                exitFocus();
                playTactileSound('tick', useHomeStore.getState().soundEnabled);
              }}
              className="btn-tactile inline-flex h-6 shrink-0 items-center gap-1 rounded-full bg-[#1e1a16] px-2.5 text-[11px] font-medium text-[#fbf9f5] hover:bg-[#322c26]"
            >
              <ArrowLeft className="size-3" aria-hidden="true" />
              <span>{copy.hero.exitFocusLabel}</span>
            </button>
          </div>
        </div>
      )}

      {/* Non-Activating Native Voice / Snapshot HUD Toast (matches macos-hold-to-talk.png corner HUD) */}
      {voiceHudMessage && (
        <div
          role="status"
          aria-live="polite"
          className="pointer-events-none absolute bottom-[114px] left-5 z-40 sm:left-10"
        >
          <div className="inline-flex items-center gap-2 rounded-full bg-[#1a1816]/92 px-3.5 py-2 text-[12px] font-medium text-[#fbf9f5] shadow-[0_14px_34px_-12px_rgba(14,10,6,0.6)] ring-1 ring-white/12 backdrop-blur-xl">
            <Mic className="size-3.5 text-[#ff9500]" aria-hidden="true" />
            <span className="tabular-nums">{voiceHudMessage}</span>
          </div>
        </div>
      )}

      {/* Always-on-Top Pinned Doorbell PiP when user closed the full Live Camera Window */}
      {pipPinned && !cameraOpen && (
        <div
          className={`pointer-events-auto absolute z-40 ${
            isFocused
              ? 'bottom-[114px] left-5 sm:left-10 lg:right-[428px] lg:left-auto'
              : 'top-[78px] right-5 sm:right-10'
          }`}
        >
          <DoorbellPiPCard
            doorbellName={copy.hero.popover.doorbellName}
            videoOnlyLabel={copy.hero.popover.videoOnly}
            pinnedLabel={copy.hero.popover.doorbellPinned}
          />
        </div>
      )}

      {/* ===== Main Hero Foreground: Bottom-Left Editorial Lockup + Click-to-Reveal Native macOS Panel & Live Camera ===== */}
      <div className="hero-chrome pointer-events-none relative z-30 mx-auto flex w-full max-w-[1080px] flex-1 flex-col justify-end px-5 pb-5 sm:px-10 sm:pb-7">
        {/* Bottom-Left Editorial Lockup (smoothly retreats when focused on Blue iMac) */}
        <div
          className={`max-w-[35rem] transition-[opacity,transform] duration-300 ${
            isFocused
              ? 'pointer-events-none translate-y-3 opacity-0'
              : 'pointer-events-auto translate-y-0 opacity-100'
          }`}
        >
          {copy.hero.eyebrow && (
            <p className="hero-enter-item editorial-eyebrow mb-3 inline-flex rounded-full bg-[#f6f2eb]/86 px-2.5 py-1 ring-1 ring-[#1e1a16]/10 backdrop-blur-md">
              {copy.hero.eyebrow}
            </p>
          )}

          <h1 id="main-heading" tabIndex={-1} className="hero-enter-item editorial-h1">
            {copy.hero.h1Prefix && copy.hero.h1Accent ? (
              <>
                {copy.hero.h1Prefix}
                <em className="editorial-italic">{copy.hero.h1Accent}</em>
              </>
            ) : (
              copy.hero.h1
            )}
          </h1>

          <p className="hero-enter-item hero-enter-item-delay-1 editorial-lead mt-4 max-w-[31rem]">
            {copy.hero.lead}
          </p>

          {/* Primary Download Pill & Blue iMac Focus Action Pill */}
          <div className="hero-enter-item hero-enter-item-delay-2 mt-5 flex flex-wrap items-center gap-3">
            <a
              href={primaryHref}
              className="btn-tactile inline-flex h-11 items-center gap-2 rounded-full bg-[#1e1a16] px-5 text-[15px] font-medium tracking-[-0.01em] text-[#fbf9f5] shadow-[0_1px_1px_rgba(30,26,22,0.25),0_12px_26px_-10px_rgba(30,26,22,0.4)] hover:bg-[#312b25]"
            >
              <Download className="size-4" aria-hidden="true" />
              <span>{primaryLabel}</span>
            </a>

            <button
              type="button"
              onClick={() => {
                toggleCameraFocus();
                playTactileSound('click', useHomeStore.getState().soundEnabled);
              }}
              className="glass-pill-warm btn-tactile inline-flex h-11 items-center gap-2 rounded-full px-5 text-[15px] font-medium tracking-[-0.01em] text-[#1e1a16]"
            >
              <Monitor className="size-4 text-[#4a78ab]" aria-hidden="true" />
              <span>{copy.hero.secondaryCta}</span>
            </button>
          </div>

          {/* Live GitHub Stars & Downloads proof strip + platform parity switch */}
          <div className="hero-enter-item hero-enter-item-delay-3 mt-4 flex flex-wrap items-center gap-x-2.5 gap-y-1 text-[13px] text-[#3b332b]">
            <span className="metric-inline inline-flex items-center gap-1 text-[12.5px] text-[#2c251e]">
              <Star className="size-3 fill-[#d97706] text-[#b45309]" aria-hidden="true" />
              <span>{formatStatCount(stars)}</span>
              <span className="font-sans text-[12px] text-[#5b5349]">{copy.stats.starsLabel}</span>
            </span>
            <span aria-hidden="true" className="text-[#71685e]">
              ·
            </span>
            <span className="metric-inline inline-flex items-center gap-1 text-[12.5px] text-[#2c251e]">
              <ArrowDownToLine className="size-3 text-[#665e54]" aria-hidden="true" />
              <span>{formatStatCount(downloads)}</span>
              <span className="font-sans text-[12px] text-[#5b5349]">{copy.stats.downloadsLabel}</span>
            </span>
            <span aria-hidden="true" className="hidden text-[#71685e] sm:inline">
              ·
            </span>
            <span className="metric-inline hidden text-[12.5px] text-[#3b332b] sm:inline">
              v1.4.0 · MIT
            </span>
            <span aria-hidden="true" className="hidden text-[#71685e] sm:inline">
              ·
            </span>
            <button
              type="button"
              onClick={() => onChangeOs(os === 'macos' ? 'windows' : 'macos')}
              className="editorial-link inline-flex min-h-[44px] items-center font-medium text-[#2c251e] sm:min-h-0"
            >
              {os === 'macos' ? copy.hero.switchToWin : copy.hero.switchToMac}
            </button>
          </div>
        </div>

        {/* Desktop Click-to-Reveal Native macOS MenuBarHome Panel + Side-by-Side Live Camera Window */}
        {isFocused && (
          <div className="pointer-events-none absolute right-5 bottom-[114px] left-5 z-30 hidden items-end justify-end gap-3 sm:right-10 sm:left-10 md:flex">
            {/* Floating Interactive Live Camera Window (opens when clicking the Camera/Doorbell card!) */}
            {cameraOpen && (
              <div className="pointer-events-auto w-full max-w-[404px]">
                <CameraLiveDrawer nativeCopy={nativeCopy} reducedMotion={reducedMotion} />
              </div>
            )}

            {/* Right-Docked Native MenuBarHome macOS Popover */}
            <div className="lg-popover-enter pointer-events-auto w-[372px] shrink-0">
              <MenuBarPopover
                copy={copy.hero.popover}
                presetsCopy={copy.hero.presets}
                locale={locale}
                searchInputRef={searchInputRef}
              />
            </div>
          </div>
        )}

        {/* Mobile (< 768px) Native Control Panel & Interactive Live Camera Sheet */}
        {(isFocused || cameraOpen) && (
          <div className="pointer-events-auto fixed inset-0 z-50 flex flex-col justify-end bg-black/35 p-3 backdrop-blur-xs md:hidden">
            <div className="mx-auto flex max-h-[86svh] w-full max-w-[390px] flex-col gap-2 overflow-y-auto pb-1">
              <div className="flex items-center justify-between rounded-full bg-[#1e1a16]/90 px-3.5 py-1.5 text-[11.5px] font-medium text-[#fbf9f5]">
                <span>{nativeCopy.focusCompactBanner}</span>
                <button
                  type="button"
                  aria-label={copy.hero.exitFocusLabel}
                  onClick={() => {
                    exitFocus();
                    playTactileSound('tick', useHomeStore.getState().soundEnabled);
                  }}
                  className="inline-flex size-6 items-center justify-center rounded-full bg-white/15 text-white"
                >
                  <X className="size-3.5" aria-hidden="true" />
                </button>
              </div>
              {cameraOpen ? (
                <CameraLiveDrawer nativeCopy={nativeCopy} reducedMotion={reducedMotion} />
              ) : (
                <MenuBarPopover
                  copy={copy.hero.popover}
                  presetsCopy={copy.hero.presets}
                  locale={locale}
                  searchInputRef={searchInputRef}
                />
              )}
            </div>
          </div>
        )}

        {/* Bottom Warm Frosted HUD & Stage Hint */}
        <div className="pointer-events-auto mt-4 flex flex-wrap items-center justify-between gap-3">
          <SmokedGlassHud
            copy={copy.hero}
            locale={locale}
            onFocusSearch={() => {
              useHomeStore.getState().focusImac();
              window.setTimeout(focusSearch, 220);
            }}
          />
          {!isFocused && (
            <p className="hidden text-[12px] font-medium text-[#3b332b] lg:block">
              {copy.hero.stageHint}
            </p>
          )}
        </div>
      </div>

      {/* Accessible language change announcement */}
      <span className="visually-hidden" aria-live="polite">
        {locale === 'zh' ? '当前语言：简体中文' : 'Current language: English'}
      </span>
    </section>
  );
}
