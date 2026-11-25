import { useId, useRef, useState, type PointerEvent } from 'react';
import {
  Camera,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  Clock,
  Crosshair,
  Grid2x2,
  LampDesk,
  Monitor,
  Pin,
  Radio,
  VolumeX,
  X,
} from 'lucide-react';
import {
  kelvinToHex,
  useHomeStore,
  type CameraFeedId,
  type CameraViewTab,
} from '../../store/homeStore';
import { playTactileSound } from '../../utils/tactileSound';
import { useUkClock } from '../../hooks/useUkClock';
import { handleTablistKeyDown } from '../../utils/tablist';
import type { NativePopoverStrings } from './nativePopoverCopy';

interface CameraLiveDrawerProps {
  nativeCopy: NativePopoverStrings;
  reducedMotion: boolean;
}

const FEED_LIST: CameraFeedId[] = ['doorbell', 'study', 'balcony', 'garage'];

/** Architectural golden-hour live camera SVG scene that reacts to real room device state */
function LiveFeedArtwork({
  feed,
  lampOn,
  lampBrightness,
  lampKelvin,
  lightBarOn,
  curtainOpen,
  compact = false,
}: {
  feed: CameraFeedId;
  lampOn: boolean;
  lampBrightness: number;
  lampKelvin: number;
  lightBarOn: boolean;
  curtainOpen: number;
  compact?: boolean;
}) {
  const lampHex = kelvinToHex(lampKelvin);
  const lampOpacity = lampOn ? 0.25 + (lampBrightness / 100) * 0.65 : 0;

  if (feed === 'study') {
    const sunRatio = curtainOpen / 100;
    return (
      <svg
        viewBox="0 0 420 248"
        className="h-full w-full object-cover"
        aria-hidden="true"
        preserveAspectRatio="xMidYMid slice"
      >
        <defs>
          <linearGradient id="camStudyWall" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stopColor="#322b25" />
            <stop offset="55%" stopColor="#463b32" />
            <stop offset="100%" stopColor="#26201c" />
          </linearGradient>
          <linearGradient id="camStudySun" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#56698e" />
            <stop offset="48%" stopColor="#d98157" />
            <stop offset="100%" stopColor="#f5bc6f" />
          </linearGradient>
          <radialGradient id="camLampGlow" cx="27%" cy="56%" r="44%">
            <stop offset="0%" stopColor={lampHex} stopOpacity={lampOpacity} />
            <stop offset="100%" stopColor={lampHex} stopOpacity="0" />
          </radialGradient>
        </defs>
        <rect width="420" height="248" fill="url(#camStudyWall)" />
        {/* Acoustic oak slats on left wall */}
        {[18, 28, 38, 48, 58, 68, 78].map((x) => (
          <rect key={x} x={x} y="16" width="5" height="170" rx="1" fill="#8b6b49" opacity="0.45" />
        ))}
        {/* Right sunset window reacting to curtainOpen */}
        <rect x="316" y="24" width="84" height="156" rx="2" fill="url(#camStudySun)" opacity={0.42 + sunRatio * 0.58} />
        <rect
          x="316"
          y="24"
          width={Math.max(8, (1 - sunRatio) * 76)}
          height="156"
          fill="#6e6357"
          opacity="0.92"
        />
        {/* Golden sun patch across oak desk */}
        <polygon
          points="316,136 168,205 245,212 375,172"
          fill="#f5a642"
          opacity={sunRatio * 0.24}
        />
        {/* European White Oak desk */}
        <rect x="38" y="176" width="344" height="16" rx="3" fill="#c7a378" />
        <rect x="52" y="192" width="14" height="56" fill="#9a7852" />
        <rect x="354" y="192" width="14" height="56" fill="#9a7852" />
        {/* Blue M4 iMac */}
        <rect x="150" y="96" width="114" height="68" rx="4" fill="#eef1f5" />
        <rect x="154" y="100" width="106" height="52" rx="2" fill="#232c3d" />
        <rect x="150" y="154" width="114" height="10" rx="1.5" fill="#9ab7d4" />
        <rect x="197" y="164" width="20" height="12" fill="#85a6c6" />
        {/* Monitor light bar glow */}
        {lightBarOn && (
          <>
            <rect x="180" y="92" width="54" height="3.5" rx="1.5" fill="#fff3dc" />
            <polygon points="182,96 232,96 270,176 144,176" fill="#ffe7be" opacity="0.22" />
          </>
        )}
        {/* Mi Desk Lamp */}
        <rect x="92" y="171" width="32" height="5" rx="2" fill="#e8e5de" />
        <line x1="108" y1="171" x2="108" y2="112" stroke="#ebe8e2" strokeWidth="3.2" />
        <line x1="108" y1="112" x2="138" y2="122" stroke="#ebe8e2" strokeWidth="3.2" />
        <circle cx="108" cy="112" r="2.6" fill="#e85d26" />
        <rect width="420" height="248" fill="url(#camLampGlow)" />
        {!compact && (
          <rect x="160" y="106" width="22" height="32" rx="3" fill="#ff9500" opacity="0.28" />
        )}
      </svg>
    );
  }

  if (feed === 'balcony') {
    return (
      <svg
        viewBox="0 0 420 248"
        className="h-full w-full object-cover"
        aria-hidden="true"
        preserveAspectRatio="xMidYMid slice"
      >
        <defs>
          <linearGradient id="camBalconySky" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#354668" />
            <stop offset="46%" stopColor="#c76d50" />
            <stop offset="82%" stopColor="#f3a959" />
            <stop offset="100%" stopColor="#f8cc82" />
          </linearGradient>
        </defs>
        <rect width="420" height="248" fill="url(#camBalconySky)" />
        <circle cx="236" cy="128" r="26" fill="#ffe4a8" opacity="0.88" />
        <circle cx="236" cy="128" r="64" fill="#ffbe6b" opacity="0.26" />
        <path d="M0 166 Q110 144 220 158 T420 152 L420 248 L0 248 Z" fill="#2c2420" opacity="0.86" />
        {/* Balcony architectural railing */}
        <line x1="0" y1="184" x2="420" y2="184" stroke="#1b1714" strokeWidth="5" />
        {[30, 86, 142, 198, 254, 310, 366].map((x) => (
          <line key={x} x1={x} y1="184" x2={x} y2="248" stroke="#1f1a17" strokeWidth="3.5" />
        ))}
      </svg>
    );
  }

  if (feed === 'garage') {
    return (
      <svg
        viewBox="0 0 420 248"
        className="h-full w-full object-cover"
        aria-hidden="true"
        preserveAspectRatio="xMidYMid slice"
      >
        <rect width="420" height="248" fill="#1b1d20" />
        <rect x="44" y="34" width="332" height="148" rx="4" fill="#25282c" stroke="#343940" strokeWidth="2" />
        {[64, 94, 124, 154].map((y) => (
          <line key={y} x1="48" y1={y} x2="372" y2={y} stroke="#1c1f22" strokeWidth="2" />
        ))}
        <polygon points="0,182 420,182 420,248 0,248" fill="#17191c" />
        <ellipse cx="210" cy="40" rx="90" ry="26" fill="#d9e7f7" opacity="0.16" />
        <rect x="184" y="28" width="52" height="6" rx="3" fill="#dce9f7" opacity="0.72" />
        {/* Wall EV charger indicator */}
        <rect x="16" y="102" width="18" height="32" rx="4" fill="#2f353c" />
        <circle cx="25" cy="114" r="2.8" fill="#30d158" />
      </svg>
    );
  }

  // Default: Front Doorbell (Warm architectural sunset porch + doorstep delivery parcel + live-synced porch lamp)
  return (
    <svg
      viewBox="0 0 420 248"
      className="h-full w-full object-cover"
      aria-hidden="true"
      preserveAspectRatio="xMidYMid slice"
    >
      <defs>
        <linearGradient id="porchSky" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#303d59" />
          <stop offset="48%" stopColor="#a75d45" />
          <stop offset="100%" stopColor="#e8a45c" />
        </linearGradient>
        <linearGradient id="porchWall" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0%" stopColor="#4b4036" />
          <stop offset="100%" stopColor="#2e2721" />
        </linearGradient>
        <radialGradient id="porchSconceGlow" cx="68%" cy="32%" r="48%">
          <stop offset="0%" stopColor={lampHex} stopOpacity={lampOn ? 0.62 : 0.08} />
          <stop offset="55%" stopColor="#f59e0b" stopOpacity={lampOn ? 0.18 : 0} />
          <stop offset="100%" stopColor="#f59e0b" stopOpacity="0" />
        </radialGradient>
      </defs>

      {/* Evening twilight garden backdrop on left */}
      <rect width="420" height="248" fill="url(#porchSky)" />
      {/* Distant olive/cedar foliage silhouette */}
      <path
        d="M0 112 Q28 84 62 96 Q90 66 132 88 L132 184 L0 184 Z"
        fill="#272c24"
        opacity="0.88"
      />
      {/* Architectural plaster entryway wall */}
      <polygon points="118,0 420,0 420,188 118,176" fill="url(#porchWall)" />
      {/* Warm oak front entry door & sidelight */}
      <rect x="164" y="24" width="96" height="156" rx="2" fill="#8b6240" stroke="#3c2b1e" strokeWidth="3" />
      <rect x="176" y="36" width="72" height="58" rx="2" fill="#463222" opacity="0.45" />
      <rect x="176" y="106" width="72" height="58" rx="2" fill="#463222" opacity="0.45" />
      <circle cx="246" cy="108" r="3.5" fill="#d9c6a3" />

      {/* Warm brass architectural porch sconce (synced LIVE to lampOn!) */}
      <rect x="282" y="64" width="14" height="28" rx="4" fill="#2a241f" stroke="#594c3f" strokeWidth="1.5" />
      <rect
        x="284"
        y="68"
        width="10"
        height="20"
        rx="2"
        fill={lampOn ? lampHex : '#574e46'}
        opacity={lampOn ? 0.95 : 0.45}
      />

      {/* Stone porch steps & welcome mat */}
      <polygon points="0,176 420,186 420,248 0,248" fill="#3a332d" />
      <polygon points="136,184 294,188 278,220 112,216" fill="#5b4d3e" />
      {/* Delivery parcel on doorstep (matches 17:41 Package event!) */}
      <g transform="translate(216, 166)">
        <polygon points="0,14 34,10 50,18 16,22" fill="#d4aa78" />
        <polygon points="0,14 16,22 16,42 0,34" fill="#a87e4e" />
        <polygon points="16,22 50,18 50,38 16,42" fill="#bd915f" />
        <line x1="17" y1="12" x2="33" y2="20" stroke="#efe2cf" strokeWidth="2.5" opacity="0.7" />
        <rect x="22" y="25" width="12" height="7" rx="1" fill="#f7f2e8" opacity="0.85" />
      </g>

      {/* Terracotta planter by doorway */}
      <path d="M132 162 L152 162 L148 192 L136 192 Z" fill="#9c593c" />
      <ellipse cx="142" cy="152" rx="14" ry="12" fill="#46583d" />

      {/* Live porch sconce glow */}
      <rect width="420" height="248" fill="url(#porchSconceGlow)" />
      {/* Subtle golden-hour diagonal sunlight grazing the stoop */}
      <polygon points="0,84 180,152 140,248 0,210" fill="#f7b35b" opacity="0.13" />
    </svg>
  );
}

/**
 * Native Floating Live Camera Window (MenuBarHome v1.4.0)
 * Showcases local go2rtc bridge, drag-to-pan/tilt PTZ, dual-lens 1x/3x switcher,
 * pinned quick switches synced with the 3D room, 2x2 still wall, 7d events, and Pin-to-PiP.
 */
export function CameraLiveDrawer({ nativeCopy, reducedMotion }: CameraLiveDrawerProps) {
  // Desktop and mobile drawers stay mounted at once: unique ids keep tabs/tabpanels paired.
  const uid = useId().replace(/:/g, '');
  const camCopy = nativeCopy.cameraWindow;
  const cameraFeed = useHomeStore((s) => s.cameraFeed);
  const cameraLens = useHomeStore((s) => s.cameraLens);
  const cameraViewTab = useHomeStore((s) => s.cameraViewTab);
  const cameraPan = useHomeStore((s) => s.cameraPan);
  const cameraTilt = useHomeStore((s) => s.cameraTilt);
  const pipPinned = useHomeStore((s) => s.pipPinned);
  const lampOn = useHomeStore((s) => s.lampOn);
  const lampBrightness = useHomeStore((s) => s.lampBrightness);
  const lampKelvin = useHomeStore((s) => s.lampKelvin);
  const lightBarOn = useHomeStore((s) => s.lightBarOn);
  const curtainOpen = useHomeStore((s) => s.curtainOpen);
  const soundEnabled = useHomeStore((s) => s.soundEnabled);

  const closeCamera = useHomeStore((s) => s.closeCamera);
  const setCameraFeed = useHomeStore((s) => s.setCameraFeed);
  const setCameraLens = useHomeStore((s) => s.setCameraLens);
  const setCameraViewTab = useHomeStore((s) => s.setCameraViewTab);
  const setCameraPtz = useHomeStore((s) => s.setCameraPtz);
  const nudgeCameraPtz = useHomeStore((s) => s.nudgeCameraPtz);
  const resetCameraPtz = useHomeStore((s) => s.resetCameraPtz);
  const togglePip = useHomeStore((s) => s.togglePip);
  const toggleLamp = useHomeStore((s) => s.toggleLamp);
  const toggleLightBar = useHomeStore((s) => s.toggleLightBar);
  const showVoiceHud = useHomeStore((s) => s.showVoiceHud);

  const clock = useUkClock();
  const [draggingPtz, setDraggingPtz] = useState(false);
  const [shutterFlash, setShutterFlash] = useState(false);
  const dragOriginRef = useRef<{ x: number; y: number; pan: number; tilt: number } | null>(null);

  const handlePtzDown = (e: PointerEvent<HTMLDivElement>) => {
    if (cameraViewTab !== 'live') return;
    // Do not hijack clicks on buttons inside the video HUD
    if ((e.target as HTMLElement).closest('button')) return;
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {
      // Ignore synthetic events
    }
    dragOriginRef.current = {
      x: e.clientX,
      y: e.clientY,
      pan: cameraPan,
      tilt: cameraTilt,
    };
    setDraggingPtz(true);
  };

  const handlePtzMove = (e: PointerEvent<HTMLDivElement>) => {
    const origin = dragOriginRef.current;
    if (!origin) return;
    const dx = e.clientX - origin.x;
    const dy = e.clientY - origin.y;
    setCameraPtz(origin.pan + dx * 0.32, origin.tilt - dy * 0.24);
  };

  const handlePtzUp = () => {
    dragOriginRef.current = null;
    setDraggingPtz(false);
  };

  const handleSnapshot = () => {
    setShutterFlash(true);
    playTactileSound('click', soundEnabled);
    showVoiceHud(camCopy.snapshotSaved, 2400);
    window.setTimeout(() => setShutterFlash(false), 180);
  };

  const currentFeedInfo = camCopy.feeds[cameraFeed];
  const lensScale = cameraLens === 'tele' ? 1.62 : 1.18;
  // Translate scaled feed proportionally to PTZ pan & tilt
  const tx = -(cameraPan / 45) * (cameraLens === 'tele' ? 22 : 9);
  const ty = (cameraTilt / 22) * (cameraLens === 'tele' ? 18 : 7);

  const tabs: Array<{ id: CameraViewTab; label: string; icon: typeof Radio }> = [
    { id: 'live', label: camCopy.tabs.live, icon: Radio },
    { id: 'wall', label: camCopy.tabs.wall, icon: Grid2x2 },
    { id: 'events', label: camCopy.tabs.events, icon: Clock },
  ];
  const tabIds = tabs.map((tab) => tab.id);

  return (
    <section
      data-ui="true"
      aria-label={camCopy.title}
      className="lg-popover-enter w-full max-w-[404px] overflow-hidden rounded-[22px] bg-[#161412]/94 text-[#f6f2eb] shadow-[0_28px_72px_-18px_rgba(16,12,8,0.68),inset_0_1px_0_rgba(255,255,255,0.16),inset_0_0_0_1px_rgba(255,245,230,0.10)] backdrop-blur-2xl select-none [&_button:focus-visible]:outline-[#fbbf24]"
    >
      {/* Native macOS Floating Panel Titlebar */}
      <div className="flex items-center justify-between gap-2 border-b border-white/[0.08] px-3.5 py-2.5">
        <div className="flex min-w-0 items-center gap-2">
          <button
            type="button"
            onClick={() => {
              closeCamera();
              playTactileSound('tick', soundEnabled);
            }}
            aria-label={camCopy.close}
            className="flex size-3.5 shrink-0 items-center justify-center rounded-full bg-[#ff5f57] text-transparent transition-colors hover:text-[#4d0000]"
          >
            <X className="size-2.5" strokeWidth={3} aria-hidden="true" />
          </button>
          <span
            className="flex size-6 shrink-0 items-center justify-center rounded-full bg-[#009eff] text-white"
            style={{ boxShadow: '0 4px 12px -3px rgba(0, 158, 255, 0.55)' }}
          >
            <Camera className="size-3.5" strokeWidth={2.2} aria-hidden="true" />
          </span>
          <div className="min-w-0 leading-tight">
            <div className="truncate text-[12.5px] font-semibold tracking-[-0.01em] text-[#fbf9f5]">
              {currentFeedInfo.name}
            </div>
            <div className="truncate text-[10px] text-[#b5ada2] tabular-nums">
              {currentFeedInfo.room} · {currentFeedInfo.status}
            </div>
          </div>
        </div>

        <div className="flex shrink-0 items-center gap-1.5">
          <button
            type="button"
            onClick={() => {
              togglePip();
              playTactileSound('click', soundEnabled);
            }}
            aria-pressed={pipPinned}
            className={`btn-tactile inline-flex h-7 items-center gap-1 rounded-full px-2.5 text-[11px] font-semibold ${
              pipPinned
                ? 'bg-[#009eff] text-white shadow-xs'
                : 'bg-white/[0.10] text-[#f6f2eb] hover:bg-white/[0.16]'
            }`}
          >
            <Pin className="size-3" aria-hidden="true" />
            <span>{pipPinned ? camCopy.unpinPip : camCopy.pinPip}</span>
          </button>

          <button
            type="button"
            onClick={() => {
              closeCamera();
              playTactileSound('tick', soundEnabled);
            }}
            aria-label={camCopy.close}
            className="btn-tactile flex size-7 items-center justify-center rounded-full bg-white/[0.08] text-[#cfc7bc] hover:bg-white/[0.14] hover:text-white"
          >
            <X className="size-3.5" aria-hidden="true" />
          </button>
        </div>
      </div>

      {/* Mode Switcher: Live View | 2x2 Wall | Events (7d) */}
      <div className="flex flex-wrap items-center justify-between gap-1.5 px-3 pt-2.5 pb-2">
        <div
          role="tablist"
          aria-label={nativeCopy.a11y.cameraModes}
          onKeyDown={(e) =>
            handleTablistKeyDown(e, tabIds, cameraViewTab, (id) => {
              setCameraViewTab(id);
              playTactileSound('tick', soundEnabled);
            })
          }
          className="inline-flex rounded-full bg-white/[0.07] p-0.5"
        >
          {tabs.map((tab) => {
            const Icon = tab.icon;
            const active = cameraViewTab === tab.id;
            return (
              <button
                key={tab.id}
                type="button"
                role="tab"
                id={`${uid}-camera-drawer-tab-${tab.id}`}
                aria-controls={`${uid}-camera-drawer-panel`}
                aria-selected={active}
                tabIndex={active ? 0 : -1}
                onClick={() => {
                  setCameraViewTab(tab.id);
                  playTactileSound('tick', soundEnabled);
                }}
                className={`btn-tactile inline-flex items-center gap-1 rounded-full px-2 py-1 text-[10.5px] font-medium whitespace-nowrap sm:px-2.5 sm:text-[11px] ${
                  active
                    ? 'bg-white/[0.18] text-white shadow-xs'
                    : 'text-[#b8b0a5] hover:text-white'
                }`}
              >
                <Icon className="size-3" aria-hidden="true" />
                <span>{tab.label}</span>
              </button>
            );
          })}
        </div>

        <button
          type="button"
          onClick={handleSnapshot}
          className="btn-tactile inline-flex h-7 items-center gap-1 rounded-full bg-white/[0.08] px-2 text-[10.5px] font-medium whitespace-nowrap text-[#e6dfd5] hover:bg-white/[0.14] sm:px-2.5"
        >
          <Camera className="size-3" aria-hidden="true" />
          <span>{camCopy.snapshotBtn}</span>
        </button>
      </div>

      {/* Main Viewport Area */}
      <div
        id={`${uid}-camera-drawer-panel`}
        role="tabpanel"
        aria-labelledby={`${uid}-camera-drawer-tab-${cameraViewTab}`}
        className="px-3 pb-3"
      >
        {cameraViewTab === 'live' && (
          <div className="space-y-2.5">
            {/* Interactive Drag-to-Pan/Tilt PTZ Live Feed Surface */}
            <div
              role="application"
              aria-label={camCopy.ptzHint}
              onPointerDown={handlePtzDown}
              onPointerMove={handlePtzMove}
              onPointerUp={handlePtzUp}
              onPointerCancel={handlePtzUp}
              className={`relative aspect-[16/10] w-full overflow-hidden rounded-[15px] bg-[#100e0c] ring-1 ring-white/12 ${
                draggingPtz ? 'cursor-grabbing' : 'cursor-grab'
              }`}
              style={{ touchAction: 'none' }}
            >
              <div
                className="h-full w-full"
                style={{
                  transform: `translate3d(${tx}%, ${ty}%, 0) scale(${lensScale})`,
                  transition:
                    draggingPtz || reducedMotion
                      ? 'none'
                      : 'transform 260ms cubic-bezier(0.23, 1, 0.32, 1)',
                }}
              >
                <LiveFeedArtwork
                  feed={cameraFeed}
                  lampOn={lampOn}
                  lampBrightness={lampBrightness}
                  lampKelvin={lampKelvin}
                  lightBarOn={lightBarOn}
                  curtainOpen={curtainOpen}
                />
              </div>

              {/* Optical lens vignette */}
              <div
                aria-hidden="true"
                className="pointer-events-none absolute inset-0"
                style={{
                  background:
                    'radial-gradient(85% 85% at 50% 50%, transparent 55%, rgba(8,6,4,0.52) 100%)',
                }}
              />

              {/* Snapshot shutter flash */}
              {shutterFlash && (
                <div
                  aria-hidden="true"
                  className="pointer-events-none absolute inset-0 bg-white/75"
                />
              )}

              {/* Top-left go2rtc local bridge pill */}
              <div className="pointer-events-none absolute top-2.5 left-2.5 flex items-center gap-1.5 rounded-full bg-black/62 px-2 py-0.5 text-[10px] font-medium text-[#f6f2eb] backdrop-blur-md">
                <span
                  className={`size-1.5 rounded-full bg-[#30d158] ${reducedMotion ? '' : 'animate-pulse'}`}
                  aria-hidden="true"
                />
                <span className="font-mono">{camCopy.go2rtcBadge}</span>
              </div>

              {/* Top-right Video-Only muted-by-default badge + real-time clock */}
              <div className="pointer-events-none absolute top-2.5 right-2.5 flex items-center gap-1.5">
                <span className="inline-flex items-center gap-1 rounded-full bg-black/62 px-2 py-0.5 text-[10px] font-medium text-[#e5ddd2] backdrop-blur-md">
                  <VolumeX className="size-2.5 text-[#f59e0b]" aria-hidden="true" />
                  <span>{camCopy.videoOnlyBadge}</span>
                </span>
                <span className="rounded-full bg-black/62 px-2 py-0.5 font-mono text-[10px] text-[#d9d1c6] tabular-nums backdrop-blur-md">
                  {clock}
                </span>
              </div>

              {/* PTZ Reticle Crosshair & Live Coordinates (visible while dragging or off-center) */}
              {(draggingPtz || cameraPan !== 0 || cameraTilt !== 0) && (
                <div
                  aria-hidden="true"
                  className="pointer-events-none absolute inset-0 flex items-center justify-center"
                >
                  <div className="relative flex size-12 items-center justify-center rounded-full border border-white/35 bg-black/15">
                    <Crosshair className="size-4 text-[#009eff]" strokeWidth={1.8} />
                  </div>
                  <div className="absolute top-10 left-1/2 -translate-x-1/2 rounded-full bg-black/70 px-2.5 py-0.5 font-mono text-[10px] text-[#9ed6ff] tabular-nums backdrop-blur-md">
                    {camCopy.ptzPan} {cameraPan >= 0 ? `+${cameraPan}°` : `${cameraPan}°`} ·{' '}
                    {camCopy.ptzTilt} {cameraTilt >= 0 ? `+${cameraTilt}°` : `${cameraTilt}°`}
                  </div>
                </div>
              )}

              {/* Bottom-left Dual-Lens 1x Wide / 3x Telephoto Pill */}
              <div className="absolute bottom-2.5 left-2.5 flex items-center gap-0.5 rounded-full bg-black/65 p-0.5 backdrop-blur-md">
                <button
                  type="button"
                  aria-pressed={cameraLens === 'wide'}
                  onClick={() => {
                    setCameraLens('wide');
                    playTactileSound('tick', soundEnabled);
                  }}
                  className={`btn-tactile rounded-full px-2 py-0.5 text-[10.5px] font-semibold ${
                    cameraLens === 'wide'
                      ? 'bg-[#009eff] text-white'
                      : 'text-[#d4cdc2] hover:text-white'
                  }`}
                >
                  {camCopy.lensWide}
                </button>
                <button
                  type="button"
                  aria-pressed={cameraLens === 'tele'}
                  onClick={() => {
                    setCameraLens('tele');
                    playTactileSound('tick', soundEnabled);
                  }}
                  className={`btn-tactile rounded-full px-2 py-0.5 text-[10.5px] font-semibold ${
                    cameraLens === 'tele'
                      ? 'bg-[#009eff] text-white'
                      : 'text-[#d4cdc2] hover:text-white'
                  }`}
                >
                  {camCopy.lensTele}
                </button>
              </div>

              {/* Bottom-right Compact PTZ Nudge Cluster + Center Reset */}
              <div className="absolute right-2.5 bottom-2.5 flex items-center gap-1 rounded-full bg-black/65 p-0.5 backdrop-blur-md">
                <button
                  type="button"
                  aria-label={nativeCopy.a11y.panLeft}
                  onClick={() => {
                    nudgeCameraPtz(-12, 0);
                    playTactileSound('tick', soundEnabled);
                  }}
                  className="btn-tactile flex size-6 items-center justify-center rounded-full text-[#e6dfd5] hover:bg-white/15"
                >
                  <ChevronLeft className="size-3.5" aria-hidden="true" />
                </button>
                <button
                  type="button"
                  aria-label={nativeCopy.a11y.tiltUp}
                  onClick={() => {
                    nudgeCameraPtz(0, 8);
                    playTactileSound('tick', soundEnabled);
                  }}
                  className="btn-tactile flex size-6 items-center justify-center rounded-full text-[#e6dfd5] hover:bg-white/15"
                >
                  <ChevronUp className="size-3.5" aria-hidden="true" />
                </button>
                <button
                  type="button"
                  aria-label={camCopy.ptzCenter}
                  onClick={() => {
                    resetCameraPtz();
                    playTactileSound('click', soundEnabled);
                  }}
                  className="btn-tactile rounded-full px-1.5 text-[9.5px] font-semibold text-[#9ed6ff] hover:bg-white/15"
                >
                  0°
                </button>
                <button
                  type="button"
                  aria-label={nativeCopy.a11y.tiltDown}
                  onClick={() => {
                    nudgeCameraPtz(0, -8);
                    playTactileSound('tick', soundEnabled);
                  }}
                  className="btn-tactile flex size-6 items-center justify-center rounded-full text-[#e6dfd5] hover:bg-white/15"
                >
                  <ChevronDown className="size-3.5" aria-hidden="true" />
                </button>
                <button
                  type="button"
                  aria-label={nativeCopy.a11y.panRight}
                  onClick={() => {
                    nudgeCameraPtz(12, 0);
                    playTactileSound('tick', soundEnabled);
                  }}
                  className="btn-tactile flex size-6 items-center justify-center rounded-full text-[#e6dfd5] hover:bg-white/15"
                >
                  <ChevronRight className="size-3.5" aria-hidden="true" />
                </button>
              </div>
            </div>

            {/* Camera Selector Strip + PTZ Drag Prompt */}
            <div className="flex items-center justify-between gap-2 text-[10.5px] text-[#afa69a]">
              <div className="flex items-center gap-1">
                {(['doorbell', 'study'] as CameraFeedId[]).map((id) => (
                  <button
                    key={id}
                    type="button"
                    aria-pressed={cameraFeed === id}
                    onClick={() => {
                      setCameraFeed(id);
                      playTactileSound('tick', soundEnabled);
                    }}
                    className={`btn-tactile rounded-full px-2 py-0.5 text-[10.5px] font-medium ${
                      cameraFeed === id
                        ? 'bg-white/[0.16] text-white'
                        : 'bg-white/[0.05] text-[#b4aba0] hover:bg-white/[0.11]'
                    }`}
                  >
                    {camCopy.feeds[id].name}
                  </button>
                ))}
              </div>
              <span className="truncate text-[10px] text-[#9d9488]">{camCopy.ptzHint}</span>
            </div>

            {/* Pinned Quick Device Switches (MenuBarHome signature: up to 2 switches live-synced with 3D room!) */}
            <div className="rounded-[14px] bg-white/[0.06] p-2 ring-1 ring-white/[0.07]">
              <div className="mb-1.5 flex items-center justify-between text-[10px] font-medium text-[#b5ada2]">
                <span>{camCopy.pinnedSwitchesLabel}</span>
                <span className="text-[#8e8579]">{camCopy.autoPipNote}</span>
              </div>
              <div className="grid grid-cols-2 gap-1.5">
                <button
                  type="button"
                  aria-pressed={lampOn}
                  onClick={() => {
                    toggleLamp();
                    playTactileSound(lampOn ? 'relayOff' : 'relayOn', soundEnabled);
                  }}
                  className={`btn-tactile flex items-center gap-2 rounded-[11px] px-2.5 py-1.5 text-left transition-colors ${
                    lampOn
                      ? 'bg-white/[0.14] text-white ring-1 ring-[#ff9500]/45'
                      : 'bg-white/[0.04] text-[#c2b9ad] hover:bg-white/[0.08]'
                  }`}
                >
                  <span
                    className="flex size-6 shrink-0 items-center justify-center rounded-full"
                    style={{
                      backgroundColor: lampOn ? '#ff9500' : 'rgba(255,255,255,0.10)',
                      color: lampOn ? '#ffffff' : '#b5ada2',
                    }}
                  >
                    <LampDesk className="size-3.5" aria-hidden="true" />
                  </span>
                  <span className="min-w-0 truncate text-[11px] font-semibold">
                    {camCopy.porchLampSwitch}
                  </span>
                </button>

                <button
                  type="button"
                  aria-pressed={lightBarOn}
                  onClick={() => {
                    toggleLightBar();
                    playTactileSound(lightBarOn ? 'relayOff' : 'relayOn', soundEnabled);
                  }}
                  className={`btn-tactile flex items-center gap-2 rounded-[11px] px-2.5 py-1.5 text-left transition-colors ${
                    lightBarOn
                      ? 'bg-white/[0.14] text-white ring-1 ring-[#009eff]/45'
                      : 'bg-white/[0.04] text-[#c2b9ad] hover:bg-white/[0.08]'
                  }`}
                >
                  <span
                    className="flex size-6 shrink-0 items-center justify-center rounded-full"
                    style={{
                      backgroundColor: lightBarOn ? '#009eff' : 'rgba(255,255,255,0.10)',
                      color: lightBarOn ? '#ffffff' : '#b5ada2',
                    }}
                  >
                    <Monitor className="size-3.5" aria-hidden="true" />
                  </span>
                  <span className="min-w-0 truncate text-[11px] font-semibold">
                    {camCopy.lightBarSwitch}
                  </span>
                </button>
              </div>
            </div>
          </div>
        )}

        {/* 2x2 Still Wall View */}
        {cameraViewTab === 'wall' && (
          <div className="grid grid-cols-2 gap-2">
            {FEED_LIST.map((feedId) => {
              const meta = camCopy.feeds[feedId];
              const isSelected = cameraFeed === feedId;
              return (
                <button
                  key={feedId}
                  type="button"
                  onClick={() => {
                    setCameraFeed(feedId);
                    setCameraViewTab('live');
                    playTactileSound('click', soundEnabled);
                  }}
                  className={`btn-tactile group relative overflow-hidden rounded-[13px] bg-[#12100e] text-left ring-1 transition-all ${
                    isSelected
                      ? 'ring-[#009eff]'
                      : 'ring-white/12 hover:ring-white/30'
                  }`}
                >
                  <div className="aspect-[16/10] w-full overflow-hidden">
                    <LiveFeedArtwork
                      feed={feedId}
                      lampOn={lampOn}
                      lampBrightness={lampBrightness}
                      lampKelvin={lampKelvin}
                      lightBarOn={lightBarOn}
                      curtainOpen={curtainOpen}
                      compact
                    />
                  </div>
                  <div className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/82 via-black/45 to-transparent px-2.5 pt-4 pb-2">
                    <div className="flex items-center justify-between gap-1">
                      <span className="truncate text-[11px] font-semibold text-white">
                        {meta.name}
                      </span>
                      <span className="size-1.5 shrink-0 rounded-full bg-[#30d158]" />
                    </div>
                    <div className="truncate text-[9.5px] text-[#c7bfb4]">{meta.status}</div>
                  </div>
                </button>
              );
            })}
          </div>
        )}

        {/* 7-Day / 500-Event Local History View */}
        {cameraViewTab === 'events' && (
          <div className="space-y-2">
            {camCopy.events.map((ev) => (
              <button
                key={`${ev.time}-${ev.title}`}
                type="button"
                onClick={() => {
                  setCameraFeed('doorbell');
                  setCameraViewTab('live');
                  playTactileSound('click', soundEnabled);
                }}
                className="btn-tactile flex w-full items-center justify-between gap-3 rounded-[13px] bg-white/[0.06] px-3 py-2.5 text-left ring-1 ring-white/[0.08] hover:bg-white/[0.11]"
              >
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-[11px] font-semibold text-[#60cdff] tabular-nums">
                      {ev.time}
                    </span>
                    <span className="truncate text-[12px] font-semibold text-[#fbf9f5]">
                      {ev.title}
                    </span>
                  </div>
                  <div className="mt-0.5 truncate text-[10.5px] text-[#b4aba0]">{ev.detail}</div>
                </div>
                <span className="shrink-0 rounded-full bg-[#009eff]/18 px-2 py-0.5 text-[10px] font-semibold text-[#7dd3fc]">
                  {ev.tag}
                </span>
              </button>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}

/** Compact live animated thumbnail preview used right inside the clickable Camera Card */
export function CameraCardMiniPreview({
  lampOn,
  lampKelvin,
}: {
  lampOn: boolean;
  lampKelvin: number;
}) {
  return (
    <div className="relative h-9 w-14 shrink-0 overflow-hidden rounded-[9px] bg-[#1a1612] ring-1 ring-black/15">
      <LiveFeedArtwork
        feed="doorbell"
        lampOn={lampOn}
        lampBrightness={72}
        lampKelvin={lampKelvin}
        lightBarOn={false}
        curtainOpen={76}
        compact
      />
      <span className="absolute top-1 left-1 flex items-center gap-0.5 rounded-full bg-black/68 px-1 py-[1px] text-[7.5px] font-bold tracking-wider text-white">
        <span className="size-1 rounded-full bg-[#30d158]" />
        LIVE
      </span>
    </div>
  );
}
