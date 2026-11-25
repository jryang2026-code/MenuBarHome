import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { MotionConfig } from 'motion/react';
import { ReactLenis, type LenisRef } from 'lenis/react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { useGSAP } from '@gsap/react';
import { SITE_COPY, type DetectedOS, type Locale, type PlatformOS } from './content/siteCopy';
import { useHomeStore } from './store/homeStore';
import { HeroSection } from './components/hero/HeroSection';
import { FeaturesSection } from './components/sections/FeaturesSection';
import { ShortcutsSection } from './components/sections/ShortcutsSection';
import { DownloadSection } from './components/sections/DownloadSection';
import { FooterSection } from './components/sections/FooterSection';

gsap.registerPlugin(ScrollTrigger, useGSAP);

const LOCALE_STORAGE_KEY = 'mbh_locale_v1';

const useIsomorphicLayoutEffect =
  typeof window !== 'undefined' ? useLayoutEffect : useEffect;

function detectPlatformOS(): DetectedOS {
  if (typeof window === 'undefined') return 'macos';

  const params = new URLSearchParams(window.location.search);
  const forced = params.get('platform')?.toLowerCase();
  if (forced === 'mac' || forced === 'macos') return 'macos';
  if (forced === 'win' || forced === 'windows') return 'windows';

  const ua = navigator.userAgent || '';
  // Phones, tablets, Linux and ChromeOS: iOS/iPadOS UAs also say "Mac OS X", so check them first.
  if (/iphone|ipad|ipod|android|linux|cros/i.test(ua)) return 'other';
  if (/macintosh/i.test(ua) && navigator.maxTouchPoints > 1) return 'other';
  if (/macintosh|mac os x/i.test(ua)) return 'macos';
  if (/windows|win32|win64|wow64/i.test(ua)) return 'windows';

  const uaDataPlatform = (
    navigator as Navigator & { userAgentData?: { platform?: string } }
  ).userAgentData?.platform;
  if (uaDataPlatform) {
    if (/win/i.test(uaDataPlatform)) return 'windows';
    if (/mac/i.test(uaDataPlatform)) return 'macos';
  }

  const navPlatform = navigator.platform || '';
  if (/win/i.test(navPlatform)) return 'windows';
  if (/mac/i.test(navPlatform)) return 'macos';

  return 'other';
}

function detectLocale(): Locale {
  if (typeof window === 'undefined') return 'en';

  // 1. Explicit URL parameter (?lang=zh, ?lang=zh-CN, ?lang=en, etc.)
  const params = new URLSearchParams(window.location.search);
  const paramLang = params.get('lang')?.trim().toLowerCase();
  if (paramLang) {
    if (/^zh(?:\b|[-_])/.test(paramLang)) return 'zh';
    if (/^en(?:\b|[-_])/.test(paramLang)) return 'en';
  }

  // 2. Saved manual toggle override in localStorage
  try {
    const saved = window.localStorage.getItem(LOCALE_STORAGE_KEY);
    if (saved === 'zh' || saved === 'en') return saved;
  } catch {
    // Ignore storage errors in privacy/sandboxed contexts
  }

  // 3. Automatic browser language preference
  const preferred =
    Array.isArray(navigator.languages) && navigator.languages.length > 0
      ? navigator.languages
      : navigator.language
        ? [navigator.language]
        : [];

  for (const tag of preferred) {
    const normalized = String(tag || '').trim().toLowerCase();
    if (/^zh(?:\b|[-_])/.test(normalized)) return 'zh';
    if (/^en(?:\b|[-_])/.test(normalized)) return 'en';
  }

  return 'en';
}

export function App() {
  // Deterministic SSR/hydration defaults; real OS + locale hydrate synchronously before paint
  const [locale, setLocale] = useState<Locale>('en');
  const [os, setOs] = useState<PlatformOS>('macos');
  const [unsupportedOs, setUnsupportedOs] = useState(false);
  const [reducedMotion, setReducedMotion] = useState(false);

  const appRef = useRef<HTMLDivElement>(null);
  const lenisRef = useRef<LenisRef>(null);

  // Apply detected OS + browser/saved/URL locale synchronously before first paint (0 hydration mismatch)
  useIsomorphicLayoutEffect(() => {
    const detectedOs = detectPlatformOS();
    const detectedLocale = detectLocale();
    setOs(detectedOs === 'windows' ? 'windows' : 'macos');
    setUnsupportedOs(detectedOs === 'other');
    setLocale(detectedLocale);
    document.documentElement.lang = detectedLocale === 'zh' ? 'zh-CN' : 'en';
  }, []);

  // Track reduced-motion preference
  useEffect(() => {
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
    const syncMotion = () => setReducedMotion(mq.matches);
    syncMotion();
    mq.addEventListener('change', syncMotion);
    return () => mq.removeEventListener('change', syncMotion);
  }, []);

  useIsomorphicLayoutEffect(() => {
    document.documentElement.lang = locale === 'zh' ? 'zh-CN' : 'en';
  }, [locale]);

  const handleToggleLocale = () => {
    setLocale((prev) => {
      const next: Locale = prev === 'en' ? 'zh' : 'en';
      try {
        window.localStorage.setItem(LOCALE_STORAGE_KEY, next);
      } catch {
        // Ignore storage errors in restricted contexts
      }
      return next;
    });
  };

  // Single gsap.ticker loop driving Lenis smooth scroll + ScrollTrigger (lagSmoothing(0))
  useEffect(() => {
    if (reducedMotion) return;

    const update = (time: number) => {
      lenisRef.current?.lenis?.raf(time * 1000);
    };

    const lenis = lenisRef.current?.lenis;
    lenis?.on('scroll', ScrollTrigger.update);

    gsap.ticker.add(update);
    gsap.ticker.lagSmoothing(0);

    return () => {
      lenis?.off('scroll', ScrollTrigger.update);
      gsap.ticker.remove(update);
    };
  }, [reducedMotion]);

  // Hero scroll-linked camera dolly progress scrubbed cleanly into Zustand transient state
  useGSAP(
    () => {
      if (reducedMotion) {
        useHomeStore.getState().setScrollProgress(0);
        return;
      }

      const mm = gsap.matchMedia();
      mm.add('(prefers-reduced-motion: no-preference)', () => {
        ScrollTrigger.create({
          trigger: '#top',
          start: 'top top',
          end: 'bottom top',
          scrub: true,
          onUpdate: (self) => {
            useHomeStore.getState().setScrollProgress(self.progress);
          },
        });
      });

      return () => mm.revert();
    },
    { scope: appRef, dependencies: [reducedMotion], revertOnUpdate: true }
  );

  const copy = SITE_COPY[locale];

  return (
    <MotionConfig reducedMotion="user">
      {!reducedMotion && (
        <ReactLenis
          root
          ref={lenisRef}
          options={{
            autoRaf: false,
            lerp: 0.1,
            anchors: true,
            respectReducedMotion: true,
          }}
        />
      )}

      <div ref={appRef} className="min-h-screen bg-[#f6f2eb] text-[#1e1a16]">
        {/* Accessible Skip Link (first keyboard Tab stop) */}
        <a
          href="#main-heading"
          className="visually-hidden fixed top-3 left-3 z-50 rounded-full bg-[#1e1a16] px-4 py-2 text-[13px] font-semibold text-[#fbf9f5] shadow-lg"
        >
          {copy.skipToContent}
        </a>

        <main>
          <HeroSection
            copy={copy}
            locale={locale}
            onToggleLocale={handleToggleLocale}
            os={os}
            onChangeOs={setOs}
            reducedMotion={reducedMotion}
          />
          <FeaturesSection
            copy={copy.features}
            locale={locale}
            os={os}
            reducedMotion={reducedMotion}
          />
          <ShortcutsSection copy={copy.shortcuts} os={os} />
          <DownloadSection
            copy={copy.download}
            os={os}
            onChangeOs={setOs}
            unsupportedOs={unsupportedOs}
          />
        </main>

        <FooterSection copy={copy.footer} locale={locale} />
      </div>
    </MotionConfig>
  );
}

export default App;
