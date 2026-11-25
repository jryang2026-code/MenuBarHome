import { useEffect, useSyncExternalStore } from 'react';

const REPO_API_URL = 'https://api.github.com/repos/jryang2026-code/MenuBarHome';
const RELEASES_API_URL = 'https://api.github.com/repos/jryang2026-code/MenuBarHome/releases?per_page=100';
const SESSION_CACHE_KEY = 'mbh_gh_stats_v1';
const LOCAL_STAR_KEY = 'mbh_starred_v1';
const CACHE_TTL_MS = 15 * 60 * 1000;
const INSTALLER_ASSET_RE = /\.(dmg|exe|msi)$/i;

/** Verified baseline fetched from GitHub API for jryang2026-code/MenuBarHome */
export const GITHUB_FALLBACK_STATS = {
  stars: 59,
  downloads: 462,
} as const;

interface InternalStatsState {
  baseStars: number;
  downloads: number;
  isLive: boolean;
  starredLocally: boolean;
}

export interface GitHubStatsSnapshot {
  /** Displayed star count (includes optimistic +1 when starredLocally is true) */
  stars: number;
  /** Raw repo stargazer count before local optimistic bump */
  baseStars: number;
  /** Total installer downloads (.dmg + .exe + .msi across releases) */
  downloads: number;
  /** True once live GitHub API data (or fresh session cache) hydrated */
  isLive: boolean;
  /** True once visitor clicked any Star CTA on the page */
  starredLocally: boolean;
  /** Optimistically marks starred across all mounted components */
  triggerLocalStar: () => void;
}

interface CachedPayload {
  stars: number;
  downloads: number;
  ts: number;
}

const SERVER_STATE: InternalStatsState = {
  baseStars: GITHUB_FALLBACK_STATS.stars,
  downloads: GITHUB_FALLBACK_STATS.downloads,
  isLive: false,
  starredLocally: false,
};

let currentState: InternalStatsState = { ...SERVER_STATE };
const listeners = new Set<() => void>();
let inflightFetch: Promise<void> | null = null;
let clientInitialized = false;

function emit() {
  listeners.forEach((listener) => listener());
}

function setState(partial: Partial<InternalStatsState>) {
  const next: InternalStatsState = { ...currentState, ...partial };
  if (
    next.baseStars === currentState.baseStars &&
    next.downloads === currentState.downloads &&
    next.isLive === currentState.isLive &&
    next.starredLocally === currentState.starredLocally
  ) {
    return;
  }
  currentState = next;
  emit();
}

function readSessionCache(): CachedPayload | null {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.sessionStorage.getItem(SESSION_CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<CachedPayload>;
    if (
      typeof parsed.stars === 'number' &&
      Number.isFinite(parsed.stars) &&
      parsed.stars >= 0 &&
      typeof parsed.downloads === 'number' &&
      Number.isFinite(parsed.downloads) &&
      parsed.downloads >= 0 &&
      typeof parsed.ts === 'number' &&
      Date.now() - parsed.ts < CACHE_TTL_MS
    ) {
      return {
        stars: Math.round(parsed.stars),
        downloads: Math.round(parsed.downloads),
        ts: parsed.ts,
      };
    }
  } catch {
    // Ignore storage quota/privacy mode errors silently
  }
  return null;
}

function writeSessionCache(stars: number, downloads: number) {
  if (typeof window === 'undefined') return;
  try {
    const payload: CachedPayload = { stars, downloads, ts: Date.now() };
    window.sessionStorage.setItem(SESSION_CACHE_KEY, JSON.stringify(payload));
  } catch {
    // Ignore storage errors silently
  }
}

function readLocalStarFlag(): boolean {
  if (typeof window === 'undefined') return false;
  try {
    return window.localStorage.getItem(LOCAL_STAR_KEY) === '1';
  } catch {
    return false;
  }
}

export function triggerLocalStar(): void {
  if (typeof window !== 'undefined') {
    try {
      window.localStorage.setItem(LOCAL_STAR_KEY, '1');
    } catch {
      // Ignore storage errors silently
    }
  }
  if (!currentState.starredLocally) {
    setState({ starredLocally: true });
  }
}

async function fetchLiveStatsOnce(): Promise<void> {
  if (typeof window === 'undefined' || typeof fetch !== 'function') return;
  if (inflightFetch) return inflightFetch;

  inflightFetch = (async () => {
    const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timeoutId = controller ? window.setTimeout(() => controller.abort(), 6500) : null;

    try {
      const headers = { Accept: 'application/vnd.github+json' };
      const signal = controller?.signal;

      const [repoRes, relRes] = await Promise.allSettled([
        fetch(REPO_API_URL, { headers, signal }),
        fetch(RELEASES_API_URL, { headers, signal }),
      ]);

      let nextStars = currentState.baseStars;
      let nextDownloads = currentState.downloads;
      let gotLive = false;

      if (repoRes.status === 'fulfilled' && repoRes.value.ok) {
        const repoJson = (await repoRes.value.json()) as { stargazers_count?: unknown };
        if (
          typeof repoJson.stargazers_count === 'number' &&
          Number.isFinite(repoJson.stargazers_count) &&
          repoJson.stargazers_count >= 0
        ) {
          nextStars = Math.round(repoJson.stargazers_count);
          gotLive = true;
        }
      }

      if (relRes.status === 'fulfilled' && relRes.value.ok) {
        const releasesJson = (await relRes.value.json()) as unknown;
        if (Array.isArray(releasesJson)) {
          let sum = 0;
          for (const release of releasesJson) {
            const assets = (release as { assets?: unknown })?.assets;
            if (!Array.isArray(assets)) continue;
            for (const asset of assets) {
              const name = (asset as { name?: unknown })?.name;
              const count = (asset as { download_count?: unknown })?.download_count;
              if (
                typeof name === 'string' &&
                INSTALLER_ASSET_RE.test(name) &&
                typeof count === 'number' &&
                Number.isFinite(count) &&
                count > 0
              ) {
                sum += count;
              }
            }
          }
          if (sum > 0) {
            nextDownloads = Math.round(sum);
            gotLive = true;
          }
        }
      }

      if (gotLive) {
        writeSessionCache(nextStars, nextDownloads);
        setState({
          baseStars: nextStars,
          downloads: nextDownloads,
          isLive: true,
        });
      }
    } catch {
      // Silent fallback on offline/CORS/abort/rate-limit — never log console errors
    } finally {
      if (timeoutId !== null) window.clearTimeout(timeoutId);
      inflightFetch = null;
    }
  })();

  return inflightFetch;
}

function initClientSync() {
  if (typeof window === 'undefined' || clientInitialized) return;
  clientInitialized = true;

  const starredLocally = readLocalStarFlag();
  const cached = readSessionCache();

  if (cached) {
    setState({
      baseStars: cached.stars,
      downloads: cached.downloads,
      isLive: true,
      starredLocally,
    });
    return;
  }

  if (starredLocally) {
    setState({ starredLocally: true });
  }

  // Defer live API hydration briefly so critical LCP poster & fonts never contend
  const kick = () => {
    void fetchLiveStatsOnce();
  };
  const ric = (
    window as Window & {
      requestIdleCallback?: (cb: () => void, opts?: { timeout: number }) => number;
    }
  ).requestIdleCallback;

  if (ric) {
    ric(kick, { timeout: 1200 });
  } else {
    window.setTimeout(kick, 250);
  }
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function getSnapshot(): InternalStatsState {
  return currentState;
}

function getServerSnapshot(): InternalStatsState {
  return SERVER_STATE;
}

export function formatStatCount(value: number): string {
  return value.toLocaleString('en-US');
}

export function useGitHubStats(): GitHubStatsSnapshot {
  const state = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);

  useEffect(() => {
    initClientSync();
  }, []);

  return {
    stars: state.baseStars + (state.starredLocally ? 1 : 0),
    baseStars: state.baseStars,
    downloads: state.downloads,
    isLive: state.isLive,
    starredLocally: state.starredLocally,
    triggerLocalStar,
  };
}
