import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
} from 'react';
import {
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  Camera,
  Check,
  ChevronRight,
  Crosshair,
  KeyRound,
  LampDesk,
  Lightbulb,
  Maximize2,
  Mic,
  Monitor,
  Pause,
  Pin,
  Play,
  PlugZap,
  RotateCcw,
  Search,
  ShieldCheck,
  Video,
  VolumeX,
  Wifi,
  X,
} from 'lucide-react';
import type {
  CameraSpotlightCopy,
  Locale,
  PlatformOS,
  SiteDictionary,
} from '../../content/siteCopy';
import { useHomeStore } from '../../store/homeStore';
import { useUkClock } from '../../hooks/useUkClock';
import { handleTablistKeyDown } from '../../utils/tablist';

interface FeaturesSectionProps {
  copy: SiteDictionary['features'];
  locale: Locale;
  os: PlatformOS;
  reducedMotion: boolean;
}

type CameraViewMode = 'live' | 'pip' | 'wall';
const CAMERA_VIEW_MODES: readonly CameraViewMode[] = ['live', 'pip', 'wall'];
type CameraLens = 'wide' | 'tele';

interface CameraSceneFeedProps {
  pan: number;
  tilt: number;
  lens: CameraLens;
  porchLightOn: boolean;
  deskLampOn: boolean;
  activeZone: string;
  compact?: boolean;
  showZoneTag?: boolean;
}

/** Architectural golden-hour entryway / porch camera feed rendered with clean geometry (no doodles) */
function CameraSceneFeed({
  pan,
  tilt,
  lens,
  porchLightOn,
  deskLampOn,
  activeZone,
  compact = false,
  showZoneTag = true,
}: CameraSceneFeedProps) {
  const scale = lens === 'tele' ? 1.62 : 1.08;
  const tx = -pan * (lens === 'tele' ? 0.52 : 0.34);
  const ty = -tilt * (lens === 'tele' ? 0.45 : 0.3);

  return (
    <div
      className="relative h-full w-full overflow-hidden bg-[#141210]"
      style={{
        background:
          'radial-gradient(82% 72% at 72% 28%, rgba(235, 148, 62, 0.24) 0%, rgba(28, 23, 19, 0.96) 66%, #110f0d 100%)',
      }}
    >
      {/* Pan / Tilt / Lens optical transform stage */}
      <div
        className="absolute inset-0 transition-transform duration-200 ease-out will-change-transform"
        style={{
          transform: `translate3d(${tx}%, ${ty}%, 0) scale(${scale})`,
        }}
      >
        {/* Warm golden-hour exterior sky horizon strip */}
        <div
          className="absolute inset-x-0 top-0 h-[44%]"
          style={{
            background:
              'linear-gradient(180deg, rgba(64, 78, 102, 0.45) 0%, rgba(217, 134, 62, 0.34) 72%, rgba(245, 177, 94, 0.16) 100%)',
          }}
        />

        {/* Architectural plaster wall & slatted timber entry door */}
        <div
          className="absolute top-[10%] left-[8%] h-[78%] w-[36%] rounded-t-[4px] border border-white/10"
          style={{
            background:
              'linear-gradient(160deg, rgba(62, 54, 46, 0.92) 0%, rgba(36, 31, 26, 0.96) 100%)',
          }}
        >
          {/* Recessed oak door panel */}
          <div
            className="absolute top-[14%] right-[16%] bottom-0 left-[16%] rounded-t-[3px] border border-amber-200/12"
            style={{
              background:
                'linear-gradient(180deg, rgba(132, 97, 64, 0.48) 0%, rgba(74, 53, 35, 0.72) 100%)',
            }}
          >
            {/* Vertical architectural glass sidelight */}
            <div
              className="absolute top-[10%] right-[14%] h-[68%] w-[16%] rounded-[1px] transition-opacity duration-300"
              style={{
                background: deskLampOn
                  ? 'linear-gradient(180deg, rgba(255, 206, 132, 0.65) 0%, rgba(245, 158, 11, 0.32) 100%)'
                  : 'linear-gradient(180deg, rgba(130, 152, 178, 0.25) 0%, rgba(62, 74, 92, 0.18) 100%)',
                boxShadow: deskLampOn ? '0 0 18px rgba(245, 158, 11, 0.35)' : 'none',
              }}
            />
            {/* Brushed metal lever handle */}
            <div className="absolute top-[52%] left-[16%] h-[3px] w-[18%] rounded-full bg-amber-100/45" />
          </div>

          {/* Architectural porch sconce light */}
          <div
            className="absolute top-[22%] right-[-10px] h-6 w-3 rounded-[2px] border border-white/20 transition-all duration-300"
            style={{
              backgroundColor: porchLightOn ? '#ffd79a' : '#3a342e',
              boxShadow: porchLightOn
                ? '0 0 28px 10px rgba(255, 184, 77, 0.45)'
                : 'none',
            }}
          />
        </div>

        {/* Porch overhang beam & architectural sunset columns */}
        <div className="absolute inset-x-0 top-0 h-[12%] border-b border-white/10 bg-[#181512]/90" />
        <div
          className="absolute top-[12%] right-[14%] h-[76%] w-[24%] border-x border-white/8"
          style={{
            background:
              'linear-gradient(180deg, rgba(255, 190, 118, 0.18) 0%, rgba(217, 119, 6, 0.08) 54%, rgba(20, 17, 14, 0.55) 100%)',
          }}
        >
          {/* Low architectural glass balustrade */}
          <div className="absolute inset-x-0 bottom-[22%] h-[32%] border-y border-white/15 bg-white/[0.04]" />
        </div>

        {/* Concrete entry floor plane with sunset diagonal light bar & parcel silhouette */}
        <div
          className="absolute inset-x-0 bottom-0 h-[26%] border-t border-white/10"
          style={{
            background:
              'linear-gradient(180deg, rgba(44, 39, 34, 0.94) 0%, rgba(22, 19, 16, 0.98) 100%)',
          }}
        >
          {/* Warm sunset floor reflection */}
          <div
            className="absolute top-0 right-[12%] h-full w-[42%] transition-opacity duration-300"
            style={{
              opacity: porchLightOn ? 0.85 : 0.42,
              background:
                'linear-gradient(110deg, transparent 8%, rgba(245, 168, 86, 0.24) 44%, rgba(255, 206, 132, 0.12) 72%, transparent 94%)',
            }}
          />

          {/* Compact delivery parcel box by threshold */}
          <div
            className="absolute bottom-[28%] left-[47%] h-[34%] w-[11%] rounded-[2px] border border-amber-100/20"
            style={{
              background:
                'linear-gradient(150deg, rgba(168, 128, 86, 0.72) 0%, rgba(108, 79, 52, 0.85) 100%)',
            }}
          />
        </div>

        {/* Dynamic warm porch light wash overlay */}
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 transition-opacity duration-300"
          style={{
            opacity: porchLightOn ? 1 : 0.12,
            background:
              'radial-gradient(54% 62% at 44% 34%, rgba(255, 191, 96, 0.26) 0%, rgba(245, 158, 11, 0.08) 46%, transparent 74%)',
          }}
        />
      </div>

      {/* Subtle lens optical vignette & viewfinder corner guides */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0"
        style={{
          background:
            'radial-gradient(90% 85% at 50% 48%, transparent 55%, rgba(10, 8, 6, 0.56) 100%)',
        }}
      />

      {!compact && (
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 flex items-center justify-center"
        >
          <div className="relative flex size-14 items-center justify-center">
            <span className="absolute top-0 left-0 h-2.5 w-2.5 border-t border-l border-white/35" />
            <span className="absolute top-0 right-0 h-2.5 w-2.5 border-t border-r border-white/35" />
            <span className="absolute bottom-0 left-0 h-2.5 w-2.5 border-b border-l border-white/35" />
            <span className="absolute right-0 bottom-0 h-2.5 w-2.5 border-r border-b border-white/35" />
            <span className="size-1 rounded-full bg-[#60cdff]/85" />
          </div>
        </div>
      )}

      {/* Subtle active zone tag inside optical stage (hidden on <640px and preview card to prevent pill overlap) */}
      {!compact && showZoneTag && (
        <div className="pointer-events-none absolute bottom-12 left-3 hidden rounded-full bg-black/55 px-2.5 py-0.5 font-mono text-[10.5px] whitespace-nowrap text-[#e7dfd3] backdrop-blur-xs sm:inline-flex">
          {activeZone} · {lens === 'tele' ? '78mm 3×' : '26mm 1×'}
        </div>
      )}
    </div>
  );
}

/** Interactive Live Camera & Doorbell PiP Studio Dialog */
function LiveCameraModal({
  copy,
  locale,
  onClose,
}: {
  copy: CameraSpotlightCopy;
  locale: Locale;
  onClose: () => void;
}) {
  const [viewMode, setViewMode] = useState<CameraViewMode>('live');
  const [lens, setLens] = useState<CameraLens>('wide');
  const [pan, setPan] = useState(0);
  const [tilt, setTilt] = useState(0);
  const [dragging, setDragging] = useState(false);
  const [porchLightOn, setPorchLightOn] = useState(true);
  const [activeEventIdx, setActiveEventIdx] = useState(0);
  const clock = useUkClock();

  const lampOn = useHomeStore((s) => s.lampOn);
  const toggleLamp = useHomeStore((s) => s.toggleLamp);

  const dragOriginRef = useRef<{ x: number; y: number; pan: number; tilt: number } | null>(null);
  const closeBtnRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    closeBtnRef.current?.focus();
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        onClose();
      } else if (e.key === 'ArrowLeft') {
        setPan((p) => Math.max(-32, p - 8));
      } else if (e.key === 'ArrowRight') {
        setPan((p) => Math.min(32, p + 8));
      } else if (e.key === 'ArrowUp') {
        setTilt((t) => Math.max(-18, t - 6));
      } else if (e.key === 'ArrowDown') {
        setTilt((t) => Math.min(18, t + 6));
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [onClose]);

  const stepPanTilt = useCallback((dp: number, dt: number) => {
    setPan((p) => Math.max(-32, Math.min(32, p + dp)));
    setTilt((t) => Math.max(-18, Math.min(18, t + dt)));
  }, []);

  const handlePointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (viewMode === 'wall') return;
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {
      // Ignore synthetic events
    }
    setDragging(true);
    dragOriginRef.current = { x: e.clientX, y: e.clientY, pan, tilt };
  };

  const handlePointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!dragging || !dragOriginRef.current) return;
    const dx = e.clientX - dragOriginRef.current.x;
    const dy = e.clientY - dragOriginRef.current.y;
    setPan(Math.max(-32, Math.min(32, Math.round(dragOriginRef.current.pan + dx * 0.24))));
    setTilt(Math.max(-18, Math.min(18, Math.round(dragOriginRef.current.tilt + dy * 0.18))));
  };

  const handlePointerUp = () => {
    setDragging(false);
    dragOriginRef.current = null;
  };

  const activeEvent = copy.events[activeEventIdx] ?? copy.events[0];

  const wallFeeds = [
    {
      name: locale === 'zh' ? '前门门铃 · 3:4' : 'Front Doorbell',
      status: 'go2rtc · 1080p',
      pan: 0,
      tilt: 0,
    },
    {
      name: locale === 'zh' ? '书房云台摄像机' : 'Study PTZ Cam',
      status: 'LAN · fMP4',
      pan: 18,
      tilt: -6,
    },
    {
      name: locale === 'zh' ? '入户门廊广角' : 'Entry Porch Wide',
      status: '26mm · 1×',
      pan: -16,
      tilt: 5,
    },
    {
      name: locale === 'zh' ? '南向阳台视角' : 'South Balcony',
      status: 'HDR · Sunset',
      pan: 22,
      tilt: 8,
    },
  ];

  const selectEvent = (idx: number) => {
    setActiveEventIdx(idx);
    setViewMode('live');
    if (idx === 0) {
      setPan(0);
      setTilt(0);
      setLens('wide');
    } else if (idx === 1) {
      setPan(18);
      setTilt(-6);
      setLens('wide');
    } else {
      setPan(-10);
      setTilt(12);
      setLens('tele');
    }
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="mbh-camera-dialog-title"
      data-ui="true"
      className="fixed inset-0 z-50 flex items-center justify-center bg-[#181410]/65 p-3 backdrop-blur-md sm:p-6"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="max-h-[92svh] w-full max-w-[920px] overflow-y-auto rounded-[24px] bg-[#fbf9f5] p-4 text-[#1e1a16] shadow-[0_32px_80px_-20px_rgba(20,14,8,0.6),inset_0_0_0_1px_rgba(38,30,22,0.12)] sm:p-6">
        {/* Modal Header: single unbroken row on md+, Close X always pinned top-right on every viewport */}
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-[#1e1a16]/10 pb-4 md:flex-nowrap">
          <div className="flex min-w-0 flex-1 items-center gap-3">
            <span className="flex size-10 shrink-0 items-center justify-center rounded-full bg-[#009eff] text-white shadow-[0_6px_16px_-4px_rgba(0,158,255,0.5)]">
              <Video className="size-5" aria-hidden="true" />
            </span>
            <div className="min-w-0">
              <h3
                id="mbh-camera-dialog-title"
                className="truncate text-[18px] leading-[1.3] font-semibold tracking-[-0.015em] text-[#1e1a16]"
              >
                {copy.modalTitle}
              </h3>
              <p className="mt-0.5 truncate font-mono text-[12px] text-[#5b5349]">
                {copy.modalSubtitle}
              </p>
            </div>
          </div>

          {/* View Mode Segmented Switch (row 2 on mobile, inline on md+) */}
          <div
            role="tablist"
            aria-label={locale === 'zh' ? '画面模式' : 'Camera view mode'}
            onKeyDown={(e) => handleTablistKeyDown(e, CAMERA_VIEW_MODES, viewMode, setViewMode)}
            className="order-3 inline-flex w-full justify-between overflow-x-auto rounded-full bg-[#eee7dc] p-1 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.08)] md:order-2 md:w-auto md:shrink-0 md:justify-start"
          >
            {(
              [
                { id: 'live', label: copy.modeLive },
                { id: 'pip', label: copy.modePip },
                { id: 'wall', label: copy.modeWall },
              ] as const
            ).map((tab) => (
              <button
                key={tab.id}
                type="button"
                role="tab"
                id={`camera-mode-tab-${tab.id}`}
                aria-controls="camera-mode-panel"
                aria-selected={viewMode === tab.id}
                tabIndex={viewMode === tab.id ? 0 : -1}
                onClick={() => setViewMode(tab.id)}
                className={`btn-tactile flex-1 shrink-0 rounded-full px-3 py-1 text-[12px] font-medium whitespace-nowrap md:flex-none ${
                  viewMode === tab.id
                    ? 'bg-[#1e1a16] text-[#fbf9f5]'
                    : 'text-[#4a433b] hover:text-[#1e1a16]'
                }`}
              >
                {tab.label}
              </button>
            ))}
          </div>

          <button
            ref={closeBtnRef}
            type="button"
            onClick={onClose}
            aria-label={copy.closeLabel}
            className="btn-tactile order-2 inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-[#eee7dc] text-[#1e1a16] hover:bg-[#e2d8c9] md:order-3"
          >
            <X className="size-4" aria-hidden="true" />
          </button>
        </div>

        {/* Main Studio Grid */}
        <div className="mt-4 grid grid-cols-1 gap-5 lg:grid-cols-12">
          {/* Interactive Live Feed / PiP / 2x2 Wall */}
          <div
            id="camera-mode-panel"
            role="tabpanel"
            aria-labelledby={`camera-mode-tab-${viewMode}`}
            className="lg:col-span-8"
          >
            {viewMode === 'wall' ? (
              <div className="grid grid-cols-2 gap-2.5 rounded-[18px] bg-[#161310] p-2.5">
                {wallFeeds.map((feed) => (
                  <button
                    key={feed.name}
                    type="button"
                    onClick={() => {
                      setPan(feed.pan);
                      setTilt(feed.tilt);
                      setViewMode('live');
                    }}
                    className="group relative aspect-[16/10] overflow-hidden rounded-[12px] border border-white/10 text-left transition-colors hover:border-[#009eff]/70"
                  >
                    <CameraSceneFeed
                      pan={feed.pan}
                      tilt={feed.tilt}
                      lens="wide"
                      porchLightOn={porchLightOn}
                      deskLampOn={lampOn}
                      activeZone={feed.name}
                      compact
                    />
                    <div className="absolute inset-x-2 bottom-2 flex items-center justify-between rounded-full bg-black/65 px-2.5 py-1 text-[11px] text-[#f6f2eb] backdrop-blur-xs">
                      <span className="truncate font-medium">{feed.name}</span>
                      <span className="font-mono text-[10px] text-[#c7beb1]">{feed.status}</span>
                    </div>
                  </button>
                ))}
              </div>
            ) : (
              <div className="flex flex-col items-center">
                <div
                  onPointerDown={handlePointerDown}
                  onPointerMove={handlePointerMove}
                  onPointerUp={handlePointerUp}
                  onPointerCancel={handlePointerUp}
                  className={`relative w-full overflow-hidden rounded-[18px] border border-[#1e1a16]/15 bg-[#141210] select-none ${
                    viewMode === 'pip'
                      ? 'aspect-[3/4] max-w-[310px] shadow-[0_24px_48px_-16px_rgba(24,18,12,0.5)]'
                      : 'aspect-[16/10]'
                  } ${dragging ? 'cursor-grabbing' : 'cursor-grab'}`}
                  style={{ touchAction: 'none' }}
                >
                  <CameraSceneFeed
                    pan={pan}
                    tilt={tilt}
                    lens={lens}
                    porchLightOn={porchLightOn}
                    deskLampOn={lampOn}
                    activeZone={activeEvent.zone}
                  />

                  {/* Top Camera Telemetry HUD */}
                  <div className="pointer-events-none absolute top-3 right-3 left-3 flex flex-wrap items-center justify-between gap-2">
                    <div className="inline-flex items-center gap-1.5 rounded-full bg-black/65 px-2.5 py-1 font-mono text-[11px] text-[#f6f2eb] backdrop-blur-xs">
                      <span className="size-2 rounded-full bg-[#22c55e]" />
                      <span className="font-semibold text-white">{copy.liveBadge}</span>
                      <span className="text-[#c7beb1]">· {copy.loopbackBadge}</span>
                    </div>

                    <div className="inline-flex items-center gap-1.5 rounded-full bg-black/65 px-2.5 py-1 font-mono text-[11px] text-[#f5cfa0] backdrop-blur-xs">
                      <VolumeX className="size-3" aria-hidden="true" />
                      <span>{copy.videoOnlyBadge}</span>
                    </div>
                  </div>

                  {/* Bottom Interactive Controls inside Camera Frame */}
                  <div
                    className="absolute right-3 bottom-3 left-3 flex flex-wrap items-center justify-between gap-2"
                    onPointerDown={(e) => e.stopPropagation()}
                  >
                    {/* Dual-Lens Toggle */}
                    <div className="inline-flex rounded-full bg-black/70 p-0.5 backdrop-blur-xs">
                      <button
                        type="button"
                        onClick={() => setLens('wide')}
                        aria-pressed={lens === 'wide'}
                        className={`rounded-full px-2.5 py-1 font-mono text-[11px] font-medium transition-colors focus-visible:outline-[#fbbf24] ${
                          lens === 'wide'
                            ? 'bg-white text-[#1e1a16]'
                            : 'text-[#e5ddd2] hover:text-white'
                        }`}
                      >
                        {copy.lensWide}
                      </button>
                      <button
                        type="button"
                        onClick={() => setLens('tele')}
                        aria-pressed={lens === 'tele'}
                        className={`rounded-full px-2.5 py-1 font-mono text-[11px] font-medium transition-colors focus-visible:outline-[#fbbf24] ${
                          lens === 'tele'
                            ? 'bg-white text-[#1e1a16]'
                            : 'text-[#e5ddd2] hover:text-white'
                        }`}
                      >
                        {copy.lensTele}
                      </button>
                    </div>

                    {/* Live PTZ Coordinates + Clock */}
                    <div className="inline-flex items-center gap-2 rounded-full bg-black/70 px-2.5 py-1 font-mono text-[11px] text-[#f6f2eb] tabular-nums backdrop-blur-xs">
                      <span>
                        PAN {pan >= 0 ? `+${pan}` : pan}° · TILT {tilt >= 0 ? `+${tilt}` : tilt}°
                      </span>
                      <span className="text-[#a89f93]">|</span>
                      <span>{clock}</span>
                    </div>
                  </div>
                </div>

                <div className="mt-2.5 flex w-full flex-wrap items-center justify-between gap-2 text-[12px] text-[#5b5349]">
                  <span className="flex items-center gap-1.5">
                    <Crosshair className="size-3.5 text-[#009eff]" aria-hidden="true" />
                    <span>{viewMode === 'pip' ? copy.autoOpenNote : copy.ptzDragHint}</span>
                  </span>
                  <button
                    type="button"
                    onClick={() => {
                      setPan(0);
                      setTilt(0);
                      setLens('wide');
                    }}
                    className="font-mono text-[12px] font-medium text-[#9a4a12] underline decoration-[#9a4a12]/35 underline-offset-4 hover:text-[#7c380c]"
                  >
                    {copy.resetView}
                  </button>
                </div>
              </div>
            )}
          </div>

          {/* Right Controls Column: PTZ Pad + Pinned Switches + 7d Local Event History */}
          <div className="flex flex-col gap-3.5 lg:col-span-4">
            {/* PTZ Arrow Pad */}
            <div className="rounded-[16px] bg-[#eee7dc]/80 p-3.5 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.08)]">
              <div className="mb-2.5 flex items-center justify-between text-[12px] font-semibold text-[#1e1a16]">
                <span>{locale === 'zh' ? 'PTZ 云台方向控制' : 'PTZ Pan & Tilt'}</span>
                <span className="font-mono text-[11px] font-normal text-[#5b5349] tabular-nums">
                  {lens === 'tele' ? '3×' : '1×'}
                </span>
              </div>
              <div className="grid grid-cols-3 gap-1.5">
                <span />
                <button
                  type="button"
                  aria-label={locale === 'zh' ? '云台向上' : 'Tilt camera up'}
                  onClick={() => stepPanTilt(0, -8)}
                  className="btn-tactile flex h-9 items-center justify-center rounded-xl bg-[#fbf9f5] text-[#1e1a16] shadow-[inset_0_0_0_1px_rgba(38,30,22,0.1)] hover:bg-white"
                >
                  <ArrowUp className="size-4" aria-hidden="true" />
                </button>
                <span />
                <button
                  type="button"
                  aria-label={locale === 'zh' ? '云台向左' : 'Pan camera left'}
                  onClick={() => stepPanTilt(-10, 0)}
                  className="btn-tactile flex h-9 items-center justify-center rounded-xl bg-[#fbf9f5] text-[#1e1a16] shadow-[inset_0_0_0_1px_rgba(38,30,22,0.1)] hover:bg-white"
                >
                  <ArrowLeft className="size-4" aria-hidden="true" />
                </button>
                <button
                  type="button"
                  aria-label={copy.resetView}
                  onClick={() => {
                    setPan(0);
                    setTilt(0);
                  }}
                  className="btn-tactile flex h-9 items-center justify-center rounded-xl bg-[#1e1a16] font-mono text-[11px] font-semibold text-[#fbf9f5] hover:bg-[#312b25]"
                >
                  0°
                </button>
                <button
                  type="button"
                  aria-label={locale === 'zh' ? '云台向右' : 'Pan camera right'}
                  onClick={() => stepPanTilt(10, 0)}
                  className="btn-tactile flex h-9 items-center justify-center rounded-xl bg-[#fbf9f5] text-[#1e1a16] shadow-[inset_0_0_0_1px_rgba(38,30,22,0.1)] hover:bg-white"
                >
                  <ArrowRight className="size-4" aria-hidden="true" />
                </button>
                <span />
                <button
                  type="button"
                  aria-label={locale === 'zh' ? '云台向下' : 'Tilt camera down'}
                  onClick={() => stepPanTilt(0, 8)}
                  className="btn-tactile flex h-9 items-center justify-center rounded-xl bg-[#fbf9f5] text-[#1e1a16] shadow-[inset_0_0_0_1px_rgba(38,30,22,0.1)] hover:bg-white"
                >
                  <ArrowDown className="size-4" aria-hidden="true" />
                </button>
                <span />
              </div>
            </div>

            {/* Pinned Quick Switches inside Camera HUD (real MenuBarHome feature: up to 2 switches) */}
            <div className="rounded-[16px] bg-[#eee7dc]/80 p-3.5 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.08)]">
              <div className="mb-2 flex items-center gap-1.5 text-[12px] font-semibold text-[#1e1a16]">
                <Pin className="size-3.5 text-[#9a4a12]" aria-hidden="true" />
                <span>{copy.pinnedSwitchesLabel}</span>
              </div>
              <div className="space-y-1.5">
                <button
                  type="button"
                  aria-pressed={porchLightOn}
                  onClick={() => setPorchLightOn((v) => !v)}
                  className="btn-tactile flex w-full items-center justify-between rounded-xl bg-[#fbf9f5] px-3 py-2 text-left shadow-[inset_0_0_0_1px_rgba(38,30,22,0.08)] hover:bg-white"
                >
                  <span className="flex items-center gap-2 text-[12.5px] font-medium text-[#1e1a16]">
                    <span
                      className="flex size-6 items-center justify-center rounded-full transition-colors"
                      style={{
                        backgroundColor: porchLightOn ? '#ff9500' : 'rgba(38,30,22,0.1)',
                        color: porchLightOn ? '#ffffff' : '#5b5349',
                      }}
                    >
                      <Lightbulb className="size-3.5" aria-hidden="true" />
                    </span>
                    <span>{copy.porchLightLabel}</span>
                  </span>
                  <span className="font-mono text-[11px] font-medium text-[#5b5349]">
                    {porchLightOn ? (locale === 'zh' ? '开启' : 'On') : locale === 'zh' ? '关闭' : 'Off'}
                  </span>
                </button>

                <button
                  type="button"
                  aria-pressed={lampOn}
                  onClick={toggleLamp}
                  className="btn-tactile flex w-full items-center justify-between rounded-xl bg-[#fbf9f5] px-3 py-2 text-left shadow-[inset_0_0_0_1px_rgba(38,30,22,0.08)] hover:bg-white"
                >
                  <span className="flex items-center gap-2 text-[12.5px] font-medium text-[#1e1a16]">
                    <span
                      className="flex size-6 items-center justify-center rounded-full transition-colors"
                      style={{
                        backgroundColor: lampOn ? '#ff9500' : 'rgba(38,30,22,0.1)',
                        color: lampOn ? '#ffffff' : '#5b5349',
                      }}
                    >
                      <LampDesk className="size-3.5" aria-hidden="true" />
                    </span>
                    <span>{copy.deskLampLabel}</span>
                  </span>
                  <span className="font-mono text-[11px] font-medium text-[#5b5349]">
                    {lampOn ? (locale === 'zh' ? '开启' : 'On') : locale === 'zh' ? '关闭' : 'Off'}
                  </span>
                </button>
              </div>
            </div>

            {/* 7-Day / 500-Event Local Event Timeline */}
            <div className="rounded-[16px] bg-[#eee7dc]/80 p-3.5 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.08)]">
              <div className="mb-2 flex items-center justify-between gap-2">
                <span className="truncate text-[12px] font-semibold text-[#1e1a16]">
                  {copy.eventsTitle}
                </span>
                <span className="shrink-0 font-mono text-[10.5px] whitespace-nowrap text-[#5b5349] tabular-nums">
                  {copy.eventsMeta}
                </span>
              </div>
              <div className="space-y-1.5">
                {copy.events.map((ev, idx) => {
                  const selected = idx === activeEventIdx;
                  return (
                    <button
                      key={ev.time}
                      type="button"
                      onClick={() => selectEvent(idx)}
                      className={`flex w-full items-start justify-between gap-2 rounded-xl px-2.5 py-2 text-left transition-colors ${
                        selected
                          ? 'bg-[#fbf9f5] shadow-[inset_0_0_0_1.5px_rgba(0,158,255,0.65)]'
                          : 'bg-[#fbf9f5]/75 hover:bg-[#fbf9f5]'
                      }`}
                    >
                      <div className="min-w-0 leading-snug">
                        <div className="truncate text-[11.5px] font-semibold text-[#1e1a16]">
                          {ev.title}
                        </div>
                        <div className="text-[10.5px] text-[#5b5349]">{ev.zone}</div>
                      </div>
                      <span className="shrink-0 font-mono text-[10.5px] text-[#665e54] tabular-nums">
                        {ev.time}
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

/** Card 1 (Paper): Zero-Hub Mi Home QR Direct + HA Dual-Source Fusion + LAN UDP 54321 */
function BridgeVignette({ locale }: { locale: Locale }) {
  const rows = [
    {
      source: locale === 'zh' ? '米家扫码' : 'Mi Home QR',
      transport: 'cn · sg · de · us · ru · i2',
      route: locale === 'zh' ? '免服务器' : 'Zero hub',
      dot: '#ff9500',
    },
    {
      source: 'Home Assistant',
      transport: 'WebSocket + mDNS',
      route: locale === 'zh' ? '自动去重' : 'Auto-dedup',
      dot: '#4a78ab',
    },
    {
      source: locale === 'zh' ? '局域网直控' : 'LAN miIO',
      transport: 'AES-128 UDP 54321',
      route: locale === 'zh' ? '本地优先' : 'LAN first',
      dot: '#1d9a48',
    },
    {
      source: 'LG webOS TV',
      transport: locale === 'zh' ? '局域网配对' : 'Direct LAN',
      route: locale === 'zh' ? '钥匙串' : 'Keychain',
      dot: '#5957d6',
    },
  ];

  return (
    <div
      data-ui="true"
      className="flex h-full w-full flex-col justify-center bg-[#fbf9f5] p-5 text-[#1e1a16] sm:p-6"
    >
      <div className="space-y-2">
        {rows.map((r) => (
          <div
            key={r.source}
            className="grid grid-cols-[1.05fr_1.35fr_0.65fr] items-center rounded-[11px] bg-[#f4eee4]/80 px-3 py-2.5 text-[11.5px] shadow-[inset_0_0_0_1px_rgba(38,30,22,0.06)]"
          >
            <span className="flex items-center gap-2 font-semibold text-[#1e1a16]">
              <span className="size-2 shrink-0 rounded-full" style={{ backgroundColor: r.dot }} />
              <span className="truncate">{r.source}</span>
            </span>
            <span className="truncate font-mono text-[10.5px] text-[#5b5349]">{r.transport}</span>
            <span className="text-right text-[11px] font-medium text-[#4a433b]">{r.route}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/** Card 2 (Sand): Keyboard-first pinyin search (⌥M -> sftd -> Study Lamp) inside non-activating NSPanel */
function SearchVignette({ active, locale }: { active: boolean; locale: Locale }) {
  const [step, setStep] = useState(2);
  const [manualToggle, setManualToggle] = useState<boolean | null>(null);

  useEffect(() => {
    if (!active || manualToggle !== null) return;
    const id = window.setInterval(() => setStep((s) => (s + 1) % 3), 3000);
    return () => window.clearInterval(id);
  }, [active, manualToggle]);

  const query = step === 0 ? 'sf' : 'sftd';
  const toggledOn = manualToggle !== null ? manualToggle : step === 2;

  return (
    <div
      data-ui="true"
      className="flex h-full w-full flex-col items-center justify-center bg-gradient-to-br from-[#efe8dc] to-[#e6ddce] p-5 sm:p-6"
    >
      <div className="w-full max-w-[336px] space-y-2.5 rounded-[18px] bg-[#fbf9f5] p-4 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.09),0_18px_36px_-22px_rgba(45,32,18,0.26)]">
        <div className="flex items-center justify-between gap-2 rounded-[11px] bg-[#f3ede3] px-3 py-2.5 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.07)]">
          <span className="flex items-center gap-2 text-[13px] text-[#1e1a16]">
            <Search className="size-3.5 text-[#665e54]" aria-hidden="true" />
            <span className="font-mono font-medium">{query}</span>
          </span>
          <span className="kbd-cap-warm !h-5 !px-1.5 !text-[10.5px]">⌥M</span>
        </div>

        <button
          type="button"
          onClick={() => setManualToggle((prev) => !(prev ?? toggledOn))}
          aria-pressed={toggledOn}
          className="btn-tactile flex w-full items-center justify-between rounded-[13px] bg-white p-3 text-left transition-colors duration-200"
          style={{ boxShadow: 'inset 0 0 0 1.5px rgba(217, 119, 6, 0.7)' }}
        >
          <span className="flex items-center gap-2.5">
            <span
              className="flex size-8.5 items-center justify-center rounded-full transition-colors duration-200"
              style={{
                backgroundColor: toggledOn ? '#ff9500' : 'rgba(38,30,22,0.08)',
                color: toggledOn ? '#ffffff' : '#5b5349',
              }}
            >
              <Lightbulb className="size-4" aria-hidden="true" />
            </span>
            <span className="leading-tight">
              <span className="block text-[13px] font-semibold text-[#1e1a16]">
                {locale === 'zh' ? '书房台灯' : 'Mi Desk Lamp 1S'}
              </span>
              <span className="block font-mono text-[11px] text-[#5b5349] tabular-nums">
                {toggledOn ? '68% · 2900K' : locale === 'zh' ? '已关闭' : 'Off'}
              </span>
            </span>
          </span>
          <span className="kbd-cap-warm !h-5 !px-1.5 !text-[10.5px]">↩</span>
        </button>
      </div>
    </div>
  );
}

/** Card 3 (Sand): Hold-to-Talk 0.5s + Offline LocalIntentParser (0 API key) */
function VoiceVignette({ active, locale }: { active: boolean; locale: Locale }) {
  const [phase, setPhase] = useState(1);

  useEffect(() => {
    if (!active) return;
    const id = window.setInterval(() => setPhase((p) => (p + 1) % 3), 3000);
    return () => window.clearInterval(id);
  }, [active]);

  const bars = [12, 22, 30, 18, 28, 34, 20, 14, 24, 16];

  return (
    <div
      data-ui="true"
      className="flex h-full w-full flex-col items-center justify-center gap-3.5 bg-gradient-to-br from-[#efe8dc] to-[#e6ddce] p-5 sm:p-6"
    >
      <div className="flex items-center gap-2 rounded-full bg-[#1e1a16] px-4 py-1.5 shadow-sm">
        <Mic className="size-3.5 text-[#f59e0b]" aria-hidden="true" />
        <span className="text-[12px] font-medium text-[#fbf9f5]">
          {locale === 'zh' ? '按住 ⌥M 说话' : 'Hold ⌥M (0.5s)'}
        </span>
        <div className="ml-1 flex h-5 items-center gap-0.5" aria-hidden="true">
          {bars.map((h, i) => (
            <span
              key={i}
              className="w-[2.5px] rounded-full bg-[#f59e0b] transition-[height,opacity] duration-200"
              style={{
                height: `${phase === 0 ? Math.max(6, Math.round(h * 0.45)) : Math.round(h * 0.6)}px`,
                opacity: phase === 2 ? 0.48 : 0.92,
              }}
            />
          ))}
        </div>
      </div>

      <div className="w-full max-w-[336px] rounded-[16px] bg-[#fbf9f5] p-4 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.09),0_14px_28px_-20px_rgba(45,32,18,0.22)]">
        <div className="text-[13.5px] font-semibold text-[#1e1a16]">
          {locale === 'zh' ? '“把吸顶灯调到 40%”' : '“Set ceiling light to 40%”'}
        </div>
        <div className="mt-3 flex items-center justify-between text-[11.5px] text-[#5b5349]">
          <span className="font-mono font-medium text-[#3b6696]">LocalIntentParser</span>
          <span className="rounded-full bg-[#1d9a48]/12 px-2.5 py-0.5 font-mono text-[11px] font-medium text-[#15803d] tabular-nums">
            {phase === 2 ? '80% → 40%' : locale === 'zh' ? '离线 · 0 API' : 'Offline · 0 API'}
          </span>
        </div>
      </div>
    </div>
  );
}

/** Card 4 (Paper): 23 Desktop Context Triggers + 32-Frame LIFO Restore Stack */
function ContextVignette({ locale }: { locale: Locale }) {
  const [activeIdx, setActiveIdx] = useState(1);

  const rules = [
    {
      icon: Monitor,
      trigger: locale === 'zh' ? '外接显示器连接' : 'Display connected',
      action: locale === 'zh' ? '开启挂灯与台灯' : 'Light Bar + Lamp',
      color: '#d97706',
    },
    {
      icon: Camera,
      trigger: locale === 'zh' ? '摄像头 / 麦克风开启' : 'Camera / mic in use',
      action: locale === 'zh' ? '会议补光 65%' : 'Meeting Fill 65%',
      color: '#009eff',
    },
    {
      icon: Wifi,
      trigger: locale === 'zh' ? '会议结束（LIFO）' : 'Call ends (LIFO)',
      action: locale === 'zh' ? '还原此前灯光' : 'Restore lights',
      color: '#1d9a48',
    },
  ];

  return (
    <div
      data-ui="true"
      className="flex h-full w-full flex-col justify-center bg-[#fbf9f5] p-5 sm:p-6"
    >
      <div className="space-y-2.5">
        {rules.map((r, idx) => {
          const Icon = r.icon;
          const selected = idx === activeIdx;
          return (
            <button
              key={r.trigger}
              type="button"
              onClick={() => setActiveIdx(idx)}
              aria-pressed={selected}
              className={`flex w-full items-center justify-between gap-2 rounded-[12px] px-3.5 py-2.5 text-left transition-colors ${
                selected
                  ? 'bg-white shadow-[inset_0_0_0_1.3px_rgba(154,74,18,0.45)]'
                  : 'bg-[#f4eee4]/80 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.06)] hover:bg-[#f4eee4]'
              }`}
            >
              <span className="flex items-center gap-2.5 text-[12px] font-semibold text-[#1e1a16]">
                <Icon className="size-3.5 shrink-0" style={{ color: r.color }} aria-hidden="true" />
                <span>{r.trigger}</span>
              </span>
              <span className="font-mono text-[11px] text-[#5b5349] tabular-nums">{r.action}</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}

/** Card 5 (Paper): Guarded 0.6s Hold All Off protecting Smart Plug + 15s Undo bar */
function AllOffVignette({ active, locale }: { active: boolean; locale: Locale }) {
  const [off, setOff] = useState(true);
  const [lockedByUser, setLockedByUser] = useState(false);

  useEffect(() => {
    if (!active || lockedByUser) return;
    const id = window.setInterval(() => setOff((v) => !v), 3200);
    return () => window.clearInterval(id);
  }, [active, lockedByUser]);

  return (
    <div
      data-ui="true"
      className="flex h-full w-full items-center justify-center bg-[#fbf9f5] p-5 sm:p-6"
    >
      <div className="w-full max-w-[344px] space-y-3 rounded-[18px] bg-[#f4eee4]/75 p-4 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.08)]">
        <div className="grid grid-cols-2 gap-2.5">
          <div className="flex items-center gap-2 rounded-[12px] bg-[#fbf9f5] p-2.5 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.06)]">
            <span
              className="flex size-7.5 items-center justify-center rounded-full transition-colors duration-200"
              style={{
                backgroundColor: off ? 'rgba(38,30,22,0.09)' : '#ff9500',
                color: off ? '#665e54' : '#ffffff',
              }}
            >
              <Lightbulb className="size-3.5" aria-hidden="true" />
            </span>
            <div className="leading-tight">
              <div className="text-[12px] font-semibold text-[#1e1a16]">
                {locale === 'zh' ? '米家吸顶灯' : 'Ceiling Light'}
              </div>
              <div className="font-mono text-[10.5px] text-[#5b5349]">
                {off ? (locale === 'zh' ? '已关闭' : 'Off') : '46% · 3200K'}
              </div>
            </div>
          </div>

          <div
            className="flex items-center gap-2 rounded-[12px] bg-white p-2.5"
            style={{ boxShadow: 'inset 0 0 0 1.2px rgba(29, 154, 72, 0.5)' }}
          >
            <span className="flex size-7.5 items-center justify-center rounded-full bg-[#1d9a48] text-white">
              <PlugZap className="size-3.5" aria-hidden="true" />
            </span>
            <div className="leading-tight">
              <div className="text-[12px] font-semibold text-[#1e1a16]">
                {locale === 'zh' ? '智能插座' : 'Smart Plug'}
              </div>
              <div className="font-mono text-[10.5px] font-medium text-[#15803d] tabular-nums">
                {locale === 'zh' ? '受保护 · 42W' : 'Protected · 42W'}
              </div>
            </div>
          </div>
        </div>

        <div className="flex items-center justify-between rounded-[12px] bg-[#1e1a16] px-3.5 py-2.5 text-[#fbf9f5]">
          <span className="text-[11.5px] tabular-nums">
            {off
              ? locale === 'zh'
                ? '已关闭 3 台 · 15s'
                : 'Turned off 3 · 15s'
              : locale === 'zh'
                ? '长按 0.6s 触发全关'
                : 'Hold 0.6s for All Off'}
          </span>
          <button
            type="button"
            onClick={() => {
              setLockedByUser(true);
              setOff((v) => !v);
            }}
            className="btn-tactile inline-flex items-center gap-1 rounded-full bg-[#f59e0b] px-2.5 py-0.5 text-[11px] font-semibold text-[#1e1a16] hover:bg-[#fbbf24] focus-visible:outline-[#fbbf24]"
          >
            <RotateCcw className="size-2.5" aria-hidden="true" />
            <span>
              {off ? (locale === 'zh' ? '撤销' : 'Undo') : locale === 'zh' ? '模拟全关' : 'Test Off'}
            </span>
          </button>
        </div>
      </div>
    </div>
  );
}

/** Card 6 (Sand): Pure Native Lightness (1.2% CPU, 0 Swift deps) + Keychain + Local MCP */
function PrivacyVignette({ locale }: { locale: Locale }) {
  const rows = [
    {
      label: locale === 'zh' ? '钥匙串 · ThisDeviceOnly' : 'Keychain · ThisDeviceOnly',
      enabled: true,
    },
    {
      label: locale === 'zh' ? '本地只读 MCP & Raycast' : 'Local MCP (--read-only)',
      enabled: true,
    },
    {
      label: locale === 'zh' ? '遥测埋点与云端中转' : 'Analytics & cloud relay',
      enabled: false,
    },
  ];

  return (
    <div
      data-ui="true"
      className="flex h-full w-full flex-col justify-center bg-gradient-to-br from-[#efe8dc] to-[#e6ddce] p-5 text-[#1e1a16] sm:p-6"
    >
      <div className="rounded-[18px] bg-[#fbf9f5] p-4 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.09)]">
        <div className="mb-3 flex items-center gap-2.5">
          <span className="flex size-7.5 items-center justify-center rounded-[9px] bg-[#4a78ab] text-white">
            <ShieldCheck className="size-4" aria-hidden="true" />
          </span>
          <div className="min-w-0 leading-tight">
            <div className="text-[12.5px] font-semibold text-[#1e1a16]">
              {locale === 'zh' ? 'Swift 6 零依赖 · Tauri v2' : 'Swift 6 · 0 third-party deps'}
            </div>
            <div className="font-mono text-[10.5px] text-[#5b5349] tabular-nums">
              1.2% CPU · 112–113 MB · Ed25519
            </div>
          </div>
        </div>

        <div className="space-y-2">
          {rows.map((item) => (
            <div
              key={item.label}
              className="flex items-center justify-between gap-2 rounded-[10px] bg-[#f4eee4]/80 px-3 py-2 shadow-[inset_0_0_0_1px_rgba(38,30,22,0.05)]"
            >
              <span className="flex min-w-0 items-center gap-2 text-[11.5px] font-medium text-[#1e1a16]">
                <KeyRound className="size-3.5 shrink-0 text-[#5b5349]" aria-hidden="true" />
                <span className="truncate">{item.label}</span>
              </span>
              <span
                className={`inline-flex h-4.5 w-8 shrink-0 items-center rounded-full p-0.5 ${
                  item.enabled ? 'justify-end bg-[#1d9a48]' : 'justify-start bg-[#d6cec2]'
                }`}
              >
                <span className="flex size-3.5 items-center justify-center rounded-full bg-white shadow-xs">
                  {item.enabled && (
                    <Check className="size-2.5 text-[#15803d]" strokeWidth={3} aria-hidden="true" />
                  )}
                </span>
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export function FeaturesSection({ copy, locale, os, reducedMotion }: FeaturesSectionProps) {
  const [paused, setPaused] = useState(false);
  const [cameraModalOpen, setCameraModalOpen] = useState(false);

  const motionRunning = !paused && !reducedMotion;
  const cam = copy.cameraSpotlight;

  const renderVisual = (id: string) => {
    switch (id) {
      case 'bridge':
        return <BridgeVignette locale={locale} />;
      case 'search':
        return <SearchVignette active={motionRunning} locale={locale} />;
      case 'voice':
        return <VoiceVignette active={motionRunning} locale={locale} />;
      case 'context':
        return <ContextVignette locale={locale} />;
      case 'all-off':
        return <AllOffVignette active={motionRunning} locale={locale} />;
      default:
        return <PrivacyVignette locale={locale} />;
    }
  };

  return (
    <section
      id="features"
      className="mx-auto w-full max-w-[1080px] px-5 py-16 sm:px-10 sm:py-20"
    >
      {/* Editorial Section Header */}
      <div className="flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
        <div className="max-w-[42rem]">
          <h2 className="editorial-h2">
            {copy.h2Prefix && copy.h2Accent ? (
              <>
                {copy.h2Prefix}
                <em className="editorial-italic">{copy.h2Accent}</em>
              </>
            ) : (
              copy.h2
            )}
          </h2>
          <p className="editorial-lead mt-3.5">{copy.lead}</p>
        </div>

        {!reducedMotion && (
          <button
            type="button"
            data-pause="true"
            aria-pressed={paused}
            onClick={() => setPaused((p) => !p)}
            className="loop-pause btn-tactile inline-flex min-h-[44px] shrink-0 items-center gap-1.5 self-start rounded-full bg-[#fbf9f5] px-4 text-[13px] font-medium text-[#3b332b] shadow-[inset_0_0_0_1px_rgba(38,30,22,0.12)] hover:bg-white hover:text-[#1e1a16] sm:min-h-[40px] sm:self-end"
          >
            {paused ? (
              <>
                <Play className="size-3.5" aria-hidden="true" />
                <span>{copy.resumeDemos}</span>
              </>
            ) : (
              <>
                <Pause className="size-3.5" aria-hidden="true" />
                <span>{copy.pauseDemos}</span>
              </>
            )}
          </button>
        )}
      </div>

      {/* ===== Standout Moat Spotlight: Clickable Live Camera, PTZ & Doorbell PiP ===== */}
      <div className="mt-9 grid grid-cols-1 items-start gap-x-10 gap-y-6 border-y border-[#1e1a16]/[0.10] py-8 md:grid-cols-2">
        {/* Left Column (Top-Aligned Editorial Copy + Spec Chips + Primary Trigger) */}
        <div className="flex flex-col items-start">
          <div className="editorial-eyebrow">{cam.eyebrow}</div>
          <h3 className="editorial-h3 mt-2.5">{cam.title}</h3>
          <p className="mt-2.5 text-[16px] leading-[1.58] text-[#4a433b] text-pretty">
            {cam.body}
          </p>

          {/* Technical Proof Chips inside data-ui so copy-stat-strip stays clean */}
          <div data-ui="true" className="mt-4 flex flex-wrap gap-1.5">
            {cam.specs.map((spec, idx) => (
              <span
                key={spec}
                className={idx === 0 ? 'metric-mono metric-mono-accent' : 'metric-mono'}
              >
                {spec}
              </span>
            ))}
          </div>

          <button
            type="button"
            onClick={() => setCameraModalOpen(true)}
            className="btn-tactile mt-5 inline-flex min-h-[44px] items-center gap-2 rounded-full bg-[#1e1a16] px-5 text-[14.5px] font-medium tracking-[-0.01em] text-[#fbf9f5] shadow-[0_1px_1px_rgba(30,26,22,0.25),0_10px_24px_-10px_rgba(30,26,22,0.38)] hover:bg-[#312b25]"
          >
            <Video className="size-4 text-[#60cdff]" aria-hidden="true" />
            <span>{cam.ctaOpen}</span>
            <ChevronRight className="size-4 opacity-75" aria-hidden="true" />
          </button>
        </div>

        {/* Right Column (Aligned 1:1 with 2-col Grid Below: Clickable Live Camera Preview Stage) */}
        <div data-ui="true" className="w-full">
          <button
            type="button"
            onClick={() => setCameraModalOpen(true)}
            aria-label={`${cam.ctaOpen} — ${cam.modalTitle}`}
            className="editorial-card-hover group relative block aspect-[16/10] w-full overflow-hidden rounded-2xl border border-[#1e1a16]/14 bg-[#141210] text-left shadow-[0_18px_40px_-24px_rgba(30,22,14,0.45)]"
          >
            <CameraSceneFeed
              pan={0}
              tilt={0}
              lens="wide"
              porchLightOn
              deskLampOn
              activeZone={locale === 'zh' ? '入户门廊' : 'Front Entry'}
              showZoneTag={false}
            />

            {/* Top HUD Overlay */}
            <div className="pointer-events-none absolute top-2.5 right-2.5 left-2.5 flex items-center justify-between gap-2 sm:top-3 sm:right-3 sm:left-3">
              <span className="inline-flex shrink-0 items-center gap-1.5 rounded-full bg-black/68 px-2.5 py-1 font-mono text-[11px] whitespace-nowrap text-[#f6f2eb] backdrop-blur-xs">
                <span className="size-2 rounded-full bg-[#22c55e]" />
                <span className="font-semibold text-white">{cam.liveBadge}</span>
                <span className="text-[#d6cec2]">· go2rtc</span>
              </span>

              <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-black/68 px-2.5 py-1 font-mono text-[11px] whitespace-nowrap text-[#f5cfa0] backdrop-blur-xs">
                <VolumeX className="size-3" aria-hidden="true" />
                <span>{cam.videoOnlyBadge}</span>
              </span>
            </div>

            {/* Bottom Interactive Hint Strip (clean single CTA pill — zero redundancy with left specs) */}
            <div className="pointer-events-none absolute right-2.5 bottom-2.5 left-2.5 flex items-center justify-end sm:right-3 sm:bottom-3 sm:left-3">
              <span className="inline-flex shrink-0 items-center gap-1.5 rounded-full bg-[#fbf9f5] px-3 py-1 text-[11.5px] font-semibold whitespace-nowrap text-[#1e1a16] shadow-md transition-transform duration-150 group-hover:scale-[1.02]">
                <Maximize2 className="size-3 text-[#9a4a12]" aria-hidden="true" />
                <span>{cam.ctaOpen}</span>
              </span>
            </div>
          </button>
        </div>
      </div>

      {/* ===== 6 Core Standout Moat Cards (2-Column 16:10 Grid, Bottom Screenshot Cards Removed) ===== */}
      <div className="mt-10 grid grid-cols-1 gap-x-10 gap-y-10 md:grid-cols-2">
        {copy.items.map((item) => (
          <article key={item.id} className="flex flex-col">
            <div
              className={`aspect-[16/10] w-full overflow-hidden rounded-2xl ${
                item.theme === 'paper' ? 'hairline-paper' : 'hairline-sand'
              }`}
            >
              {renderVisual(item.id)}
            </div>
            <h3 className="editorial-h3 mt-4">
              {os === 'windows' && item.winTitle ? item.winTitle : item.title}
            </h3>
            <p className="mt-1.5 pr-2 text-[16px] leading-[1.58] text-[#4a433b] text-pretty">
              {os === 'windows' && item.winBody ? item.winBody : item.body}
            </p>
          </article>
        ))}
      </div>

      {/* Interactive Live Camera / PTZ / Dual-Lens / 3:4 PiP / 2x2 Wall Modal */}
      {cameraModalOpen && (
        <LiveCameraModal
          copy={cam}
          locale={locale}
          onClose={() => setCameraModalOpen(false)}
        />
      )}
    </section>
  );
}
