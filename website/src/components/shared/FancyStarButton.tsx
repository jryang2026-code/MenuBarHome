import { useEffect, useRef, useState, type PointerEvent } from 'react';
import { Github, Star } from 'lucide-react';
import { RELEASE_URLS, type Locale } from '../../content/siteCopy';
import { useHomeStore } from '../../store/homeStore';
import { playTactileSound } from '../../utils/tactileSound';
import { formatStatCount, useGitHubStats } from '../../hooks/useGitHubStats';

export type FancyStarVariant = 'nav' | 'spotlight' | 'subtle';

export interface FancyStarButtonProps {
  variant?: FancyStarVariant;
  label?: string;
  starredLabel?: string;
  locale?: Locale;
  href?: string;
  showGithubIcon?: boolean;
  className?: string;
  onStarClick?: () => void;
}

/** 8 crisp geometric golden micro-spark vectors radiating around the star icon on click */
const SPARK_VECTORS = [
  { sx: '-22px', sy: '-18px', rot: '-35deg', delay: '0ms', shape: 'diamond' },
  { sx: '0px', sy: '-26px', rot: '0deg', delay: '20ms', shape: 'dot' },
  { sx: '22px', sy: '-18px', rot: '35deg', delay: '10ms', shape: 'diamond' },
  { sx: '27px', sy: '2px', rot: '75deg', delay: '35ms', shape: 'dot' },
  { sx: '19px', sy: '20px', rot: '130deg', delay: '15ms', shape: 'diamond' },
  { sx: '-2px', sy: '24px', rot: '180deg', delay: '40ms', shape: 'dot' },
  { sx: '-21px', sy: '18px', rot: '-135deg', delay: '25ms', shape: 'diamond' },
  { sx: '-27px', sy: '-1px', rot: '-85deg', delay: '30ms', shape: 'dot' },
] as const;

function RollingStarCount({ value, className }: { value: number; className?: string }) {
  const prevRef = useRef(value);
  const [prevValue, setPrevValue] = useState<number | null>(null);
  const [rollKey, setRollKey] = useState(0);

  useEffect(() => {
    if (prevRef.current !== value) {
      setPrevValue(prevRef.current);
      prevRef.current = value;
      setRollKey((k) => k + 1);
      const timer = window.setTimeout(() => setPrevValue(null), 380);
      return () => window.clearTimeout(timer);
    }
    return undefined;
  }, [value]);

  const formatted = formatStatCount(value);

  return (
    <span className={`star-odometer ${className ?? ''}`}>
      {prevValue !== null && (
        <span
          key={`out-${rollKey}`}
          aria-hidden="true"
          className="star-odometer-out"
        >
          {formatStatCount(prevValue)}
        </span>
      )}
      <span
        key={rollKey > 0 ? `in-${rollKey}` : 'rest'}
        className={rollKey > 0 ? 'star-odometer-in' : undefined}
      >
        {formatted}
      </span>
    </span>
  );
}

export function FancyStarButton({
  variant = 'nav',
  label,
  starredLabel,
  locale = 'en',
  href = RELEASE_URLS.repo,
  showGithubIcon = variant === 'spotlight',
  className = '',
  onStarClick,
}: FancyStarButtonProps) {
  const { stars, starredLocally, triggerLocalStar } = useGitHubStats();
  const [burstKey, setBurstKey] = useState(0);
  const sheenRef = useRef<HTMLSpanElement>(null);
  const anchorRef = useRef<HTMLAnchorElement>(null);

  const defaultLabel =
    variant === 'spotlight'
      ? locale === 'zh'
        ? '去 GitHub 点星'
        : 'Star on GitHub'
      : locale === 'zh'
        ? '点星'
        : 'Star';

  const defaultStarredLabel =
    variant === 'spotlight'
      ? locale === 'zh'
        ? '已在 GitHub 点星'
        : 'Starred on GitHub'
      : locale === 'zh'
        ? '已点星'
        : 'Starred';

  const visibleLabel = starredLocally
    ? (starredLabel ?? defaultStarredLabel)
    : (label ?? defaultLabel);

  const accessibleLabel =
    locale === 'zh'
      ? `${visibleLabel} MenuBarHome（当前 ${formatStatCount(stars)} 星）`
      : `${visibleLabel} MenuBarHome on GitHub (${formatStatCount(stars)} stars)`;

  const handlePointerMove = (e: PointerEvent<HTMLAnchorElement>) => {
    if (variant !== 'spotlight' || e.pointerType !== 'mouse') return;
    const el = anchorRef.current;
    const sheen = sheenRef.current;
    if (!el || !sheen) return;
    const rect = el.getBoundingClientRect();
    const x = Math.round(e.clientX - rect.left);
    const y = Math.round(e.clientY - rect.top);
    // Write directly to leaf sheen element — zero React rerender & no parent CSS var inheritance thrash
    sheen.style.setProperty('--star-mx', `${x}px`);
    sheen.style.setProperty('--star-my', `${y}px`);
  };

  const handleClick = () => {
    triggerLocalStar();
    setBurstKey((k) => k + 1);
    playTactileSound('click', useHomeStore.getState().soundEnabled);
    onStarClick?.();
  };

  const variantClasses: Record<FancyStarVariant, string> = {
    nav: 'fancy-star-btn fancy-star-nav min-h-[44px] px-2.5 sm:min-h-0 sm:h-9 sm:px-3.5 text-[13px] font-medium text-[#1e1a16]',
    spotlight:
      'fancy-star-btn fancy-star-spotlight min-h-[48px] px-5 sm:px-6 text-[15px] font-medium tracking-[-0.01em] text-[#fbf9f5]',
    subtle:
      'fancy-star-btn fancy-star-subtle min-h-[44px] sm:min-h-[36px] px-3.5 text-[13px] font-medium text-[#7c380c]',
  };

  const dividerClass =
    variant === 'spotlight'
      ? 'h-4 w-px bg-[#fde68a]/22'
      : variant === 'subtle'
        ? 'h-3.5 w-px bg-[#9a4a12]/22'
        : 'h-3.5 w-px bg-[#1e1a16]/14';

  const countClass =
    variant === 'spotlight'
      ? 'font-mono text-[13.5px] font-medium text-[#fde68a]'
      : variant === 'subtle'
        ? 'font-mono text-[12.5px] font-medium text-[#7c380c]'
        : 'font-mono text-[12.5px] font-medium text-[#3b332b]';

  return (
    <a
      ref={anchorRef}
      href={href}
      target="_blank"
      rel="noreferrer"
      aria-label={accessibleLabel}
      data-starred={starredLocally ? 'true' : 'false'}
      data-variant={variant}
      onPointerMove={handlePointerMove}
      onClick={handleClick}
      className={`${variantClasses[variant]} ${className}`}
    >
      {/* Clipped interior optical effects (pointer sheen + hover sweep) so click sparks can radiate past pill rim */}
      <span aria-hidden="true" className="pointer-events-none absolute inset-0 overflow-hidden rounded-[inherit]">
        {variant === 'spotlight' && (
          <span ref={sheenRef} className="fancy-star-pointer-sheen" />
        )}
        <span className="fancy-star-sweep" />
      </span>

      {/* Content row */}
      <span className="relative z-10 inline-flex items-center gap-2">
        {showGithubIcon && (
          <Github
            className={variant === 'spotlight' ? 'size-4 text-[#e5dccf]' : 'size-3.5 text-current'}
            aria-hidden="true"
          />
        )}

        <span className="relative inline-flex items-center justify-center">
          <Star
            aria-hidden="true"
            className={`fancy-star-icon ${
              variant === 'spotlight' ? 'size-4' : 'size-3.5'
            } ${
              starredLocally
                ? 'fill-[#f59e0b] text-[#f59e0b]'
                : variant === 'spotlight'
                  ? 'fill-[#fbbf24]/25 text-[#fbbf24]'
                  : 'fill-[#f59e0b]/20 text-[#b45309]'
            }`}
          />

          {/* 8-ray geometric golden micro-spark celebration burst on click */}
          {burstKey > 0 && (
            <span key={burstKey} aria-hidden="true" className="fancy-star-burst">
              {SPARK_VECTORS.map((vec, i) => (
                <span
                  key={i}
                  className={
                    vec.shape === 'diamond'
                      ? 'fancy-star-spark fancy-star-spark-diamond'
                      : 'fancy-star-spark fancy-star-spark-dot'
                  }
                  style={
                    {
                      '--sx': vec.sx,
                      '--sy': vec.sy,
                      '--srot': vec.rot,
                      '--sdelay': vec.delay,
                    } as React.CSSProperties
                  }
                />
              ))}
            </span>
          )}
        </span>

        <span
          className={
            variant === 'nav'
              ? 'hidden whitespace-nowrap sm:inline'
              : 'whitespace-nowrap'
          }
        >
          {visibleLabel}
        </span>

        <span aria-hidden="true" className={dividerClass} />

        <RollingStarCount value={stars} className={countClass} />
      </span>
    </a>
  );
}
