import { RELEASE_URLS, type SiteDictionary } from '../../content/siteCopy';

interface FooterSectionProps {
  copy: SiteDictionary['footer'];
}

export function FooterSection({ copy }: FooterSectionProps) {
  return (
    <footer className="mt-6 border-t border-[#1e1a16]/[0.09]">
      <div className="mx-auto w-full max-w-[1080px] px-5 py-10 sm:px-10 sm:py-12">
        <div className="flex flex-col justify-between gap-4 md:flex-row md:items-center">
          <div className="flex items-center gap-2 font-mono text-[13px] text-[#4a433b] tabular-nums md:shrink-0 md:whitespace-nowrap">
            <img
              src="./media/logo-dark.svg"
              alt=""
              width={20}
              height={20}
              loading="lazy"
              decoding="async"
              className="size-5 shrink-0 rounded-[23%]"
            />
            <span>{copy.meta}</span>
          </div>

          <nav
            aria-label="Footer"
            className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[13.5px] lg:flex-nowrap lg:gap-x-5"
          >
            <a
              href={RELEASE_URLS.repo}
              target="_blank"
              rel="noreferrer"
              className="inline-flex min-h-[44px] items-center whitespace-nowrap text-[#4a433b] underline-offset-4 transition-colors hover:text-[#9a4a12] hover:underline hover:decoration-[#9a4a12]/50 sm:min-h-[36px]"
            >
              {copy.links.github}
            </a>
            <a
              href={RELEASE_URLS.devicesDoc}
              target="_blank"
              rel="noreferrer"
              className="inline-flex min-h-[44px] items-center whitespace-nowrap text-[#4a433b] underline-offset-4 transition-colors hover:text-[#9a4a12] hover:underline hover:decoration-[#9a4a12]/50 sm:min-h-[36px]"
            >
              {copy.links.devices}
            </a>
            <a
              href={RELEASE_URLS.faqDoc}
              target="_blank"
              rel="noreferrer"
              className="inline-flex min-h-[44px] items-center whitespace-nowrap text-[#4a433b] underline-offset-4 transition-colors hover:text-[#9a4a12] hover:underline hover:decoration-[#9a4a12]/50 sm:min-h-[36px]"
            >
              {copy.links.faq}
            </a>
            <a
              href={RELEASE_URLS.securityDoc}
              target="_blank"
              rel="noreferrer"
              className="inline-flex min-h-[44px] items-center whitespace-nowrap text-[#4a433b] underline-offset-4 transition-colors hover:text-[#9a4a12] hover:underline hover:decoration-[#9a4a12]/50 sm:min-h-[36px]"
            >
              {copy.links.security}
            </a>
            <a
              href={RELEASE_URLS.zhReadme}
              target="_blank"
              rel="noreferrer"
              className="inline-flex min-h-[44px] items-center whitespace-nowrap text-[#4a433b] underline-offset-4 transition-colors hover:text-[#9a4a12] hover:underline hover:decoration-[#9a4a12]/50 sm:min-h-[36px]"
            >
              {copy.links.zhReadme}
            </a>
          </nav>
        </div>

        {/* Editorial Serif Colophon Wordmark + Copyright */}
        <div className="relative mt-8 flex flex-col items-center justify-center py-3 text-center">
          <span
            aria-hidden="true"
            className="font-editorial pointer-events-none select-none text-[clamp(40px,6.8vw,74px)] leading-[1] tracking-[-0.025em] text-[#dfd5c5]"
          >
            MenuBar<em className="italic">Home</em>
          </span>
          <p className="mt-1.5 font-mono text-[13px] text-[#5b5349] tabular-nums">
            {copy.copyright}
          </p>
        </div>
      </div>
    </footer>
  );
}
