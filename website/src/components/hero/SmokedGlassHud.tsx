import {
  Camera,
  LampDesk,
  Maximize2,
  Monitor,
  Pin,
  Power,
  RotateCcw,
  SlidersHorizontal,
  Volume2,
  VolumeX,
  X,
} from 'lucide-react';
import { kelvinToHex, useHomeStore, type ScenePreset } from '../../store/homeStore';
import { playTactileSound } from '../../utils/tactileSound';
import { useUkClock } from '../../hooks/useUkClock';
import type { Locale, SiteDictionary } from '../../content/siteCopy';
import { NATIVE_POPOVER_COPY, type NativePopoverStrings } from './nativePopoverCopy';

interface SmokedGlassHudProps {
  copy: SiteDictionary['hero'];
  locale: Locale;
  onFocusSearch: () => void;
}

export function SmokedGlassHud({ copy, locale, onFocusSearch }: SmokedGlassHudProps) {
  const nativeCopy = NATIVE_POPOVER_COPY[locale];

  const preset = useHomeStore((s) => s.preset);
  const cameraFocus = useHomeStore((s) => s.cameraFocus);
  const activeKeycap = useHomeStore((s) => s.activeKeycap);
  const soundEnabled = useHomeStore((s) => s.soundEnabled);
  const undoSnapshot = useHomeStore((s) => s.undoSnapshot);
  const applyPreset = useHomeStore((s) => s.applyPreset);
  const executeAllOff = useHomeStore((s) => s.executeAllOff);
  const undoAllOff = useHomeStore((s) => s.undoAllOff);
  const toggleCameraFocus = useHomeStore((s) => s.toggleCameraFocus);
  const openCamera = useHomeStore((s) => s.openCamera);
  const stepActiveLightBrightness = useHomeStore((s) => s.stepActiveLightBrightness);
  const setSearchQuery = useHomeStore((s) => s.setSearchQuery);
  const flashKeycap = useHomeStore((s) => s.flashKeycap);
  const toggleSound = useHomeStore((s) => s.toggleSound);

  const presets: Array<{ id: ScenePreset; label: string }> = [
    { id: 'evening', label: copy.presets.evening },
    { id: 'focus', label: copy.presets.focus },
    { id: 'movie', label: copy.presets.movie },
  ];

  const isFocused = cameraFocus === 'imac';

  return (
    <div
      data-ui="true"
      className="warm-hud flex max-w-full flex-nowrap items-center gap-1 rounded-full px-1.5 py-1.5 text-[12px] text-[#1e1a16] sm:gap-2 sm:px-2.5"
    >
      {/* Scene Preset Selector */}
      <div
        className="flex items-center gap-0.5 sm:gap-1"
        role="group"
        aria-label={nativeCopy.a11y.sceneGroup}
      >
        {presets.map((item) => {
          const active = preset === item.id;
          return (
            <button
              key={item.id}
              type="button"
              aria-pressed={active}
              onClick={() => {
                applyPreset(item.id);
                playTactileSound('click', soundEnabled);
              }}
              className={`btn-tactile h-7 rounded-full px-2 text-[11.5px] font-medium whitespace-nowrap sm:px-3 sm:text-[12px] ${
                active
                  ? 'bg-[#1e1a16] text-[#fbf9f5]'
                  : 'text-[#5b5349] hover:bg-[#1e1a16]/[0.07] hover:text-[#1e1a16]'
              }`}
            >
              {item.label}
            </button>
          );
        })}

        {/* Mobile quick Native Panel & Live Camera triggers (zero horizontal overflow at 390px) */}
        <button
          type="button"
          onClick={() => {
            toggleCameraFocus();
            playTactileSound('click', soundEnabled);
          }}
          className="btn-tactile inline-flex h-7 items-center gap-1 rounded-full bg-[#1e1a16]/[0.08] px-2 text-[11px] font-medium whitespace-nowrap text-[#1e1a16] hover:bg-[#1e1a16]/[0.14] md:hidden"
        >
          <SlidersHorizontal className="size-3 text-[#d97706]" aria-hidden="true" />
          <span>{nativeCopy.mobilePanelTrigger}</span>
        </button>

        <button
          type="button"
          aria-label={nativeCopy.mobileCameraTrigger}
          onClick={() => {
            openCamera('doorbell');
            playTactileSound('click', soundEnabled);
          }}
          className="btn-tactile inline-flex size-7 items-center justify-center rounded-full bg-[#009eff]/15 text-[#007aff] hover:bg-[#009eff]/25 md:hidden"
        >
          <Camera className="size-3.5" aria-hidden="true" />
        </button>

        {undoSnapshot && (
          <button
            type="button"
            aria-label={copy.popover.undoAction}
            onClick={() => {
              undoAllOff();
              playTactileSound('undo', soundEnabled);
            }}
            className="btn-tactile inline-flex size-7 items-center justify-center rounded-full bg-[#ff9500]/20 text-[#9a4a12] md:hidden"
          >
            <RotateCcw className="size-3.5" aria-hidden="true" />
          </button>
        )}
      </div>

      <span className="hidden h-4 w-px bg-[#1e1a16]/12 sm:inline-block" aria-hidden="true" />

      {/* Blue iMac Focus Toggle Pill */}
      <button
        type="button"
        aria-pressed={isFocused}
        onClick={() => {
          toggleCameraFocus();
          playTactileSound('click', soundEnabled);
        }}
        className={`btn-tactile hidden h-7 items-center gap-1.5 rounded-full px-2.5 text-[11.5px] font-medium whitespace-nowrap sm:inline-flex ${
          isFocused
            ? 'bg-[#4a78ab] text-white'
            : 'text-[#3c5f87] hover:bg-[#4a78ab]/10 hover:text-[#2a4d75]'
        }`}
      >
        <Monitor className="size-3.5" aria-hidden="true" />
        <span>{isFocused ? copy.exitFocusLabel : copy.focusImacLabel}</span>
      </button>

      <span className="hidden h-4 w-px bg-[#1e1a16]/12 lg:inline-block" aria-hidden="true" />

      {/* Interactive Keycap Strip */}
      <div className="hidden items-center gap-1.5 lg:flex">
        <button
          type="button"
          onClick={() => {
            flashKeycap('optM');
            playTactileSound('click', soundEnabled);
            onFocusSearch();
          }}
          className="btn-tactile inline-flex h-7 items-center gap-1.5 rounded-full px-2 text-[11.5px] text-[#5b5349] hover:bg-[#1e1a16]/[0.06] hover:text-[#1e1a16]"
        >
          <kbd
            className="kbd-cap-warm !h-5 !min-w-5 !px-1.5 !text-[11px]"
            data-pressed={activeKeycap === 'optM'}
          >
            ⌥M
          </kbd>
          <span>{copy.hud.open}</span>
        </button>

        <button
          type="button"
          onClick={() => {
            flashKeycap('arrows');
            stepActiveLightBrightness(12);
            playTactileSound('tick', soundEnabled);
          }}
          className="btn-tactile inline-flex h-7 items-center gap-1 rounded-full px-2 text-[11.5px] text-[#5b5349] hover:bg-[#1e1a16]/[0.06] hover:text-[#1e1a16]"
        >
          <kbd
            className="kbd-cap-warm !h-5 !min-w-5 !px-1 !text-[11px]"
            data-pressed={activeKeycap === 'arrows'}
          >
            ←
          </kbd>
          <kbd
            className="kbd-cap-warm !h-5 !min-w-5 !px-1 !text-[11px]"
            data-pressed={activeKeycap === 'arrows'}
          >
            →
          </kbd>
          <span>{copy.hud.step}</span>
        </button>

        <button
          type="button"
          onClick={() => {
            flashKeycap('sftd');
            setSearchQuery('sftd');
            playTactileSound('click', soundEnabled);
            onFocusSearch();
          }}
          className="btn-tactile inline-flex h-7 items-center gap-1.5 rounded-full px-2 text-[11.5px] text-[#5b5349] hover:bg-[#1e1a16]/[0.06] hover:text-[#1e1a16]"
        >
          <kbd
            className="kbd-cap-warm !h-5 !px-1.5 !font-mono !text-[10.5px]"
            data-pressed={activeKeycap === 'sftd'}
          >
            sftd
          </kbd>
        </button>

        {/* Quick All Off button on wide desktop when outside Focus mode */}
        {!isFocused && (
          <button
            type="button"
            onClick={() => {
              if (undoSnapshot) undoAllOff();
              else executeAllOff();
              playTactileSound(undoSnapshot ? 'undo' : 'relayOff', soundEnabled);
            }}
            className="btn-tactile hidden h-7 items-center gap-1 rounded-full px-2 text-[11.5px] text-[#5b5349] hover:bg-[#1e1a16]/[0.06] hover:text-[#1e1a16] xl:inline-flex"
          >
            {undoSnapshot ? (
              <>
                <RotateCcw className="size-3 text-[#d97706]" aria-hidden="true" />
                <span>{copy.popover.undoAction}</span>
              </>
            ) : (
              <>
                <Power className="size-3 text-[#d97706]" aria-hidden="true" />
                <span>{copy.popover.allOffLabel}</span>
              </>
            )}
          </button>
        )}
      </div>

      <span className="hidden h-4 w-px bg-[#1e1a16]/12 sm:inline-block" aria-hidden="true" />

      {/* Muted-by-Default Tactile Sound Toggle */}
      <button
        type="button"
        onClick={() => {
          const next = !soundEnabled;
          toggleSound();
          if (next) playTactileSound('tick', true);
        }}
        aria-pressed={soundEnabled}
        aria-label={soundEnabled ? copy.soundOn : copy.soundOff}
        className="btn-tactile hidden h-7 items-center gap-1 rounded-full px-2 text-[11.5px] text-[#6b6258] hover:bg-[#1e1a16]/[0.06] hover:text-[#1e1a16] sm:inline-flex"
      >
        {soundEnabled ? (
          <Volume2 className="size-3.5 text-[#d97706]" aria-hidden="true" />
        ) : (
          <VolumeX className="size-3.5" aria-hidden="true" />
        )}
        <span className="hidden md:inline">{soundEnabled ? copy.soundOn : copy.soundOff}</span>
      </button>
    </div>
  );
}

/**
 * Always-on-Top Pinned Front Doorbell PiP Card
 * Persists even after closing the full CameraLiveDrawer; click to expand back into live PTZ view,
 * or toggle the pinned porch/study lamp directly from the floating card!
 */
export function DoorbellPiPCard({
  doorbellName,
  videoOnlyLabel,
  pinnedLabel,
  a11y,
}: {
  doorbellName: string;
  videoOnlyLabel: string;
  pinnedLabel: string;
  a11y: NativePopoverStrings['a11y'];
}) {
  const pipPinned = useHomeStore((s) => s.pipPinned);
  const pipGhosting = useHomeStore((s) => s.pipGhosting);
  const lampOn = useHomeStore((s) => s.lampOn);
  const lampKelvin = useHomeStore((s) => s.lampKelvin);
  const soundEnabled = useHomeStore((s) => s.soundEnabled);
  const togglePip = useHomeStore((s) => s.togglePip);
  const toggleLamp = useHomeStore((s) => s.toggleLamp);
  const openCamera = useHomeStore((s) => s.openCamera);
  const clock = useUkClock(pipPinned);

  if (!pipPinned) return null;

  const lampHex = kelvinToHex(lampKelvin);

  return (
    <aside
      data-ui="true"
      aria-label={a11y.pipRegion(doorbellName)}
      className={`w-[244px] overflow-hidden rounded-[16px] bg-[#161412]/94 text-[#f6f2eb] shadow-[0_22px_52px_-14px_rgba(16,12,8,0.62),inset_0_0_0_1px_rgba(255,245,230,0.14)] backdrop-blur-xl transition-[opacity,transform,filter] duration-300 [&_button:focus-visible]:outline-[#fbbf24] ${
        pipGhosting ? 'pip-ghost' : 'pip-pinned'
      }`}
    >
      <div className="relative h-[126px] w-full overflow-hidden bg-[#181512]">
        {/* Architectural Sunset Porch SVG (synced live to lampOn!) */}
        <svg
          viewBox="0 0 260 134"
          className="h-full w-full object-cover"
          aria-hidden="true"
          preserveAspectRatio="xMidYMid slice"
        >
          <defs>
            <linearGradient id="pipSky" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stopColor="#2f3c56" />
              <stop offset="55%" stopColor="#9c563f" />
              <stop offset="100%" stopColor="#e29e58" />
            </linearGradient>
            <radialGradient id="pipGlow" cx="72%" cy="34%" r="52%">
              <stop offset="0%" stopColor={lampHex} stopOpacity={lampOn ? 0.65 : 0.08} />
              <stop offset="100%" stopColor={lampHex} stopOpacity="0" />
            </radialGradient>
          </defs>
          <rect width="260" height="134" fill="url(#pipSky)" />
          <polygon points="74,0 260,0 260,104 74,96" fill="#3a322b" />
          <rect x="106" y="14" width="60" height="86" rx="2" fill="#825b3a" stroke="#342519" strokeWidth="2" />
          <rect x="180" y="34" width="9" height="18" rx="3" fill={lampOn ? lampHex : '#554d45'} />
          <polygon points="0,96 260,102 260,134 0,134" fill="#2e2823" />
          {/* Delivery parcel on doorstep */}
          <polygon points="134,94 156,92 165,98 143,100" fill="#d4aa78" />
          <polygon points="143,100 165,98 165,112 143,114" fill="#b78a58" />
          <rect width="260" height="134" fill="url(#pipGlow)" />
          <rect
            width="260"
            height="134"
            fill="linear-gradient(180deg, transparent 55%, rgba(0,0,0,0.72) 100%)"
            opacity="0"
          />
        </svg>

        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 bottom-0 h-14 bg-gradient-to-t from-black/82 via-black/40 to-transparent"
        />

        {/* Top-left PiP Status Pill */}
        <div className="pointer-events-none absolute top-2 left-2 flex items-center gap-1.5 rounded-full bg-black/62 px-2 py-0.5 text-[10px] font-medium text-[#7dd3fc] backdrop-blur-md">
          <Pin className="size-2.5" aria-hidden="true" />
          <span>{pinnedLabel}</span>
        </div>

        {/* Top-right Expand to Full Live PTZ + Close buttons */}
        <div className="absolute top-2 right-2 flex items-center gap-1">
          <button
            type="button"
            onClick={() => {
              openCamera('doorbell');
              playTactileSound('click', soundEnabled);
            }}
            aria-label={a11y.openFullCamera}
            className="btn-tactile flex size-6 items-center justify-center rounded-full bg-black/62 text-[#e4ded4] hover:bg-black/85 hover:text-white"
          >
            <Maximize2 className="size-3" aria-hidden="true" />
          </button>
          <button
            type="button"
            onClick={() => {
              togglePip();
              playTactileSound('tick', soundEnabled);
            }}
            aria-label={a11y.closePip}
            className="btn-tactile flex size-6 items-center justify-center rounded-full bg-black/62 text-[#e4ded4] hover:bg-black/85 hover:text-white"
          >
            <X className="size-3" aria-hidden="true" />
          </button>
        </div>

        {/* Bottom HUD: Name, Video only + clock, and live Porch Lamp quick orb */}
        <div className="absolute right-2 bottom-2 left-2 flex items-center justify-between gap-2 text-[10.5px] tabular-nums">
          <button
            type="button"
            onClick={() => {
              openCamera('doorbell');
              playTactileSound('click', soundEnabled);
            }}
            className="min-w-0 text-left hover:underline"
          >
            <div className="truncate font-semibold text-[#fbf9f5]">{doorbellName}</div>
            <div className="truncate font-mono text-[9.5px] text-[#cfc7bc]">
              {videoOnlyLabel} · {clock}
            </div>
          </button>
          <button
            type="button"
            aria-label={a11y.togglePorchLampFromPip}
            aria-pressed={lampOn}
            onClick={() => {
              toggleLamp();
              playTactileSound(lampOn ? 'relayOff' : 'relayOn', soundEnabled);
            }}
            className="btn-tactile flex size-6.5 shrink-0 items-center justify-center rounded-full transition-colors"
            style={{
              backgroundColor: lampOn ? '#ff9500' : 'rgba(255,255,255,0.16)',
              color: '#ffffff',
            }}
          >
            <LampDesk className="size-3.5" aria-hidden="true" />
          </button>
        </div>
      </div>
    </aside>
  );
}
