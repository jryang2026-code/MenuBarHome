import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type RefObject,
} from 'react';
import {
  Blinds,
  ChevronDown,
  ChevronRight,
  Droplets,
  Home,
  LampDesk,
  LayoutGrid,
  Lightbulb,
  Mic,
  Monitor,
  Moon,
  PlugZap,
  Power,
  RefreshCw,
  RotateCcw,
  Search,
  ShieldCheck,
  Snowflake,
  Sparkles,
  Sun,
  Thermometer,
  Video,
  X,
} from 'lucide-react';
import {
  kelvinToHex,
  useHomeStore,
  type RoomFilter,
  type ScenePreset,
} from '../../store/homeStore';
import { playTactileSound } from '../../utils/tactileSound';
import { handleTablistKeyDown } from '../../utils/tablist';
import type { Locale, SiteDictionary } from '../../content/siteCopy';
import {
  NATIVE_POPOVER_COPY,
  STUDY_CLIMATE_24H,
} from './nativePopoverCopy';
import { CameraCardMiniPreview } from './CameraLiveDrawer';

interface MenuBarPopoverProps {
  copy: SiteDictionary['hero']['popover'];
  presetsCopy: SiteDictionary['hero']['presets'];
  locale: Locale;
  searchInputRef: RefObject<HTMLInputElement | null>;
}

type NavigableDeviceId =
  | 'lamp'
  | 'ceiling'
  | 'ac'
  | 'curtains'
  | 'lightBar'
  | 'plug'
  | 'camera';

const HOLD_DURATION_MS = 600;
const ROOMS: RoomFilter[] = ['all', 'study', 'living', 'entry'];

/** Inline 24-hour temperature & humidity hover sparkline (SensorSparklineView.swift signature) */
function ClimateSparkline({
  isDark,
  onHoverIdx,
  hoverIdx,
}: {
  isDark: boolean;
  hoverIdx: number | null;
  onHoverIdx: (idx: number | null) => void;
}) {
  const minT = 23.2;
  const maxT = 26.8;
  const width = 128;
  const height = 22;

  const points = STUDY_CLIMATE_24H.map((pt, i) => {
    const x = (i / (STUDY_CLIMATE_24H.length - 1)) * width;
    const y = height - ((pt.temp - minT) / (maxT - minT)) * (height - 4) - 2;
    return { x, y, ...pt };
  });

  const linePath = points
    .map((p, i) => `${i === 0 ? 'M' : 'L'}${p.x.toFixed(1)},${p.y.toFixed(1)}`)
    .join(' ');
  const areaPath = `${linePath} L${width},${height} L0,${height} Z`;
  const activePt = hoverIdx !== null ? points[hoverIdx] : points[points.length - 1];

  return (
    <div
      className="relative mt-1.5 h-[24px] w-full cursor-crosshair"
      onPointerMove={(e) => {
        const rect = e.currentTarget.getBoundingClientRect();
        const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
        onHoverIdx(Math.round(ratio * (points.length - 1)));
      }}
      onPointerLeave={() => onHoverIdx(null)}
    >
      <svg
        viewBox={`0 0 ${width} ${height}`}
        className="h-full w-full overflow-visible"
        aria-hidden="true"
        preserveAspectRatio="none"
      >
        <defs>
          <linearGradient id="mbhSparkFill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={isDark ? '#73a1e6' : '#1c5cbf'} stopOpacity="0.28" />
            <stop offset="100%" stopColor={isDark ? '#73a1e6' : '#1c5cbf'} stopOpacity="0.0" />
          </linearGradient>
        </defs>
        <path d={areaPath} fill="url(#mbhSparkFill)" />
        <path
          d={linePath}
          fill="none"
          stroke={isDark ? '#73a1e6' : '#1c5cbf'}
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        {activePt && (
          <circle
            cx={activePt.x}
            cy={activePt.y}
            r={hoverIdx !== null ? 2.8 : 2.1}
            fill={isDark ? '#73a1e6' : '#1c5cbf'}
            stroke={isDark ? '#1e1e22' : '#ffffff'}
            strokeWidth="1.2"
          />
        )}
      </svg>
    </div>
  );
}

/**
 * Authentic Native MenuBarHome macOS Panel (`v1.4.0`)
 * Faithfully mirrors `macos-panel-themes-light.png`, `macos-panel-themes-dark.png`,
 * `macos-keyboard-search.png`, `macos-hold-to-talk.png`, and `macos-all-off-undo.png`:
 * - Simulated macOS Menu Bar anchor pill (`house + 25.8°C`)
 * - Light & Dark native Classic skins (`0.5pt` specular rims, neutral wells, vivid semantic orbs)
 * - Compact 2-column bento tiles with click-orb-to-toggle + click-body-to-expand inline drawers
 * - Interactive 0.5s Voice Dictation (`LocalIntentParser`), `⌘K` Quick Scenes / For You drawer
 * - Inline Mi Wall AC stepper, Protected Smart Plug, 24h Climate Sparkline, and Clickable Live Camera Card
 */
export function MenuBarPopover({
  copy,
  presetsCopy,
  locale,
  searchInputRef,
}: MenuBarPopoverProps) {
  const nativeCopy = NATIVE_POPOVER_COPY[locale];

  const lampOn = useHomeStore((s) => s.lampOn);
  const lampBrightness = useHomeStore((s) => s.lampBrightness);
  const lampKelvin = useHomeStore((s) => s.lampKelvin);
  const ceilingOn = useHomeStore((s) => s.ceilingOn);
  const ceilingBrightness = useHomeStore((s) => s.ceilingBrightness);
  const ceilingKelvin = useHomeStore((s) => s.ceilingKelvin);
  const lightBarOn = useHomeStore((s) => s.lightBarOn);
  const curtainOpen = useHomeStore((s) => s.curtainOpen);
  const acOn = useHomeStore((s) => s.acOn);
  const acTemp = useHomeStore((s) => s.acTemp);
  const plugOn = useHomeStore((s) => s.plugOn);
  const preset = useHomeStore((s) => s.preset);
  const panelAppearance = useHomeStore((s) => s.panelAppearance);
  const roomFilter = useHomeStore((s) => s.roomFilter);
  const expandedDevice = useHomeStore((s) => s.expandedDevice);
  const quickDrawerOpen = useHomeStore((s) => s.quickDrawerOpen);
  const cameraOpen = useHomeStore((s) => s.cameraOpen);
  const searchQuery = useHomeStore((s) => s.searchQuery);
  const undoSnapshot = useHomeStore((s) => s.undoSnapshot);
  const undoSecondsLeft = useHomeStore((s) => s.undoSecondsLeft);
  const plugProtectedFlash = useHomeStore((s) => s.plugProtectedFlash);
  const soundEnabled = useHomeStore((s) => s.soundEnabled);

  const toggleLamp = useHomeStore((s) => s.toggleLamp);
  const setLampBrightness = useHomeStore((s) => s.setLampBrightness);
  const setLampKelvin = useHomeStore((s) => s.setLampKelvin);
  const toggleCeiling = useHomeStore((s) => s.toggleCeiling);
  const setCeilingBrightness = useHomeStore((s) => s.setCeilingBrightness);
  const setCeilingKelvin = useHomeStore((s) => s.setCeilingKelvin);
  const toggleLightBar = useHomeStore((s) => s.toggleLightBar);
  const cycleCurtains = useHomeStore((s) => s.cycleCurtains);
  const setCurtainOpen = useHomeStore((s) => s.setCurtainOpen);
  const toggleAc = useHomeStore((s) => s.toggleAc);
  const stepAcTemp = useHomeStore((s) => s.stepAcTemp);
  const applyPreset = useHomeStore((s) => s.applyPreset);
  const executeAllOff = useHomeStore((s) => s.executeAllOff);
  const undoAllOff = useHomeStore((s) => s.undoAllOff);
  const tickUndoCountdown = useHomeStore((s) => s.tickUndoCountdown);
  const togglePanelAppearance = useHomeStore((s) => s.togglePanelAppearance);
  const setRoomFilter = useHomeStore((s) => s.setRoomFilter);
  const toggleExpandedDevice = useHomeStore((s) => s.toggleExpandedDevice);
  const toggleQuickDrawer = useHomeStore((s) => s.toggleQuickDrawer);
  const openCamera = useHomeStore((s) => s.openCamera);
  const closeCamera = useHomeStore((s) => s.closeCamera);
  const setSearchQuery = useHomeStore((s) => s.setSearchQuery);
  const showVoiceHud = useHomeStore((s) => s.showVoiceHud);
  const exitFocus = useHomeStore((s) => s.exitFocus);

  const [holdProgress, setHoldProgress] = useState(0);
  const [isHolding, setIsHolding] = useState(false);
  const [voiceActive, setVoiceActive] = useState(false);
  const [voiceTranscript, setVoiceTranscript] = useState('');
  const [voiceCycleIdx, setVoiceCycleIdx] = useState(0);
  const [focusedIndex, setFocusedIndex] = useState<number>(-1);
  const [sparkHoverIdx, setSparkHoverIdx] = useState<number | null>(null);
  const [refreshSpin, setRefreshSpin] = useState(false);

  const holdRafRef = useRef<number | null>(null);
  const holdTimerRef = useRef<number | null>(null);
  const holdStartRef = useRef(0);
  const holdFiredRef = useRef(false);
  const voiceTimersRef = useRef<number[]>([]);

  const isDark = panelAppearance === 'dark';

  useEffect(() => {
    if (!undoSnapshot) return;
    const id = window.setInterval(tickUndoCountdown, 500);
    return () => window.clearInterval(id);
  }, [undoSnapshot, tickUndoCountdown]);

  const clearVoiceTimers = () => {
    voiceTimersRef.current.forEach((id) => window.clearTimeout(id));
    voiceTimersRef.current = [];
  };

  const cancelHold = () => {
    if (holdRafRef.current !== null) {
      cancelAnimationFrame(holdRafRef.current);
      holdRafRef.current = null;
    }
    if (holdTimerRef.current !== null) {
      window.clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
    setIsHolding(false);
    setHoldProgress(0);
  };

  const completeHold = () => {
    if (holdFiredRef.current) return;
    holdFiredRef.current = true;
    cancelHold();
    executeAllOff();
    playTactileSound('relayOff', useHomeStore.getState().soundEnabled);
  };

  const startHold = () => {
    cancelHold();
    holdFiredRef.current = false;
    setIsHolding(true);
    holdStartRef.current = performance.now();
    holdTimerRef.current = window.setTimeout(completeHold, HOLD_DURATION_MS);

    const step = (now: number) => {
      if (holdFiredRef.current) return;
      const pct = Math.min(1, (now - holdStartRef.current) / HOLD_DURATION_MS);
      setHoldProgress(pct);
      if (pct >= 1) {
        completeHold();
        return;
      }
      holdRafRef.current = requestAnimationFrame(step);
    };
    holdRafRef.current = requestAnimationFrame(step);
  };

  useEffect(
    () => () => {
      cancelHold();
      clearVoiceTimers();
    },
    []
  );

  // Trigger interactive Hold-to-Talk LocalIntentParser simulation (matching macos-hold-to-talk.png)
  const triggerVoiceCommand = () => {
    clearVoiceTimers();
    if (voiceActive) {
      setVoiceActive(false);
      setVoiceTranscript('');
      return;
    }

    const cmd = nativeCopy.voiceCommands[voiceCycleIdx % nativeCopy.voiceCommands.length];
    setVoiceCycleIdx((idx) => idx + 1);
    setVoiceActive(true);
    setVoiceTranscript('');
    playTactileSound('click', soundEnabled);

    const chars = Array.from(cmd.transcript);
    const stepMs = Math.max(28, Math.floor(620 / Math.max(chars.length, 1)));
    chars.forEach((_, idx) => {
      const tId = window.setTimeout(() => {
        setVoiceTranscript(chars.slice(0, idx + 1).join(''));
      }, 140 + idx * stepMs);
      voiceTimersRef.current.push(tId);
    });

    const execTimer = window.setTimeout(() => {
      const store = useHomeStore.getState();
      if (cmd.action === 'ceiling40') {
        store.setCeilingBrightness(40);
      } else if (cmd.action === 'curtain50') {
        store.setCurtainOpen(50);
      } else {
        store.setLampBrightness(Math.max(store.lampBrightness, 60));
        store.setLampKelvin(2200);
      }
      playTactileSound('relayOn', store.soundEnabled);
      store.showVoiceHud(`${nativeCopy.voiceParserBadge} · ${cmd.feedback}`, 3200);
    }, 920);
    voiceTimersRef.current.push(execTimer);

    const doneTimer = window.setTimeout(() => {
      setVoiceActive(false);
      setVoiceTranscript('');
    }, 1750);
    voiceTimersRef.current.push(doneTimer);
  };

  // Run natural-language LocalIntentParser when hitting Return on non-matching text
  const runLocalIntentQuery = (raw: string): boolean => {
    const text = raw.trim().toLowerCase();
    if (!text) return false;
    const store = useHomeStore.getState();
    const pctMatch = text.match(/(\d{1,3})\s*%/);
    if (pctMatch) {
      const val = Number(pctMatch[1]);
      if (text.includes('ceil') || text.includes('吸顶') || text.includes('xdd')) {
        store.setCeilingBrightness(val);
        showVoiceHud(`${nativeCopy.voiceParserBadge} · ${copy.ceilingName} → ${val}%`);
        return true;
      }
      if (text.includes('curt') || text.includes('窗帘') || text.includes('cl')) {
        store.setCurtainOpen(val);
        showVoiceHud(`${nativeCopy.voiceParserBadge} · ${copy.curtainsName} → ${val}%`);
        return true;
      }
      store.setLampBrightness(val);
      showVoiceHud(`${nativeCopy.voiceParserBadge} · ${copy.lampName} → ${val}%`);
      return true;
    }
    if (text.includes('undo') || text.includes('撤销')) {
      store.undoAllOff();
      return true;
    }
    if (text.includes('warm') || text.includes('暖')) {
      store.setLampKelvin(2200);
      showVoiceHud(`${nativeCopy.voiceParserBadge} · ${copy.lampName} → 2200K`);
      return true;
    }
    return false;
  };

  const q = searchQuery.trim().toLowerCase();

  // Room + Pinyin/Name filtering matching PanelSearch.swift
  const selectRoom = (room: RoomFilter) => {
    setRoomFilter(room);
    if (q) setSearchQuery('');
    playTactileSound('tick', soundEnabled);
  };

  const matchesRoom = (room: RoomFilter) => roomFilter === 'all' || roomFilter === room;

  const showLamp =
    (q
      ? 'sftd sf td study desk lamp 台灯 书房台灯 light 灯'.includes(q) ||
        copy.lampName.toLowerCase().includes(q)
      : matchesRoom('study'));
  const showCeiling =
    (q
      ? 'xdd ktxdd ceiling living light 吸顶灯 客厅吸顶灯 灯'.includes(q) ||
        copy.ceilingName.toLowerCase().includes(q)
      : matchesRoom('living'));
  const showAc =
    (q
      ? 'kt ac air wall cool climate 空调 壁挂空调 制冷 书房'.includes(q) ||
        copy.acName.toLowerCase().includes(q)
      : matchesRoom('study'));
  const showCurtains =
    (q
      ? 'cl ddc curtain cover sunset 窗帘 电动窗帘 书房'.includes(q) ||
        copy.curtainsName.toLowerCase().includes(q)
      : matchesRoom('study'));
  const showLightBar =
    (q
      ? 'gd xsq monitor light bar 挂灯 显示器挂灯 屏幕 书房'.includes(q) ||
        copy.lightBarName.toLowerCase().includes(q)
      : matchesRoom('study'));
  const showPlug =
    (q
      ? 'cz plug smart protected socket 插座 智能插座 42w 书房'.includes(q) ||
        copy.plugName.toLowerCase().includes(q)
      : matchesRoom('study'));
  const showSensor =
    (q
      ? 'wsd temp humidity climate sensor 温湿度 温度 湿度 书房'.includes(q) ||
        nativeCopy.sensorTitle.toLowerCase().includes(q)
      : matchesRoom('study'));
  const showCamera =
    (q
      ? 'cam sxt ml doorbell video pip ptz go2rtc 摄像头 门铃 前门 玄关'.includes(q) ||
        nativeCopy.cameraCardTitle.toLowerCase().includes(q)
      : matchesRoom('entry'));

  const visibleNavIds = useMemo<NavigableDeviceId[]>(() => {
    const list: NavigableDeviceId[] = [];
    if (showLamp) list.push('lamp');
    if (showCeiling) list.push('ceiling');
    if (showAc) list.push('ac');
    if (showCurtains) list.push('curtains');
    if (showLightBar) list.push('lightBar');
    if (showPlug) list.push('plug');
    if (showCamera) list.push('camera');
    return list;
  }, [showLamp, showCeiling, showAc, showCurtains, showLightBar, showPlug, showCamera]);

  // Auto-highlight top search match with native blue ring (macos-keyboard-search.png)
  useEffect(() => {
    if (q) {
      setFocusedIndex(visibleNavIds.length > 0 ? 0 : -1);
    } else {
      setFocusedIndex(-1);
    }
  }, [q, visibleNavIds.length]);

  const focusedId: NavigableDeviceId | null =
    focusedIndex >= 0 && focusedIndex < visibleNavIds.length
      ? visibleNavIds[focusedIndex]
      : null;

  const activateDeviceId = (id: NavigableDeviceId) => {
    if (id === 'lamp') toggleLamp();
    else if (id === 'ceiling') toggleCeiling();
    else if (id === 'ac') toggleAc();
    else if (id === 'curtains') cycleCurtains();
    else if (id === 'lightBar') toggleLightBar();
    else if (id === 'camera') openCamera();
    else if (id === 'plug') showVoiceHud(nativeCopy.plugProtectedNote, 1800);
    playTactileSound('click', soundEnabled);
  };

  const handleSearchKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.nativeEvent.isComposing || e.keyCode === 229) return;
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (visibleNavIds.length > 0) {
        setFocusedIndex((prev) => (prev + 1) % visibleNavIds.length);
      }
      return;
    }
    if (e.key === 'ArrowUp') {
      e.preventDefault();
      if (visibleNavIds.length > 0) {
        setFocusedIndex((prev) => (prev <= 0 ? visibleNavIds.length - 1 : prev - 1));
      }
      return;
    }
    if (e.key === 'Enter') {
      e.preventDefault();
      if (focusedId) {
        activateDeviceId(focusedId);
        return;
      }
      if (runLocalIntentQuery(searchQuery)) {
        setSearchQuery('');
        playTactileSound('relayOn', soundEnabled);
      }
      return;
    }
    if (e.key === 'Escape') {
      e.stopPropagation();
      if (searchQuery) {
        setSearchQuery('');
      } else {
        searchInputRef.current?.blur();
      }
    }
  };

  const activeCount =
    (lampOn ? 1 : 0) +
    (ceilingOn ? 1 : 0) +
    (lightBarOn ? 1 : 0) +
    (acOn ? 1 : 0) +
    (plugOn ? 1 : 0);

  const nonProtectedOnCount =
    (lampOn ? 1 : 0) + (ceilingOn ? 1 : 0) + (lightBarOn ? 1 : 0) + (acOn ? 1 : 0);

  const totalVisibleDevices =
    visibleNavIds.length + (showSensor ? 1 : 0);

  const curtainStatus =
    curtainOpen > 70
      ? copy.curtainsOpen
      : curtainOpen > 25
        ? copy.curtainsHalf
        : copy.curtainsClosed;

  const plugFlashActive = Date.now() - plugProtectedFlash < 1800;
  const ringCircumference = 2 * Math.PI * 7.5;

  const quickPresets: Array<{ id: ScenePreset; label: string }> = [
    { id: 'evening', label: presetsCopy.evening },
    { id: 'focus', label: presetsCopy.focus },
    { id: 'movie', label: presetsCopy.movie },
  ];

  // Native TileSurface styling helpers (Classic Light vs Classic Dark)
  const shellStyle = isDark
    ? {
        background:
          'linear-gradient(164deg, rgba(40, 40, 44, 0.90) 0%, rgba(28, 28, 32, 0.86) 55%, rgba(34, 34, 38, 0.90) 100%)',
        backdropFilter: 'blur(38px) saturate(1.75)',
        WebkitBackdropFilter: 'blur(38px) saturate(1.75)',
        boxShadow:
          'inset 0 1px 0 rgba(255,255,255,0.18), inset 0 0 0 0.5px rgba(255,255,255,0.10), 0 30px 68px -20px rgba(10,8,6,0.68)',
      }
    : undefined;

  const tileClasses = (active: boolean, focused: boolean) => {
    const base =
      'relative rounded-[18px] transition-[background-color,box-shadow,transform] duration-150';
    if (isDark) {
      return `${base} ${
        active
          ? 'bg-white/[0.13] hover:bg-white/[0.16] text-[#f5f3ef]'
          : 'bg-white/[0.06] hover:bg-white/[0.09] text-[#d6d2cb]'
      } ${
        focused
          ? 'ring-[1.8px] ring-[#0a84ff] shadow-[0_0_0_3px_rgba(10,132,255,0.22)]'
          : 'ring-1 ring-white/[0.10]'
      }`;
    }
    return `${base} ${
      active
        ? 'bg-white/[0.84] hover:bg-white/[0.92] text-[#1a1612] shadow-[inset_0_1px_0_rgba(255,255,255,0.95),0_4px_14px_-8px_rgba(42,28,14,0.18)]'
        : 'bg-white/[0.46] hover:bg-white/[0.62] text-[#2c2620] shadow-[inset_0_1px_0_rgba(255,255,255,0.72)]'
    } ${
      focused
        ? 'ring-[1.8px] ring-[#007aff] shadow-[0_0_0_3px_rgba(0,122,255,0.18)]'
        : 'ring-1 ring-black/[0.06]'
    }`;
  };

  const textPrimary = isDark ? 'text-[#f6f4f0]' : 'text-[#1a1612]';
  const textSecondary = isDark ? 'text-[#a39f98]' : 'text-[#5b5349]';
  const textMuted = isDark ? 'text-[#848079]' : 'text-[#71685e]';

  const hoveredClimate =
    sparkHoverIdx !== null ? STUDY_CLIMATE_24H[sparkHoverIdx] : STUDY_CLIMATE_24H[STUDY_CLIMATE_24H.length - 1];

  const handleForYouChip = (
    id: 'ceiling40' | 'curtainsHalf' | 'acCool25' | 'nightLamp'
  ) => {
    if (id === 'ceiling40') {
      setCeilingBrightness(40);
    } else if (id === 'curtainsHalf') {
      setCurtainOpen(50);
    } else if (id === 'acCool25') {
      if (!acOn) toggleAc();
      if (acTemp !== 25) stepAcTemp(25 - acTemp);
    } else {
      setLampBrightness(24);
      setLampKelvin(2100);
    }
    playTactileSound('click', soundEnabled);
  };

  return (
    <div className="flex w-full max-w-[372px] flex-col items-end gap-1.5 select-none">
      {/* Simulated macOS Menu Bar Status Anchor Pill (exact top strip above the panel) */}
      <div
        data-ui="true"
        title={nativeCopy.menuBarTip}
        className={`inline-flex h-6.5 items-center gap-2 rounded-full px-2.5 text-[11px] font-medium tabular-nums backdrop-blur-xl transition-colors ${
          isDark
            ? 'bg-[#202024]/88 text-[#f5f3ef] ring-1 ring-white/14'
            : 'bg-white/78 text-[#1a1612] ring-1 ring-black/10 shadow-xs'
        }`}
      >
        <span
          className={`inline-flex items-center gap-1.5 rounded-full px-1.5 py-0.5 ${
            isDark ? 'bg-white/14' : 'bg-black/[0.07]'
          }`}
        >
          <Home className="size-3 text-[#ff9500]" strokeWidth={2.3} aria-hidden="true" />
          <span className="font-semibold">25.8°C</span>
        </span>
        <span className="h-3 w-px bg-current opacity-15" aria-hidden="true" />
        <span className="text-[10.5px] opacity-80">
          {activeCount} {nativeCopy.activeUnit}
        </span>
        <span className="text-[10.5px] opacity-60">17:42</span>
      </div>

      {/* Main Native MenuBarHome macOS Classic Panel */}
      <div
        data-ui="true"
        style={shellStyle}
        className={`${isDark ? '[&_:focus-visible]:outline-[#fbbf24]' : 'classic-lg-shell'} w-full rounded-[24px] p-3 ${textPrimary}`}
        aria-label={nativeCopy.a11y.panel}
      >
        {/* 1. Native Header: Orange House Orb + Title + Demo Pill + Hold All Off with Excl. Sub-Note */}
        <div className="mb-2 flex items-start justify-between gap-2">
          <div className="flex min-w-0 items-center gap-2.5">
            <span
              className="flex size-9 shrink-0 items-center justify-center rounded-full bg-[#ff9500] text-white"
              style={{
                boxShadow:
                  'inset 0 1.5px 1px rgba(255,255,255,0.45), 0 6px 14px -4px rgba(255, 149, 0, 0.55)',
              }}
            >
              <Home className="size-4.5" strokeWidth={2.2} aria-hidden="true" />
            </span>
            <div className="min-w-0 leading-tight">
              <div className="flex items-center gap-1.5">
                <span className={`truncate text-[14px] font-semibold tracking-[-0.02em] ${textPrimary}`}>
                  {nativeCopy.homeTitle}
                </span>
                <span
                  className={`shrink-0 rounded-full px-1.5 py-[1px] text-[9.5px] font-medium ${
                    isDark
                      ? 'bg-white/10 text-[#b8b4ad]'
                      : 'bg-black/[0.06] text-[#5b5349]'
                  }`}
                >
                  {nativeCopy.demoBadge}
                </span>
              </div>
              <div className={`mt-0.5 text-[10.5px] font-medium tabular-nums ${textSecondary}`}>
                {activeCount} {nativeCopy.activeUnit} · {nativeCopy.studyClimateShort}
              </div>
            </div>
          </div>

          {/* Right: 0.6s Hold All Off Capsule + Authentic Micro Sub-Note ("全关不含插座等 2 台") */}
          <div className="flex shrink-0 flex-col items-end">
            <button
              type="button"
              aria-label={`${nativeCopy.allOffButton(nonProtectedOnCount)} (${copy.holdHint})`}
              onPointerDown={(e) => {
                try {
                  e.currentTarget.setPointerCapture(e.pointerId);
                } catch {
                  // Ignore synthetic events
                }
                startHold();
              }}
              onPointerUp={cancelHold}
              onPointerCancel={cancelHold}
              onPointerLeave={cancelHold}
              onKeyDown={(e) => {
                if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) {
                  e.preventDefault();
                  startHold();
                }
              }}
              onKeyUp={(e) => {
                if (e.key === ' ' || e.key === 'Enter') {
                  cancelHold();
                }
              }}
              className={`btn-tactile relative inline-flex h-7 items-center gap-1.5 rounded-full px-2.5 text-[11px] font-semibold whitespace-nowrap ${
                isDark
                  ? 'bg-white/[0.11] text-[#f6f4f0] ring-1 ring-white/14 hover:bg-white/[0.16]'
                  : 'liquid-glass-pill text-[#1a1612]'
              }`}
            >
              <span className="relative flex size-4 items-center justify-center">
                <svg width="17" height="17" viewBox="0 0 20 20" className="-rotate-90" aria-hidden="true">
                  <circle
                    cx="10"
                    cy="10"
                    r="7.5"
                    fill="none"
                    stroke={isDark ? 'rgba(255,255,255,0.18)' : 'rgba(38,30,22,0.15)'}
                    strokeWidth="2"
                  />
                  <circle
                    cx="10"
                    cy="10"
                    r="7.5"
                    fill="none"
                    stroke="#ff9500"
                    strokeWidth="2.3"
                    strokeDasharray={ringCircumference}
                    strokeDashoffset={ringCircumference * (1 - holdProgress)}
                    strokeLinecap="round"
                  />
                </svg>
                <Power className="absolute size-2.5" strokeWidth={2.4} aria-hidden="true" />
              </span>
              <span className="tabular-nums">
                {isHolding
                  ? nativeCopy.allOffHolding
                  : nativeCopy.allOffButton(nonProtectedOnCount)}
              </span>
            </button>
            <span className={`mt-0.5 text-[9.5px] font-medium ${textMuted}`}>
              {nativeCopy.allOffExcludes}
            </span>
          </div>
        </div>

        {/* 2. Native Search + Click/Hold-to-Talk Voice Dictation Pill */}
        <div className="relative mb-2">
          <label htmlFor="mbh-hero-search" className="visually-hidden">
            {nativeCopy.searchPlaceholder}
          </label>

          {voiceActive ? (
            <div
              className={`flex h-8.5 w-full items-center justify-between gap-2 rounded-full px-3 text-[12px] font-medium ring-[1.5px] ring-[#ff453a]/70 ${
                isDark ? 'bg-[#2a2224]/90 text-white' : 'bg-white/90 text-[#1a1612]'
              }`}
            >
              <span className="flex min-w-0 items-center gap-2">
                {/* Tiny live waveform bars matching macos-hold-to-talk.png */}
                <span className="flex items-end gap-[2px]" aria-hidden="true">
                  <span className="h-2.5 w-[2px] animate-pulse rounded-full bg-[#ff453a]" />
                  <span className="h-3.5 w-[2px] animate-pulse rounded-full bg-[#ff453a]" />
                  <span className="h-2 w-[2px] animate-pulse rounded-full bg-[#ff453a]" />
                </span>
                <span className="truncate">
                  {voiceTranscript || nativeCopy.voiceListening}
                </span>
              </span>
              <button
                type="button"
                onClick={triggerVoiceCommand}
                aria-label={nativeCopy.a11y.stopDictation}
                className="flex size-5 shrink-0 items-center justify-center rounded-full bg-[#ff453a] text-white"
              >
                <span className="size-1.5 rounded-[1.5px] bg-white" />
              </button>
            </div>
          ) : (
            <>
              <Search
                className={`pointer-events-none absolute top-1/2 left-3 z-10 size-3.5 -translate-y-1/2 ${textSecondary}`}
                aria-hidden="true"
              />
              <input
                ref={searchInputRef}
                id="mbh-hero-search"
                type="text"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                onKeyDown={handleSearchKeyDown}
                placeholder={nativeCopy.searchPlaceholder}
                className={`h-8.5 w-full rounded-full pr-16 pl-8.5 text-[12px] font-medium ${
                  isDark
                    ? 'bg-white/[0.08] text-[#f6f4f0] ring-1 ring-white/12 placeholder:text-[#8c8881] focus-visible:ring-[1.6px] focus-visible:ring-[#0a84ff]'
                    : 'liquid-glass-pill text-[#1a1612] placeholder:text-[#6b6258] focus-visible:ring-[1.6px] focus-visible:ring-[#007aff]'
                }`}
              />
              <div className="absolute top-1/2 right-2 z-10 flex -translate-y-1/2 items-center gap-1">
                {searchQuery && (
                  <>
                    <span className={`text-[10px] font-medium tabular-nums ${textMuted}`}>
                      {nativeCopy.searchMatches(totalVisibleDevices)}
                    </span>
                    <button
                      type="button"
                      aria-label={nativeCopy.a11y.clearSearch}
                      onClick={() => setSearchQuery('')}
                      className={`rounded-full p-0.5 ${textSecondary} hover:opacity-100`}
                    >
                      <X className="size-3.5" aria-hidden="true" />
                    </button>
                  </>
                )}
                <button
                  type="button"
                  onClick={triggerVoiceCommand}
                  title={nativeCopy.voiceHoldHint}
                  aria-label={nativeCopy.voiceHoldHint}
                  className={`btn-tactile flex size-6 items-center justify-center rounded-full transition-colors ${
                    isDark
                      ? 'text-[#60a5fa] hover:bg-white/10'
                      : 'text-[#007aff] hover:bg-[#007aff]/10'
                  }`}
                >
                  <Mic className="size-3.5" strokeWidth={2.2} aria-hidden="true" />
                </button>
              </div>
            </>
          )}
        </div>

        {/* 3. Native Room Filter Segmented Bar + ⌘K Quick Drawer & Light/Dark Theme Icons */}
        <div className="mb-2 flex items-center justify-between gap-1.5">
          <div
            role="tablist"
            aria-label={nativeCopy.a11y.roomFilter}
            onKeyDown={(e) => handleTablistKeyDown(e, ROOMS, roomFilter, selectRoom)}
            className={`flex flex-1 items-center gap-0.5 rounded-full p-0.5 ${
              isDark ? 'bg-white/[0.07]' : 'liquid-glass-track'
            }`}
          >
            {ROOMS.map((room) => {
              const active = roomFilter === room && !q;
              return (
                <button
                  key={room}
                  role="tab"
                  type="button"
                  id={`popover-room-tab-${room}`}
                  aria-controls="popover-device-panel"
                  aria-selected={active}
                  tabIndex={room === roomFilter ? 0 : -1}
                  onClick={() => selectRoom(room)}
                  className={`btn-tactile flex-1 rounded-full py-1 text-[11px] font-medium ${
                    active
                      ? isDark
                        ? 'bg-white/[0.20] text-white shadow-xs'
                        : 'bg-white text-[#1a1612] shadow-xs'
                      : `${textSecondary} hover:opacity-100`
                  }`}
                >
                  {nativeCopy.rooms[room]}
                </button>
              );
            })}
          </div>

          {/* ⌘K Quick Actions / For You Drawer Button */}
          <button
            type="button"
            aria-pressed={quickDrawerOpen}
            aria-label={`${nativeCopy.quickDrawerTitle} (⌘K)`}
            title={`${nativeCopy.quickDrawerTitle} (⌘K)`}
            onClick={() => {
              toggleQuickDrawer();
              playTactileSound('tick', soundEnabled);
            }}
            className={`btn-tactile flex size-7 shrink-0 items-center justify-center rounded-full ${
              quickDrawerOpen
                ? 'bg-[#007aff] text-white shadow-xs'
                : isDark
                  ? 'bg-white/[0.09] text-[#d6d2cb] hover:bg-white/[0.15]'
                  : 'liquid-glass-pill text-[#3b332b]'
            }`}
          >
            <LayoutGrid className="size-3.5" aria-hidden="true" />
          </button>

          {/* Native Light / Dark Appearance Toggle */}
          <button
            type="button"
            aria-label={isDark ? nativeCopy.appearanceDark : nativeCopy.appearanceLight}
            title={isDark ? nativeCopy.appearanceDark : nativeCopy.appearanceLight}
            onClick={() => {
              togglePanelAppearance();
              playTactileSound('tick', soundEnabled);
            }}
            className={`btn-tactile flex size-7 shrink-0 items-center justify-center rounded-full ${
              isDark
                ? 'bg-white/[0.09] text-[#fbbf24] hover:bg-white/[0.15]'
                : 'liquid-glass-pill text-[#3b332b]'
            }`}
          >
            {isDark ? (
              <Sun className="size-3.5" aria-hidden="true" />
            ) : (
              <Moon className="size-3.5" aria-hidden="true" />
            )}
          </button>
        </div>

        {/* Collapsible ⌘K Quick Scenes & "For You" Drawer */}
        {quickDrawerOpen && (
          <div
            className={`mb-2 rounded-[16px] p-2.5 ${
              isDark
                ? 'bg-white/[0.07] ring-1 ring-white/10'
                : 'bg-white/[0.66] ring-1 ring-black/[0.06]'
            }`}
          >
            <div className="mb-1.5 flex items-center justify-between text-[10px] font-semibold">
              <span className="inline-flex items-center gap-1 text-[#007aff]">
                <Sparkles className="size-3" aria-hidden="true" />
                <span>{nativeCopy.forYouLabel}</span>
              </span>
              <span className={`font-mono text-[9.5px] ${textMuted}`}>⌘K</span>
            </div>
            <div className="mb-2 flex flex-wrap gap-1">
              {nativeCopy.forYouChips.map((chip) => (
                <button
                  key={chip.id}
                  type="button"
                  onClick={() => handleForYouChip(chip.id)}
                  className={`btn-tactile rounded-full px-2 py-0.5 text-[10.5px] font-medium ${
                    isDark
                      ? 'bg-white/[0.10] text-[#f5f3ef] hover:bg-white/[0.17]'
                      : 'bg-white/90 text-[#1a1612] ring-1 ring-black/[0.07] hover:bg-white'
                  }`}
                >
                  {chip.label}
                </button>
              ))}
            </div>
            <div className="flex items-center gap-1">
              {quickPresets.map((item) => {
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
                    className={`btn-tactile flex-1 rounded-full py-1 text-[10.5px] font-semibold ${
                      active
                        ? isDark
                          ? 'bg-[#ff9500] text-[#1a1612]'
                          : 'bg-[#1a1612] text-[#fbf9f5]'
                        : isDark
                          ? 'bg-white/[0.08] text-[#cfc9bf] hover:bg-white/[0.14]'
                          : 'bg-black/[0.05] text-[#3b332b] hover:bg-black/[0.09]'
                    }`}
                  >
                    {item.label}
                  </button>
                );
              })}
            </div>
          </div>
        )}

        {/* Section Count Label matching native "⌄ 全屋设备 7" */}
        <div className={`mb-1.5 flex items-center justify-between px-0.5 text-[10.5px] font-medium ${textSecondary}`}>
          <span className="inline-flex items-center gap-1">
            <ChevronDown className="size-3 opacity-70" aria-hidden="true" />
            <span>
              {q
                ? nativeCopy.sectionSearch
                : roomFilter === 'all'
                  ? nativeCopy.sectionAll
                  : nativeCopy.rooms[roomFilter]}
            </span>
            <span className={`tabular-nums ${textMuted}`}>{totalVisibleDevices}</span>
          </span>
          {!quickDrawerOpen && (
            <div className="flex items-center gap-1">
              {quickPresets.map((item) => {
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
                    className={`btn-tactile rounded-full px-1.5 py-[1px] text-[10px] font-medium ${
                      active
                        ? isDark
                          ? 'bg-white/18 text-white'
                          : 'bg-[#1a1612] text-[#fbf9f5]'
                        : `${textMuted} hover:opacity-100`
                    }`}
                  >
                    {item.label}
                  </button>
                );
              })}
            </div>
          )}
        </div>

        {/* 4. Scroll-Safe Compact Native Bento Device Grid */}
        <div
          id="popover-device-panel"
          role="tabpanel"
          aria-labelledby={`popover-room-tab-${roomFilter}`}
          className="max-h-[calc(100svh-360px)] space-y-2 overflow-y-auto pr-0.5"
        >
          {/* Empty Search Fallback → LocalIntentParser hint (matches macos-hold-to-talk.png) */}
          {totalVisibleDevices === 0 && (
            <div
              className={`rounded-[16px] px-3 py-5 text-center ${
                isDark ? 'bg-white/[0.05]' : 'bg-white/[0.52]'
              }`}
            >
              <Search className={`mx-auto mb-1.5 size-5 opacity-45 ${textSecondary}`} aria-hidden="true" />
              <div className={`text-[12px] font-semibold ${textPrimary}`}>
                {nativeCopy.searchEmptyTitle}
              </div>
              <div className={`mt-0.5 text-[10.5px] ${textMuted}`}>
                {nativeCopy.searchEmptyHint}
              </div>
            </div>
          )}

          {/* Row 1: Desk Lamp + Ceiling Light (2-column compact native capsules, orb toggles / body expands!) */}
          {(showLamp || showCeiling) && (
            <div className="space-y-1.5">
              <div className={`grid gap-2 ${showLamp && showCeiling ? 'grid-cols-2' : 'grid-cols-1'}`}>
                {showLamp && (
                  <div className={`${tileClasses(lampOn, focusedId === 'lamp')} flex items-center gap-1.5 px-2 py-2`}>
                    <button
                      type="button"
                      aria-label={nativeCopy.a11y.toggleDevice(copy.lampName)}
                      aria-pressed={lampOn}
                      onClick={() => {
                        toggleLamp();
                        playTactileSound(lampOn ? 'relayOff' : 'relayOn', soundEnabled);
                      }}
                      className="btn-tactile flex size-8.5 shrink-0 items-center justify-center rounded-full transition-colors"
                      style={{
                        backgroundColor: lampOn
                          ? '#ff9500'
                          : isDark
                            ? 'rgba(255, 149, 0, 0.18)'
                            : 'rgba(255, 149, 0, 0.15)',
                        color: lampOn ? '#ffffff' : '#e07b00',
                        boxShadow: lampOn ? '0 4px 12px -3px rgba(255, 149, 0, 0.55)' : 'none',
                      }}
                    >
                      <LampDesk className="size-4" strokeWidth={2.2} aria-hidden="true" />
                    </button>
                    <button
                      type="button"
                      aria-expanded={expandedDevice === 'lamp'}
                      onClick={() => {
                        toggleExpandedDevice('lamp');
                        playTactileSound('tick', soundEnabled);
                      }}
                      className="flex min-w-0 flex-1 items-center justify-between gap-0.5 text-left"
                    >
                      <span className="min-w-0">
                        <span className={`block truncate text-[12px] font-semibold ${textPrimary}`}>
                          {nativeCopy.tileLabels.lamp}
                        </span>
                        <span className={`block truncate text-[10.5px] font-medium tabular-nums ${textSecondary}`}>
                          {lampOn ? `${lampBrightness}%, ${lampKelvin}K` : copy.offLabel}
                        </span>
                      </span>
                      <ChevronRight
                        className={`size-3.5 shrink-0 transition-transform duration-150 ${textMuted} ${
                          expandedDevice === 'lamp' ? 'rotate-90' : ''
                        }`}
                        aria-hidden="true"
                      />
                    </button>
                  </div>
                )}

                {showCeiling && (
                  <div className={`${tileClasses(ceilingOn, focusedId === 'ceiling')} flex items-center gap-1.5 px-2 py-2`}>
                    <button
                      type="button"
                      aria-label={nativeCopy.a11y.toggleDevice(copy.ceilingName)}
                      aria-pressed={ceilingOn}
                      onClick={() => {
                        toggleCeiling();
                        playTactileSound(ceilingOn ? 'relayOff' : 'relayOn', soundEnabled);
                      }}
                      className="btn-tactile flex size-8.5 shrink-0 items-center justify-center rounded-full transition-colors"
                      style={{
                        backgroundColor: ceilingOn
                          ? '#ff9500'
                          : isDark
                            ? 'rgba(255, 149, 0, 0.18)'
                            : 'rgba(255, 149, 0, 0.15)',
                        color: ceilingOn ? '#ffffff' : '#e07b00',
                        boxShadow: ceilingOn ? '0 4px 12px -3px rgba(255, 149, 0, 0.55)' : 'none',
                      }}
                    >
                      <Lightbulb className="size-4" strokeWidth={2.2} aria-hidden="true" />
                    </button>
                    <button
                      type="button"
                      aria-expanded={expandedDevice === 'ceiling'}
                      onClick={() => {
                        toggleExpandedDevice('ceiling');
                        playTactileSound('tick', soundEnabled);
                      }}
                      className="flex min-w-0 flex-1 items-center justify-between gap-0.5 text-left"
                    >
                      <span className="min-w-0">
                        <span className={`block truncate text-[12px] font-semibold ${textPrimary}`}>
                          {nativeCopy.tileLabels.ceiling}
                        </span>
                        <span className={`block truncate text-[10.5px] font-medium tabular-nums ${textSecondary}`}>
                          {ceilingOn ? `${ceilingBrightness}%, ${ceilingKelvin}K` : copy.offLabel}
                        </span>
                      </span>
                      <ChevronRight
                        className={`size-3.5 shrink-0 transition-transform duration-150 ${textMuted} ${
                          expandedDevice === 'ceiling' ? 'rotate-90' : ''
                        }`}
                        aria-hidden="true"
                      />
                    </button>
                  </div>
                )}
              </div>

              {/* Inline Detail Drawer for Desk Lamp or Ceiling Light (native 12-14px rounded sub-panel) */}
              {(expandedDevice === 'lamp' || expandedDevice === 'ceiling') && (
                <div
                  className={`rounded-[14px] px-3 py-2.5 ${
                    isDark
                      ? 'bg-white/[0.08] ring-1 ring-white/10'
                      : 'bg-white/[0.76] ring-1 ring-black/[0.06]'
                  }`}
                >
                  {(() => {
                    const isCeil = expandedDevice === 'ceiling';
                    const isOn = isCeil ? ceilingOn : lampOn;
                    const bri = isCeil ? ceilingBrightness : lampBrightness;
                    const kel = isCeil ? ceilingKelvin : lampKelvin;
                    const hex = kelvinToHex(kel);
                    return (
                      <div className="space-y-2">
                        <div className="flex items-center justify-between text-[10.5px] font-medium tabular-nums">
                          <label htmlFor="mbh-inline-brightness" className={textSecondary}>
                            {isCeil ? copy.ceilingName : copy.lampName} · {copy.brightness}
                          </label>
                          <span className={`font-semibold ${textPrimary}`}>
                            {isOn ? `${bri}%` : '0%'}
                          </span>
                        </div>
                        <input
                          id="mbh-inline-brightness"
                          type="range"
                          min={0}
                          max={100}
                          value={isOn ? bri : 0}
                          onChange={(e) => {
                            const v = Number(e.target.value);
                            if (isCeil) setCeilingBrightness(v);
                            else setLampBrightness(v);
                          }}
                          className="mbh-slider"
                          style={{
                            background: `linear-gradient(90deg, #ffc24d 0%, #f2861c ${isOn ? bri : 0}%, ${
                              isDark ? 'rgba(255,255,255,0.14)' : 'rgba(38,30,22,0.12)'
                            } ${isOn ? bri : 0}%)`,
                            borderRadius: '9999px',
                            height: '6px',
                          }}
                        />

                        <div className="flex items-center justify-between text-[10.5px] font-medium tabular-nums">
                          <label htmlFor="mbh-inline-kelvin" className={`flex items-center gap-1.5 ${textSecondary}`}>
                            <span>{copy.kelvin}</span>
                            <span
                              className="inline-block size-2 rounded-full ring-1 ring-black/15"
                              style={{ backgroundColor: hex }}
                              aria-hidden="true"
                            />
                          </label>
                          <span className={`font-semibold ${textPrimary}`}>{kel}K</span>
                        </div>
                        <input
                          id="mbh-inline-kelvin"
                          type="range"
                          min={isCeil ? 2700 : 1900}
                          max={6500}
                          step={100}
                          value={kel}
                          onChange={(e) => {
                            const v = Number(e.target.value);
                            if (isCeil) setCeilingKelvin(v);
                            else setLampKelvin(v);
                          }}
                          className="mbh-slider"
                          style={{
                            background: 'linear-gradient(90deg, #fa9e29 0%, #ffe6bd 50%, #8fd1ff 100%)',
                            borderRadius: '9999px',
                            height: '6px',
                          }}
                        />

                        <div className="flex items-center gap-1.5 pt-0.5">
                          {[
                            { k: isCeil ? 2700 : 2200, label: isCeil ? '2700K' : nativeCopy.lampPresets.candle },
                            { k: 3200, label: nativeCopy.lampPresets.warm },
                            { k: 5000, label: nativeCopy.lampPresets.daylight },
                          ].map((p) => (
                            <button
                              key={p.k}
                              type="button"
                              onClick={() => {
                                if (isCeil) setCeilingKelvin(p.k);
                                else setLampKelvin(p.k);
                                playTactileSound('tick', soundEnabled);
                              }}
                              className={`btn-tactile flex-1 rounded-full py-0.5 text-[10px] font-semibold tabular-nums ${
                                Math.abs(kel - p.k) <= 200
                                  ? 'bg-[#ff9500] text-white'
                                  : isDark
                                    ? 'bg-white/10 text-[#d0cbc4] hover:bg-white/16'
                                    : 'bg-black/[0.05] text-[#453e36] hover:bg-black/[0.09]'
                              }`}
                            >
                              {p.label}
                            </button>
                          ))}
                        </div>
                      </div>
                    );
                  })()}
                </div>
              )}
            </div>
          )}

          {/* Row 2: Full-Width Inline Mi Wall AC Card (exact match to macos-panel-themes-light.png!) */}
          {showAc && (
            <div className={`${tileClasses(acOn, focusedId === 'ac')} px-2.5 pt-2 pb-1.5`}>
              <div className="flex items-center justify-between gap-2">
                <button
                  type="button"
                  onClick={() => {
                    toggleAc();
                    playTactileSound(acOn ? 'relayOff' : 'relayOn', soundEnabled);
                  }}
                  aria-pressed={acOn}
                  className="btn-tactile flex min-w-0 items-center gap-2.5 text-left"
                >
                  <span
                    className="flex size-9 shrink-0 items-center justify-center rounded-full transition-colors"
                    style={{
                      backgroundColor: acOn
                        ? '#007aff'
                        : isDark
                          ? 'rgba(255,255,255,0.10)'
                          : 'rgba(38,30,22,0.08)',
                      color: acOn ? '#ffffff' : isDark ? '#9e9a93' : '#6b6258',
                      boxShadow: acOn ? '0 4px 12px -3px rgba(0, 122, 255, 0.55)' : 'none',
                    }}
                  >
                    <Snowflake className="size-4" strokeWidth={2.2} aria-hidden="true" />
                  </span>
                  <span className="min-w-0 leading-tight">
                    <span className={`block truncate text-[12.5px] font-semibold ${textPrimary}`}>
                      {copy.acName}
                    </span>
                    <span className={`block truncate text-[10.5px] font-medium ${textSecondary}`}>
                      {nativeCopy.deviceRooms.ac}, {acOn ? copy.acCool : copy.acOff}
                    </span>
                  </span>
                </button>

                <div className="flex shrink-0 items-center gap-1.5">
                  <button
                    type="button"
                    aria-label={nativeCopy.a11y.decreaseAcTemp}
                    onClick={() => {
                      stepAcTemp(-1);
                      playTactileSound('tick', soundEnabled);
                    }}
                    className={`btn-tactile flex size-6.5 items-center justify-center rounded-full text-[14px] font-semibold ${
                      isDark
                        ? 'bg-white/[0.12] text-white hover:bg-white/[0.18]'
                        : 'bg-white text-[#1a1612] shadow-xs ring-1 ring-black/[0.08]'
                    }`}
                  >
                    −
                  </button>
                  <span className={`min-w-[44px] text-center text-[16px] font-semibold tracking-[-0.02em] tabular-nums ${textPrimary}`}>
                    {acTemp}
                    <span className="text-[11px] font-medium opacity-70">°C</span>
                  </span>
                  <button
                    type="button"
                    aria-label={nativeCopy.a11y.increaseAcTemp}
                    onClick={() => {
                      stepAcTemp(1);
                      playTactileSound('tick', soundEnabled);
                    }}
                    className={`btn-tactile flex size-6.5 items-center justify-center rounded-full text-[14px] font-semibold ${
                      isDark
                        ? 'bg-white/[0.12] text-white hover:bg-white/[0.18]'
                        : 'bg-white text-[#1a1612] shadow-xs ring-1 ring-black/[0.08]'
                    }`}
                  >
                    +
                  </button>
                </div>
              </div>
              {/* Signature subtle bottom AC temp range bar */}
              <div
                aria-hidden="true"
                className={`mt-2 h-[3px] w-full overflow-hidden rounded-full ${
                  isDark ? 'bg-white/10' : 'bg-black/[0.07]'
                }`}
              >
                <div
                  className="h-full rounded-full transition-[width,background-color] duration-200"
                  style={{
                    width: `${((acTemp - 16) / 14) * 100}%`,
                    backgroundColor: acOn ? '#007aff' : isDark ? 'rgba(255,255,255,0.22)' : 'rgba(38,30,22,0.22)',
                  }}
                />
              </div>
            </div>
          )}

          {/* Row 3: Motorized Curtains + Monitor Light Bar (2-column compact bento tiles) */}
          {(showCurtains || showLightBar) && (
            <div className="space-y-1.5">
              <div className={`grid gap-2 ${showCurtains && showLightBar ? 'grid-cols-2' : 'grid-cols-1'}`}>
                {showCurtains && (
                  <div className={`${tileClasses(curtainOpen > 15, focusedId === 'curtains')} flex items-center gap-1.5 px-2 py-2`}>
                    <button
                      type="button"
                      aria-label={nativeCopy.a11y.cycleDevice(copy.curtainsName)}
                      onClick={() => {
                        cycleCurtains();
                        playTactileSound('click', soundEnabled);
                      }}
                      className="btn-tactile flex size-8.5 shrink-0 items-center justify-center rounded-full transition-colors"
                      style={{
                        backgroundColor:
                          curtainOpen > 15
                            ? '#5c9edb'
                            : isDark
                              ? 'rgba(92,158,219,0.18)'
                              : 'rgba(92,158,219,0.16)',
                        color: curtainOpen > 15 ? '#ffffff' : '#3b7bb8',
                        boxShadow:
                          curtainOpen > 15 ? '0 4px 12px -3px rgba(92, 158, 219, 0.5)' : 'none',
                      }}
                    >
                      <Blinds className="size-4" strokeWidth={2.1} aria-hidden="true" />
                    </button>
                    <button
                      type="button"
                      aria-expanded={expandedDevice === 'curtains'}
                      onClick={() => {
                        toggleExpandedDevice('curtains');
                        playTactileSound('tick', soundEnabled);
                      }}
                      className="flex min-w-0 flex-1 items-center justify-between gap-0.5 text-left"
                    >
                      <span className="min-w-0">
                        <span className={`block truncate text-[12px] font-semibold ${textPrimary}`}>
                          {nativeCopy.tileLabels.curtains}
                        </span>
                        <span className={`block truncate text-[10.5px] font-medium tabular-nums ${textSecondary}`}>
                          {curtainOpen}% · {curtainStatus.split('·')[0].trim()}
                        </span>
                      </span>
                      <ChevronRight
                        className={`size-3.5 shrink-0 transition-transform duration-150 ${textMuted} ${
                          expandedDevice === 'curtains' ? 'rotate-90' : ''
                        }`}
                        aria-hidden="true"
                      />
                    </button>
                  </div>
                )}

                {showLightBar && (
                  <button
                    type="button"
                    aria-pressed={lightBarOn}
                    onClick={() => {
                      toggleLightBar();
                      playTactileSound(lightBarOn ? 'relayOff' : 'relayOn', soundEnabled);
                    }}
                    className={`${tileClasses(lightBarOn, focusedId === 'lightBar')} btn-tactile flex items-center gap-1.5 px-2 py-2 text-left`}
                  >
                    <span
                      className="flex size-8.5 shrink-0 items-center justify-center rounded-full transition-colors"
                      style={{
                        backgroundColor: lightBarOn
                          ? '#ff9500'
                          : isDark
                            ? 'rgba(255,149,0,0.16)'
                            : 'rgba(255,149,0,0.14)',
                        color: lightBarOn ? '#ffffff' : '#e07b00',
                      }}
                    >
                      <Monitor className="size-4" strokeWidth={2.1} aria-hidden="true" />
                    </span>
                    <span className="min-w-0">
                      <span className={`block truncate text-[12px] font-semibold ${textPrimary}`}>
                        {nativeCopy.tileLabels.lightBar}
                      </span>
                      <span className={`block truncate text-[10.5px] font-medium ${textSecondary}`}>
                        {lightBarOn ? nativeCopy.tileLabels.lightBarOn : copy.offLabel}
                      </span>
                    </span>
                  </button>
                )}
              </div>

              {/* Inline Detail Drawer for Motorized Curtains */}
              {expandedDevice === 'curtains' && (
                <div
                  className={`rounded-[14px] px-3 py-2.5 ${
                    isDark
                      ? 'bg-white/[0.08] ring-1 ring-white/10'
                      : 'bg-white/[0.76] ring-1 ring-black/[0.06]'
                  }`}
                >
                  <div className="mb-1.5 flex items-center justify-between text-[10.5px] font-medium tabular-nums">
                    <label htmlFor="mbh-inline-curtains" className={textSecondary}>
                      {copy.curtainsName}
                    </label>
                    <span className={`font-semibold ${textPrimary}`}>{curtainOpen}%</span>
                  </div>
                  <input
                    id="mbh-inline-curtains"
                    type="range"
                    min={0}
                    max={100}
                    value={curtainOpen}
                    onChange={(e) => setCurtainOpen(Number(e.target.value))}
                    className="mbh-slider"
                    style={{
                      background: `linear-gradient(90deg, #9bc5ec 0%, #5c9edb ${curtainOpen}%, ${
                        isDark ? 'rgba(255,255,255,0.14)' : 'rgba(38,30,22,0.12)'
                      } ${curtainOpen}%)`,
                      borderRadius: '9999px',
                      height: '6px',
                    }}
                  />
                  <div className="mt-2 flex items-center gap-1.5">
                    {[
                      { v: 6, label: nativeCopy.curtainStops.closed },
                      { v: 50, label: nativeCopy.curtainStops.half },
                      { v: 96, label: nativeCopy.curtainStops.open },
                    ].map((s) => (
                      <button
                        key={s.v}
                        type="button"
                        onClick={() => {
                          setCurtainOpen(s.v);
                          playTactileSound('tick', soundEnabled);
                        }}
                        className={`btn-tactile flex-1 rounded-full py-0.5 text-[10px] font-semibold ${
                          Math.abs(curtainOpen - s.v) <= 15
                            ? 'bg-[#5c9edb] text-white'
                            : isDark
                              ? 'bg-white/10 text-[#d0cbc4] hover:bg-white/16'
                              : 'bg-black/[0.05] text-[#453e36] hover:bg-black/[0.09]'
                        }`}
                      >
                        {s.label}
                      </button>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}

          {/* Row 4: Protected Smart Plug + Study Climate Sensor with 24h Sparkline */}
          {(showPlug || showSensor) && (
            <div className={`grid gap-2 ${showPlug && showSensor ? 'grid-cols-2' : 'grid-cols-1'}`}>
              {showPlug && (
                <button
                  type="button"
                  onClick={() => {
                    showVoiceHud(nativeCopy.plugProtectedNote, 2000);
                    playTactileSound('tick', soundEnabled);
                  }}
                  className={`${tileClasses(plugOn, focusedId === 'plug')} btn-tactile flex items-center gap-2 p-2.5 text-left`}
                  style={
                    plugFlashActive
                      ? {
                          boxShadow:
                            'inset 0 0 0 1.8px rgba(48, 209, 88, 0.92), 0 8px 18px -8px rgba(48, 209, 88, 0.36)',
                        }
                      : undefined
                  }
                >
                  <span
                    className="relative flex size-9 shrink-0 items-center justify-center rounded-full bg-[#30d158] text-white"
                    style={{ boxShadow: '0 4px 12px -3px rgba(48, 209, 88, 0.5)' }}
                  >
                    <PlugZap className="size-4" strokeWidth={2.2} aria-hidden="true" />
                    <ShieldCheck
                      className="absolute -right-0.5 -bottom-0.5 size-3.5 rounded-full bg-[#15803d] p-[1px] text-white"
                      aria-hidden="true"
                    />
                  </span>
                  <span className="min-w-0">
                    <span className={`block truncate text-[12px] font-semibold ${textPrimary}`}>
                      {nativeCopy.tileLabels.plug}
                    </span>
                    <span
                      className={`block truncate text-[10.5px] font-semibold tabular-nums ${
                        isDark ? 'text-[#4ade80]' : 'text-[#15803d]'
                      }`}
                    >
                      {nativeCopy.plugProtectedNote}
                    </span>
                  </span>
                </button>
              )}

              {showSensor && (
                <div className={`${tileClasses(true, false)} px-2.5 py-2`}>
                  <div className="flex items-center justify-between gap-1">
                    <span className={`inline-flex min-w-0 items-center gap-1 text-[10px] font-medium ${textSecondary}`}>
                      <Thermometer
                        className="size-3 shrink-0"
                        style={{ color: isDark ? '#73a1e6' : '#1c5cbf' }}
                        aria-hidden="true"
                      />
                      <span className="truncate">{nativeCopy.sensorTitle}</span>
                    </span>
                    <span
                      className={`shrink-0 rounded-full px-1.5 py-[1px] text-[9px] font-semibold ${
                        isDark
                          ? 'bg-[#30d158]/20 text-[#4ade80]'
                          : 'bg-[#30d158]/16 text-[#15803d]'
                      }`}
                    >
                      {sparkHoverIdx !== null ? hoveredClimate.hour : nativeCopy.sensorComfy}
                    </span>
                  </div>
                  <div className="mt-0.5 flex items-baseline gap-1.5 tabular-nums">
                    <span className={`text-[16px] leading-none font-semibold tracking-[-0.02em] ${textPrimary}`}>
                      {hoveredClimate.temp.toFixed(1)}
                      <span className="text-[10.5px] font-medium opacity-75">°C</span>
                    </span>
                    <span
                      className="inline-flex items-center gap-0.5 text-[10.5px] font-medium"
                      style={{ color: isDark ? '#4fa8a3' : '#127570' }}
                    >
                      <Droplets className="size-2.5" aria-hidden="true" />
                      {hoveredClimate.humidity}%
                    </span>
                  </div>
                  <ClimateSparkline
                    isDark={isDark}
                    hoverIdx={sparkHoverIdx}
                    onHoverIdx={setSparkHoverIdx}
                  />
                </div>
              )}
            </div>
          )}

          {/* Row 5: STANDOUT CLICKABLE CAMERA & VIDEO DOORBELL CARD (Opens Full Interactive PTZ / PiP View!) */}
          {showCamera && (
            <button
              type="button"
              data-testid="hero-camera-card"
              aria-expanded={cameraOpen}
              onClick={() => {
                if (cameraOpen) closeCamera();
                else openCamera('doorbell');
                playTactileSound('click', soundEnabled);
              }}
              className={`${tileClasses(true, focusedId === 'camera' || cameraOpen)} btn-tactile group flex w-full items-center justify-between gap-2.5 p-2 text-left`}
              style={
                cameraOpen
                  ? {
                      boxShadow: isDark
                        ? 'inset 0 0 0 1.6px #009eff, 0 8px 22px -8px rgba(0, 158, 255, 0.35)'
                        : 'inset 0 0 0 1.6px #009eff, 0 8px 20px -10px rgba(0, 158, 255, 0.28)',
                    }
                  : undefined
              }
            >
              <div className="flex min-w-0 items-center gap-2.5">
                <span
                  className="relative flex size-9 shrink-0 items-center justify-center rounded-full bg-[#009eff] text-white"
                  style={{ boxShadow: '0 4px 12px -3px rgba(0, 158, 255, 0.55)' }}
                >
                  <Video className="size-4" strokeWidth={2.2} aria-hidden="true" />
                  <span
                    className="absolute -top-0.5 -right-0.5 size-2.5 rounded-full bg-[#30d158] ring-2 ring-white"
                    aria-hidden="true"
                  />
                </span>
                <div className="min-w-0 leading-tight">
                  <div className="flex items-center gap-1.5">
                    <span className={`truncate text-[12.5px] font-semibold ${textPrimary}`}>
                      {nativeCopy.cameraCardTitle}
                    </span>
                    <span className="shrink-0 rounded-full bg-[#009eff]/16 px-1.5 py-[1px] text-[9px] font-bold tracking-wide text-[#007aff]">
                      {nativeCopy.cameraLiveBadge}
                    </span>
                  </div>
                  <div className={`mt-0.5 truncate text-[10px] font-medium ${textSecondary}`}>
                    {nativeCopy.cameraCardSubtitle}
                  </div>
                </div>
              </div>

              <div className="flex shrink-0 items-center gap-1.5">
                <CameraCardMiniPreview lampOn={lampOn} lampKelvin={lampKelvin} />
                <ChevronRight
                  className={`size-4 transition-transform duration-150 group-hover:translate-x-0.5 ${
                    cameraOpen ? 'text-[#009eff]' : textMuted
                  }`}
                  aria-hidden="true"
                />
              </div>
            </button>
          )}
        </div>

        {/* 5. Native 15s Undo Banner (matches macos-all-off-undo.png) */}
        {undoSnapshot && (
          <div
            role="status"
            aria-live="polite"
            className={`mt-2 flex items-center justify-between gap-2 rounded-[14px] px-3 py-2 text-[11px] shadow-md ${
              isDark
                ? 'bg-[#2c2c30] text-[#f6f4f0] ring-1 ring-white/14'
                : 'bg-white/95 text-[#1a1612] ring-1 ring-black/10'
            }`}
          >
            <span className="flex items-center gap-1.5 font-medium tabular-nums">
              <Power className="size-3.5 shrink-0 text-[#ff9500]" aria-hidden="true" />
              <span>
                {copy.undoBannerPrefix} {undoSnapshot.closedCount} {copy.undoBannerSuffix} (
                {undoSecondsLeft}s)
              </span>
            </span>
            <button
              type="button"
              onClick={() => {
                undoAllOff();
                playTactileSound('undo', soundEnabled);
              }}
              className={`btn-tactile inline-flex shrink-0 items-center gap-1 rounded-full px-2.5 py-0.5 text-[11px] font-semibold ${
                isDark
                  ? 'bg-white/15 text-white hover:bg-white/22'
                  : 'bg-[#eee7dc] text-[#1a1612] hover:bg-[#e5dcd0]'
              }`}
            >
              <RotateCcw className="size-3" aria-hidden="true" />
              <span>{copy.undoAction}</span>
            </button>
          </div>
        )}

        {/* 6. Native Classic Bottom Status Bar */}
        <div
          className={`mt-2.5 flex items-center justify-between border-t pt-2 text-[10.5px] ${
            isDark ? 'border-white/10 text-[#9c9790]' : 'border-black/[0.07] text-[#5b5349]'
          }`}
        >
          <span className="flex items-center gap-1.5 tabular-nums">
            <span className="size-1.5 rounded-full bg-[#30d158]" aria-hidden="true" />
            <span>{nativeCopy.statusFooter}</span>
          </span>
          <div className="flex items-center gap-1">
            <button
              type="button"
              aria-label={nativeCopy.a11y.refreshDevices}
              onClick={() => {
                setRefreshSpin(true);
                playTactileSound('tick', soundEnabled);
                window.setTimeout(() => setRefreshSpin(false), 450);
              }}
              className={`btn-tactile flex size-6 items-center justify-center rounded-full ${
                isDark ? 'hover:bg-white/10' : 'hover:bg-black/[0.06]'
              }`}
            >
              <RefreshCw
                className={`size-3 ${refreshSpin ? 'animate-spin' : ''}`}
                aria-hidden="true"
              />
            </button>
            <button
              type="button"
              onClick={() => {
                exitFocus();
                playTactileSound('tick', soundEnabled);
              }}
              className={`btn-tactile rounded-full px-2 py-0.5 font-medium ${
                isDark
                  ? 'text-[#d6d2cb] hover:bg-white/10'
                  : 'text-[#3b332b] hover:bg-black/[0.06]'
              }`}
            >
              {nativeCopy.exitFocusShort} ✕
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
