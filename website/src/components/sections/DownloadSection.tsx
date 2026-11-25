import { useState, type ReactNode } from 'react';
import { ArrowDownToLine, Check, Copy, Download, ExternalLink, Star, X } from 'lucide-react';
import {
  INSTALL_COMMANDS,
  RELEASE_URLS,
  type Locale,
  type PlatformOS,
  type SiteDictionary,
} from '../../content/siteCopy';
import { formatStatCount, useGitHubStats } from '../../hooks/useGitHubStats';
import { FancyStarButton } from '../shared/FancyStarButton';

interface DownloadSectionProps {
  copy: SiteDictionary['download'];
  os: PlatformOS;
  onChangeOs: (os: PlatformOS) => void;
}

function renderEditorialHeading(text: string): ReactNode {
  const splitPatterns = [', ', '，', ' and ', ' & ', '与', '和'];
  for (const sep of splitPatterns) {
    const idx = text.lastIndexOf(sep);
    if (idx > 0 && idx + sep.length < text.length) {
      const cut = idx + sep.length;
      return (
        <>
          {text.slice(0, cut)}
          <em className="editorial-italic">{text.slice(cut)}</em>
        </>
      );
    }
  }
  const lastSpace = text.lastIndexOf(' ');
  if (lastSpace > 0) {
    return (
      <>
        {text.slice(0, lastSpace + 1)}
        <em className="editorial-italic">{text.slice(lastSpace + 1)}</em>
      </>
    );
  }
  return text;
}

export function DownloadSection({ copy, os, onChangeOs }: DownloadSectionProps) {
  const [copied, setCopied] = useState(false);
  const [showStarNudge, setShowStarNudge] = useState(false);
  const { stars, downloads, isLive } = useGitHubStats();

  const locale: Locale = /[\u4e00-\u9fff]/.test(copy.h2) ? 'zh' : 'en';
  const stats = copy.stats;
  const starInvite = copy.starInvite;
  const commandText = os === 'macos' ? INSTALL_COMMANDS.macos : INSTALL_COMMANDS.windows;

  const handleCopy = async () => {
    setShowStarNudge(true);
    try {
      await navigator.clipboard.writeText(commandText);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      setCopied(false);
    }
  };

  const handleDownloadTrigger = () => {
    setShowStarNudge(true);
  };

  const primaryUrl = os === 'macos' ? RELEASE_URLS.macDmg : RELEASE_URLS.winExe;
  const shaUrl = os === 'macos' ? RELEASE_URLS.macSha256 : RELEASE_URLS.winSha256;
  const sbomUrl = os === 'macos' ? RELEASE_URLS.macSbom : RELEASE_URLS.winSbom;

  return (
    <section
      id="download"
      className="mx-auto w-full max-w-[1080px] px-5 py-12 sm:px-10 sm:py-14"
    >
      <div className="hairline-download rounded-[28px] p-6 sm:p-10">
        {/* Top Split (top-aligned for clean split-pair geometry) */}
        <div className="flex flex-col justify-between gap-7 md:flex-row md:items-start">
          <div className="min-w-0 flex-1 max-w-[32rem]">
            {/* App Mark + Live GitHub Proof Strip */}
            <div className="flex flex-wrap items-center gap-3.5">
              <img
                src="./media/app-icon-256.png"
                alt="MenuBarHome application icon"
                width={56}
                height={56}
                loading="lazy"
                decoding="async"
                className="size-14 rounded-[23%] shadow-sm"
              />

              <div
                data-testid="download-live-stats"
                className="inline-flex flex-wrap items-center gap-x-2.5 gap-y-1 rounded-full bg-[#eee7dc]/85 px-3.5 py-1.5 font-mono text-[13px] font-medium text-[#2b241d] shadow-[inset_0_0_0_1px_rgba(38,30,22,0.09)] tabular-nums"
              >
                <span className="inline-flex items-center gap-1 text-[#8c400e]">
                  <Star className="size-3.5 fill-[#f59e0b] text-[#d97706]" aria-hidden="true" />
                  <span>{formatStatCount(stars)}</span>
                  <span className="text-[#4a433b]">{stats.starsLabel}</span>
                </span>
                <span aria-hidden="true" className="text-[#1e1a16]/25">·</span>
                <span className="inline-flex items-center gap-1">
                  <ArrowDownToLine className="size-3.5 text-[#4a78ab]" aria-hidden="true" />
                  <span>{formatStatCount(downloads)}</span>
                  <span className="text-[#4a433b]">{stats.downloadsLabel}</span>
                </span>
                <span aria-hidden="true" className="hidden text-[#1e1a16]/25 sm:inline">·</span>
                <span className="hidden text-[#4a433b] sm:inline">v1.4.0 · MIT</span>
              </div>
            </div>

            <h2 className="editorial-h2 mt-5">{renderEditorialHeading(copy.h2)}</h2>
            <p className="editorial-lead mt-3 max-w-[44ch]">{copy.lead}</p>

            {/* Platform Switcher Tabs */}
            <div
              role="tablist"
              aria-label="Target operating system"
              className="mt-5 inline-flex rounded-full bg-[#eee7dc] p-1 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.09)]"
            >
              <button
                type="button"
                role="tab"
                aria-selected={os === 'macos'}
                onClick={() => onChangeOs('macos')}
                className={`btn-tactile min-h-[44px] rounded-full px-4 text-[13.5px] font-medium sm:min-h-[38px] ${
                  os === 'macos'
                    ? 'bg-[#1e1a16] text-[#fbf9f5] shadow-xs'
                    : 'text-[#4a433b] hover:text-[#1e1a16]'
                }`}
              >
                {copy.macTab}
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={os === 'windows'}
                onClick={() => onChangeOs('windows')}
                className={`btn-tactile min-h-[44px] rounded-full px-4 text-[13.5px] font-medium sm:min-h-[38px] ${
                  os === 'windows'
                    ? 'bg-[#1e1a16] text-[#fbf9f5] shadow-xs'
                    : 'text-[#4a433b] hover:text-[#1e1a16]'
                }`}
              >
                {copy.winTab}
              </button>
            </div>
          </div>

          {/* Primary Download CTA + Tabular Build Spec Pill */}
          <div className="flex flex-col items-start gap-2.5 md:shrink-0 md:items-end">
            <a
              href={primaryUrl}
              onClick={handleDownloadTrigger}
              className="btn-tactile inline-flex min-h-[48px] items-center gap-2.5 rounded-full bg-[#1e1a16] px-6 text-[15px] font-medium tracking-[-0.01em] text-[#fbf9f5] shadow-[0_1px_1px_rgba(30,26,22,0.25),0_12px_28px_-10px_rgba(30,26,22,0.42)] hover:bg-[#312b25]"
            >
              <Download className="size-4" aria-hidden="true" />
              <span>{os === 'macos' ? copy.macCta : copy.winCta}</span>
            </a>

            <div className="metric-mono md:whitespace-nowrap">
              {os === 'macos' ? copy.macSize : copy.winSize}
            </div>

            {os === 'windows' && (
              <a
                href={RELEASE_URLS.winMsi}
                onClick={handleDownloadTrigger}
                className="editorial-link inline-flex min-h-[44px] items-center gap-1.5 text-[13.5px] font-medium text-[#2b241d] sm:min-h-[36px]"
              >
                <span>{copy.winMsiLink}</span>
                <ExternalLink className="size-3.5" aria-hidden="true" />
              </a>
            )}
          </div>
        </div>

        {/* High-Contrast Dark Espresso Terminal Install / Verify Well */}
        <div className="hairline-terminal-warm mt-7 overflow-hidden rounded-2xl">
          <div className="flex min-h-[48px] items-center justify-between gap-3 border-b border-white/[0.07] bg-white/[0.035] px-4 py-2.5">
            <div className="flex min-w-0 flex-1 items-center gap-3">
              <span className="hidden shrink-0 items-center gap-1.5 sm:inline-flex" aria-hidden="true">
                <span className="size-2.5 rounded-full bg-white/[0.16]" />
                <span className="size-2.5 rounded-full bg-white/[0.16]" />
                <span className="size-2.5 rounded-full bg-white/[0.16]" />
              </span>
              <span className="min-w-0 flex-1 font-mono text-[13px] leading-snug text-[#ded6ca] text-pretty">
                {os === 'macos' ? copy.terminalHeaderMac : copy.terminalHeaderWin}
              </span>
            </div>
            <button
              type="button"
              onClick={handleCopy}
              aria-live="polite"
              className="btn-tactile inline-flex min-h-[44px] min-w-[78px] shrink-0 items-center justify-center gap-1.5 rounded-full bg-white/[0.11] px-3.5 font-mono text-[12.5px] font-medium text-[#f6f2eb] hover:bg-white/[0.2] sm:min-h-[34px]"
            >
              {copied ? (
                <>
                  <Check className="size-3.5 text-[#4ade80]" aria-hidden="true" />
                  <span>{copy.copied}</span>
                </>
              ) : (
                <>
                  <Copy className="size-3.5" aria-hidden="true" />
                  <span>{copy.copy}</span>
                </>
              )}
            </button>
          </div>
          <pre className="px-4 py-4 font-mono text-[13.5px] leading-[1.75] text-[#f2ece2] whitespace-pre-wrap break-all sm:px-5">
            <code>{commandText}</code>
          </pre>
        </div>

        {/* Calm Non-Blocking Post-Download / Post-Copy Inline Star Nudge */}
        {showStarNudge && (
          <div
            role="status"
            data-testid="post-action-star-nudge"
            className="star-nudge-enter mt-4 flex flex-wrap items-center justify-between gap-3 rounded-2xl bg-[#f5ede0] px-4 py-3 shadow-[inset_0_0_0_1px_rgba(154,74,18,0.22)]"
          >
            <div className="flex min-w-0 flex-1 items-center gap-2.5">
              <Star className="size-4 shrink-0 fill-[#f59e0b] text-[#d97706]" aria-hidden="true" />
              <p className="text-[14px] leading-snug font-medium text-[#2b241d] text-pretty">
                {starInvite.postDownloadNudge}
              </p>
            </div>

            <div className="flex shrink-0 items-center gap-2">
              <FancyStarButton
                variant="subtle"
                locale={locale}
                label={starInvite.cta}
                starredLabel={starInvite.ctaStarred}
              />
              <button
                type="button"
                onClick={() => setShowStarNudge(false)}
                aria-label={locale === 'zh' ? '关闭提示' : 'Dismiss reminder'}
                className="btn-tactile inline-flex size-11 items-center justify-center rounded-full text-[#5b5349] hover:bg-[#1e1a16]/[0.07] hover:text-[#1e1a16] sm:size-9"
              >
                <X className="size-4" aria-hidden="true" />
              </button>
            </div>
          </div>
        )}

        {/* Honest Signing & Supply-Chain Integrity Notes */}
        <div className="mt-5 space-y-3 text-[14.5px] leading-[1.62] text-[#4a433b]">
          <p className="max-w-[68ch] text-pretty">
            {os === 'macos' ? copy.signingMac : copy.signingWin}
          </p>

          <div className="flex flex-col justify-between gap-3 border-t border-[#1e1a16]/[0.08] pt-3.5 sm:flex-row sm:flex-wrap sm:items-center">
            <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[13.5px] text-[#4a433b] tabular-nums">
              <span>{copy.verifyPrefix}</span>
              <a
                href={shaUrl}
                target="_blank"
                rel="noreferrer"
                className="editorial-link inline-flex min-h-[44px] items-center font-mono text-[13px] font-medium text-[#1e1a16] sm:min-h-[32px]"
              >
                {copy.shaLink}
              </a>
              <a
                href={sbomUrl}
                target="_blank"
                rel="noreferrer"
                className="editorial-link inline-flex min-h-[44px] items-center font-mono text-[13px] font-medium text-[#1e1a16] sm:min-h-[32px]"
              >
                {copy.sbomLink}
              </a>
            </div>

            <div className="metric-mono metric-mono-accent">{copy.footprintNote}</div>
          </div>
        </div>
      </div>

      {/* Sculptural Warm Dark-Espresso Editorial GitHub Star Invitation Card */}
      <div
        data-dark-surface="true"
        data-testid="star-invite-card"
        className="hairline-star-card mt-6 overflow-hidden rounded-[26px] px-6 py-7 sm:px-10 sm:py-8"
      >
        <div className="flex flex-col justify-between gap-6 md:flex-row md:items-center">
          <div className="min-w-0 max-w-[34rem]">
            <div className="inline-flex items-center gap-2 font-mono text-[13px] font-medium tracking-[0.03em] text-[#fbbf24]">
              <span className="size-1.5 rounded-full bg-[#f59e0b]" aria-hidden="true" />
              <span>{starInvite.eyebrow}</span>
            </div>

            <p className="font-editorial mt-2.5 text-[clamp(26px,3vw,36px)] leading-[1.12] tracking-[-0.02em] text-[#fbf9f5]">
              {starInvite.titlePrefix}
              <em className="editorial-italic-gold">{starInvite.titleAccent}</em>
            </p>

            <p className="mt-2.5 max-w-[46ch] text-[15px] leading-[1.6] text-[#d6cec2] text-pretty">
              {starInvite.body}
            </p>
          </div>

          <div className="flex flex-col items-start gap-2.5 md:shrink-0 md:items-end">
            <FancyStarButton
              variant="spotlight"
              locale={locale}
              label={starInvite.cta}
              starredLabel={starInvite.ctaStarred}
            />

            <div className="inline-flex flex-wrap items-center gap-x-2 gap-y-0.5 font-mono text-[13px] text-[#c7beb1] tabular-nums">
              <span>
                ★ {formatStatCount(stars)} {stats.starsLabel}
              </span>
              <span aria-hidden="true" className="text-[#9c9388]">·</span>
              <span>
                ↓ {formatStatCount(downloads)} {stats.downloadsLabel}
              </span>
              {isLive && (
                <>
                  <span aria-hidden="true" className="text-[#9c9388]">·</span>
                  <span className="text-[#fbbf24]/90">{stats.liveLabel}</span>
                </>
              )}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
