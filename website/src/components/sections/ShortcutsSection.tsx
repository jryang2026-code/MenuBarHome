import type { ReactNode } from 'react';
import { Command, Cpu, Terminal, Workflow } from 'lucide-react';
import type { PlatformOS, SiteDictionary } from '../../content/siteCopy';

interface ShortcutsSectionProps {
  copy: SiteDictionary['shortcuts'];
  os: PlatformOS;
}

const ECO_ICONS = [Command, Terminal, Workflow, Cpu] as const;

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

export function ShortcutsSection({ copy, os }: ShortcutsSectionProps) {
  return (
    <section
      id="shortcuts"
      className="mx-auto w-full max-w-[1080px] px-5 py-14 sm:px-10 sm:py-16"
    >
      <div className="max-w-[38rem]">
        <h2 className="editorial-h2">{renderEditorialHeading(copy.h2)}</h2>
        <p className="editorial-lead mt-3">{copy.lead}</p>
      </div>

      {/* 2-Column Warm Hairline Shortcut Reference Sheet */}
      <dl className="mt-8 grid grid-cols-1 gap-x-10 border-t border-[#1e1a16]/[0.10] md:grid-cols-2">
        {copy.items.map((item) => {
          const keys = os === 'macos' ? item.macKeys : item.winKeys;
          const label = os === 'windows' && item.winLabel ? item.winLabel : item.label;
          return (
            <div
              key={item.label}
              className="flex min-h-[50px] items-center justify-between gap-4 border-b border-[#1e1a16]/[0.085] py-2.5 transition-colors duration-150 hover:bg-[#eee7dc]/40"
            >
              <dt className="text-[15px] leading-[1.45] font-normal text-[#2b241d]">
                {label}
              </dt>
              <dd className="flex shrink-0 items-center gap-1.5">
                {keys.map((k, idx) =>
                  k === '…' ? (
                    <span key={idx} className="px-0.5 font-mono text-[13px] text-[#665e54]">
                      …
                    </span>
                  ) : (
                    <kbd key={`${k}-${idx}`} className="kbd-cap-warm">
                      {k}
                    </kbd>
                  )
                )}
                {item.note && (
                  <>
                    <span className="font-mono text-[12px] text-[#665e54]">/</span>
                    <kbd className="kbd-cap-warm">{item.note}</kbd>
                  </>
                )}
              </dd>
            </div>
          );
        })}
      </dl>

      {/* Companion Ecosystem Strip aligned strictly to gap-x-10 2-col grid */}
      <div className="mt-9">
        <div className="editorial-eyebrow mb-3">{copy.ecosystemLabel}</div>
        <div
          data-ui="true"
          className="grid grid-cols-1 gap-x-10 gap-y-3 md:grid-cols-2"
        >
          {copy.ecosystemItems.map((eco, idx) => {
            const Icon = ECO_ICONS[idx % ECO_ICONS.length];
            return (
              <div
                key={eco.name}
                className="hairline-paper editorial-card-hover flex items-center gap-3.5 rounded-2xl px-4 py-3"
              >
                <span className="flex size-8.5 shrink-0 items-center justify-center rounded-xl bg-[#eee7dc] text-[#9a4a12] shadow-[inset_0_0_0_1px_rgba(38,30,22,0.08)]">
                  <Icon className="size-4" aria-hidden="true" />
                </span>
                <div className="min-w-0">
                  <div className="text-[14.5px] font-semibold tracking-[-0.015em] text-[#1e1a16]">
                    {eco.name}
                  </div>
                  <div className="mt-0.5 font-mono text-[13px] text-[#4a433b] tabular-nums">
                    {eco.detail}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
