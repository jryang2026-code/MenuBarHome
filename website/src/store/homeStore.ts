import { create } from 'zustand';

export type ScenePreset = 'evening' | 'focus' | 'movie';
export type CameraFocus = 'overview' | 'imac';
export type LightControlTab = 'desk' | 'ceiling';
export type PanelAppearance = 'light' | 'dark';
export type RoomFilter = 'all' | 'study' | 'living' | 'entry';
export type CameraFeedId = 'doorbell' | 'study' | 'balcony' | 'garage';
export type CameraLens = 'wide' | 'tele';
export type CameraViewTab = 'live' | 'wall' | 'events';
export type ExpandableDeviceId = 'lamp' | 'ceiling' | 'curtains' | null;
export type HoverTarget =
  | 'lamp'
  | 'ceiling'
  | 'lightbar'
  | 'curtains'
  | 'ac'
  | 'monolith'
  | 'imac'
  | 'plug'
  | null;

export interface UndoSnapshot {
  lampOn: boolean;
  lampBrightness: number;
  lampKelvin: number;
  ceilingOn: boolean;
  ceilingBrightness: number;
  ceilingKelvin: number;
  lightBarOn: boolean;
  acOn: boolean;
  monolithOn: boolean;
  curtainOpen: number;
  closedCount: number;
  expiresAt: number;
}

export interface HomeState {
  // Interactive smart-home device state (bi-directionally synced between 3D room & macOS popover)
  lampOn: boolean;
  lampBrightness: number; // 0..100
  lampKelvin: number; // 1900..6500

  ceilingOn: boolean;
  ceilingBrightness: number; // 0..100
  ceilingKelvin: number; // 2700..6500

  lightBarOn: boolean;
  lightBarBrightness: number; // 0..100

  curtainOpen: number; // 0 (closed) .. 100 (wide open, lets golden sunset stream in)
  acOn: boolean;
  acTemp: number; // 16..30

  plugOn: boolean; // Always protected during 0.6s Hold All Off
  plugWatts: number;
  monolithOn: boolean;
  preset: ScenePreset;

  // Camera focus & Popover / HUD / PiP interactive state
  cameraFocus: CameraFocus;
  activeLightTab: LightControlTab;
  panelAppearance: PanelAppearance;
  roomFilter: RoomFilter;
  expandedDevice: ExpandableDeviceId;
  quickDrawerOpen: boolean;
  cameraOpen: boolean;
  cameraFeed: CameraFeedId;
  cameraLens: CameraLens;
  cameraViewTab: CameraViewTab;
  cameraPan: number; // -45..45 deg
  cameraTilt: number; // -22..22 deg
  voiceHudMessage: string | null;
  hoveredTarget: HoverTarget;
  selectedTarget: HoverTarget;
  searchQuery: string;
  pipPinned: boolean;
  pipGhosting: boolean;
  activeKeycap: string | null;
  soundEnabled: boolean;
  undoSnapshot: UndoSnapshot | null;
  undoSecondsLeft: number;
  plugProtectedFlash: number;

  // Transient animation value read inside R3F useFrame via .getState() (zero React re-renders)
  scrollProgress: number;

  // Actions
  toggleLamp: () => void;
  setLampBrightness: (val: number) => void;
  setLampKelvin: (val: number) => void;
  stepActiveLightBrightness: (delta: number) => void;

  toggleCeiling: () => void;
  setCeilingBrightness: (val: number) => void;
  setCeilingKelvin: (val: number) => void;

  toggleLightBar: () => void;

  cycleCurtains: () => void;
  setCurtainOpen: (val: number) => void;

  toggleAc: () => void;
  stepAcTemp: (delta: number) => void;

  toggleMonolith: () => void;
  applyPreset: (preset: ScenePreset) => void;
  executeAllOff: () => void;
  undoAllOff: () => void;
  tickUndoCountdown: () => void;

  focusImac: () => void;
  exitFocus: () => void;
  toggleCameraFocus: () => void;
  setActiveLightTab: (tab: LightControlTab) => void;
  togglePanelAppearance: () => void;
  setRoomFilter: (room: RoomFilter) => void;
  cycleRoomFilter: () => void;
  toggleExpandedDevice: (id: Exclude<ExpandableDeviceId, null>) => void;
  setExpandedDevice: (id: ExpandableDeviceId) => void;
  toggleQuickDrawer: () => void;
  setQuickDrawerOpen: (open: boolean) => void;
  openCamera: (feed?: CameraFeedId) => void;
  closeCamera: () => void;
  setCameraFeed: (feed: CameraFeedId) => void;
  setCameraLens: (lens: CameraLens) => void;
  setCameraViewTab: (tab: CameraViewTab) => void;
  setCameraPtz: (pan: number, tilt: number) => void;
  nudgeCameraPtz: (dPan: number, dTilt: number) => void;
  resetCameraPtz: () => void;
  showVoiceHud: (msg: string, durationMs?: number) => void;

  togglePip: () => void;
  setHoveredTarget: (target: HoverTarget) => void;
  setSelectedTarget: (target: HoverTarget) => void;
  setSearchQuery: (q: string) => void;
  flashKeycap: (key: string) => void;
  toggleSound: () => void;
  setScrollProgress: (progress: number) => void;
}

let keycapTimer: number | undefined;
let pipGhostTimer: number | undefined;
let voiceHudTimer: number | undefined;

const ROOM_ORDER: RoomFilter[] = ['all', 'study', 'living', 'entry'];

function anyNonProtectedOn(s: {
  lampOn: boolean;
  ceilingOn: boolean;
  lightBarOn: boolean;
  acOn: boolean;
}): boolean {
  return s.lampOn || s.ceilingOn || s.lightBarOn || s.acOn;
}

export const useHomeStore = create<HomeState>((set, get) => ({
  // Default: Warm Golden-Hour Evening study
  lampOn: true,
  lampBrightness: 68,
  lampKelvin: 2900,

  ceilingOn: true,
  ceilingBrightness: 46,
  ceilingKelvin: 3200,

  lightBarOn: true,
  lightBarBrightness: 70,

  curtainOpen: 76,
  acOn: false,
  acTemp: 26,

  plugOn: true,
  plugWatts: 42,
  monolithOn: true,
  preset: 'evening',

  cameraFocus: 'overview',
  activeLightTab: 'desk',
  panelAppearance: 'light',
  roomFilter: 'all',
  expandedDevice: null,
  quickDrawerOpen: false,
  cameraOpen: false,
  cameraFeed: 'doorbell',
  cameraLens: 'wide',
  cameraViewTab: 'live',
  cameraPan: 0,
  cameraTilt: 0,
  voiceHudMessage: null,
  hoveredTarget: null,
  selectedTarget: 'lamp',
  searchQuery: '',
  pipPinned: false,
  pipGhosting: false,
  activeKeycap: null,
  soundEnabled: false,
  undoSnapshot: null,
  undoSecondsLeft: 0,
  plugProtectedFlash: 0,

  scrollProgress: 0,

  toggleLamp: () =>
    set((s) => {
      const next = !s.lampOn;
      return {
        lampOn: next,
        activeLightTab: 'desk',
        monolithOn: anyNonProtectedOn({ ...s, lampOn: next }),
        undoSnapshot: null,
        undoSecondsLeft: 0,
      };
    }),

  setLampBrightness: (val) =>
    set((s) => {
      const clamped = Math.max(0, Math.min(100, Math.round(val)));
      const nextOn = clamped > 0;
      return {
        lampOn: nextOn,
        lampBrightness: clamped,
        activeLightTab: 'desk',
        monolithOn: anyNonProtectedOn({ ...s, lampOn: nextOn }),
        undoSnapshot: null,
        undoSecondsLeft: 0,
      };
    }),

  setLampKelvin: (val) =>
    set({
      lampKelvin: Math.max(1900, Math.min(6500, Math.round(val / 100) * 100)),
      activeLightTab: 'desk',
    }),

  toggleCeiling: () =>
    set((s) => {
      const next = !s.ceilingOn;
      return {
        ceilingOn: next,
        activeLightTab: 'ceiling',
        monolithOn: anyNonProtectedOn({ ...s, ceilingOn: next }),
        undoSnapshot: null,
        undoSecondsLeft: 0,
      };
    }),

  setCeilingBrightness: (val) =>
    set((s) => {
      const clamped = Math.max(0, Math.min(100, Math.round(val)));
      const nextOn = clamped > 0;
      return {
        ceilingOn: nextOn,
        ceilingBrightness: clamped,
        activeLightTab: 'ceiling',
        monolithOn: anyNonProtectedOn({ ...s, ceilingOn: nextOn }),
        undoSnapshot: null,
        undoSecondsLeft: 0,
      };
    }),

  setCeilingKelvin: (val) =>
    set({
      ceilingKelvin: Math.max(2700, Math.min(6500, Math.round(val / 100) * 100)),
      activeLightTab: 'ceiling',
    }),

  stepActiveLightBrightness: (delta) =>
    set((s) => {
      if (s.activeLightTab === 'ceiling') {
        const base = s.ceilingOn ? s.ceilingBrightness : 0;
        const next = Math.max(0, Math.min(100, base + delta));
        const nextOn = next > 0;
        return {
          ceilingOn: nextOn,
          ceilingBrightness: next === 0 ? 10 : next,
          monolithOn: anyNonProtectedOn({ ...s, ceilingOn: nextOn }),
          undoSnapshot: null,
          undoSecondsLeft: 0,
        };
      }
      const base = s.lampOn ? s.lampBrightness : 0;
      const next = Math.max(0, Math.min(100, base + delta));
      const nextOn = next > 0;
      return {
        lampOn: nextOn,
        lampBrightness: next === 0 ? 10 : next,
        monolithOn: anyNonProtectedOn({ ...s, lampOn: nextOn }),
        undoSnapshot: null,
        undoSecondsLeft: 0,
      };
    }),

  toggleLightBar: () =>
    set((s) => {
      const next = !s.lightBarOn;
      return {
        lightBarOn: next,
        monolithOn: anyNonProtectedOn({ ...s, lightBarOn: next }),
        undoSnapshot: null,
        undoSecondsLeft: 0,
      };
    }),

  cycleCurtains: () =>
    set((s) => {
      // Smooth 3-stop toggle: Wide Open (96%) -> Half Sunset (50%) -> Closed (6%)
      const next = s.curtainOpen > 75 ? 48 : s.curtainOpen > 25 ? 6 : 96;
      return { curtainOpen: next };
    }),

  setCurtainOpen: (val) =>
    set({ curtainOpen: Math.max(0, Math.min(100, Math.round(val))) }),

  toggleAc: () =>
    set((s) => {
      const next = !s.acOn;
      return {
        acOn: next,
        monolithOn: anyNonProtectedOn({ ...s, acOn: next }),
        undoSnapshot: null,
        undoSecondsLeft: 0,
      };
    }),

  stepAcTemp: (delta) =>
    set((s) => ({
      acOn: true,
      acTemp: Math.max(16, Math.min(30, s.acTemp + delta)),
      monolithOn: true,
    })),

  toggleMonolith: () => {
    const s = get();
    if (s.monolithOn && anyNonProtectedOn(s)) {
      s.executeAllOff();
    } else if (s.undoSnapshot) {
      s.undoAllOff();
    } else {
      s.applyPreset('evening');
    }
  },

  applyPreset: (preset) => {
    if (preset === 'evening') {
      set({
        preset,
        lampOn: true,
        lampBrightness: 68,
        lampKelvin: 2900,
        ceilingOn: true,
        ceilingBrightness: 46,
        ceilingKelvin: 3200,
        lightBarOn: true,
        lightBarBrightness: 70,
        curtainOpen: 76,
        acOn: false,
        monolithOn: true,
        undoSnapshot: null,
        undoSecondsLeft: 0,
      });
    } else if (preset === 'focus') {
      set({
        preset,
        lampOn: true,
        lampBrightness: 92,
        lampKelvin: 5000,
        ceilingOn: true,
        ceilingBrightness: 88,
        ceilingKelvin: 4800,
        lightBarOn: true,
        lightBarBrightness: 95,
        curtainOpen: 96,
        acOn: true,
        acTemp: 24,
        monolithOn: true,
        undoSnapshot: null,
        undoSecondsLeft: 0,
      });
    } else {
      set({
        preset,
        lampOn: true,
        lampBrightness: 22,
        lampKelvin: 2100,
        ceilingOn: false,
        ceilingBrightness: 30,
        ceilingKelvin: 2700,
        lightBarOn: false,
        curtainOpen: 8,
        acOn: true,
        acTemp: 25,
        monolithOn: true,
        undoSnapshot: null,
        undoSecondsLeft: 0,
      });
    }
  },

  executeAllOff: () => {
    const s = get();
    const closedCount =
      (s.lampOn ? 1 : 0) +
      (s.ceilingOn ? 1 : 0) +
      (s.lightBarOn ? 1 : 0) +
      (s.acOn ? 1 : 0);
    const snapshot: UndoSnapshot = {
      lampOn: s.lampOn,
      lampBrightness: s.lampBrightness,
      lampKelvin: s.lampKelvin,
      ceilingOn: s.ceilingOn,
      ceilingBrightness: s.ceilingBrightness,
      ceilingKelvin: s.ceilingKelvin,
      lightBarOn: s.lightBarOn,
      acOn: s.acOn,
      monolithOn: s.monolithOn,
      curtainOpen: s.curtainOpen,
      closedCount: Math.max(closedCount, 3),
      expiresAt: Date.now() + 15_000,
    };
    set({
      lampOn: false,
      ceilingOn: false,
      lightBarOn: false,
      acOn: false,
      monolithOn: false,
      // Mi Smart Plug stays protected and powered on!
      plugOn: true,
      undoSnapshot: snapshot,
      undoSecondsLeft: 15,
      plugProtectedFlash: Date.now(),
    });
  },

  undoAllOff: () => {
    const snap = get().undoSnapshot;
    if (!snap) return;
    set({
      lampOn: snap.lampOn,
      lampBrightness: snap.lampBrightness || 68,
      lampKelvin: snap.lampKelvin,
      ceilingOn: snap.ceilingOn,
      ceilingBrightness: snap.ceilingBrightness || 46,
      ceilingKelvin: snap.ceilingKelvin,
      lightBarOn: snap.lightBarOn,
      acOn: snap.acOn,
      monolithOn: true,
      curtainOpen: snap.curtainOpen,
      undoSnapshot: null,
      undoSecondsLeft: 0,
    });
  },

  tickUndoCountdown: () => {
    const snap = get().undoSnapshot;
    if (!snap) return;
    const left = Math.max(0, Math.ceil((snap.expiresAt - Date.now()) / 1000));
    if (left <= 0) {
      set({ undoSnapshot: null, undoSecondsLeft: 0 });
    } else if (left !== get().undoSecondsLeft) {
      set({ undoSecondsLeft: left });
    }
  },

  focusImac: () => set({ cameraFocus: 'imac', selectedTarget: 'imac' }),
  exitFocus: () =>
    set({
      cameraFocus: 'overview',
      cameraOpen: false,
      quickDrawerOpen: false,
      expandedDevice: null,
    }),
  toggleCameraFocus: () =>
    set((s) =>
      s.cameraFocus === 'imac'
        ? {
            cameraFocus: 'overview',
            cameraOpen: false,
            quickDrawerOpen: false,
            expandedDevice: null,
          }
        : { cameraFocus: 'imac', selectedTarget: 'imac' }
    ),
  setActiveLightTab: (activeLightTab) => set({ activeLightTab }),
  togglePanelAppearance: () =>
    set((s) => ({ panelAppearance: s.panelAppearance === 'light' ? 'dark' : 'light' })),
  setRoomFilter: (roomFilter) => set({ roomFilter }),
  cycleRoomFilter: () =>
    set((s) => {
      const idx = ROOM_ORDER.indexOf(s.roomFilter);
      return { roomFilter: ROOM_ORDER[(idx + 1) % ROOM_ORDER.length] };
    }),
  toggleExpandedDevice: (id) =>
    set((s) => ({
      expandedDevice: s.expandedDevice === id ? null : id,
      activeLightTab: id === 'ceiling' ? 'ceiling' : id === 'lamp' ? 'desk' : s.activeLightTab,
    })),
  setExpandedDevice: (expandedDevice) => set({ expandedDevice }),
  toggleQuickDrawer: () => set((s) => ({ quickDrawerOpen: !s.quickDrawerOpen })),
  setQuickDrawerOpen: (quickDrawerOpen) => set({ quickDrawerOpen }),
  openCamera: (feed) =>
    set((s) => ({
      cameraOpen: true,
      cameraFeed: feed ?? s.cameraFeed,
      cameraFocus: 'imac',
    })),
  closeCamera: () => set({ cameraOpen: false }),
  setCameraFeed: (cameraFeed) => set({ cameraFeed, cameraPan: 0, cameraTilt: 0 }),
  setCameraLens: (cameraLens) => set({ cameraLens }),
  setCameraViewTab: (cameraViewTab) => set({ cameraViewTab }),
  setCameraPtz: (pan, tilt) =>
    set({
      cameraPan: Math.max(-45, Math.min(45, Math.round(pan))),
      cameraTilt: Math.max(-22, Math.min(22, Math.round(tilt))),
    }),
  nudgeCameraPtz: (dPan, dTilt) =>
    set((s) => ({
      cameraPan: Math.max(-45, Math.min(45, Math.round(s.cameraPan + dPan))),
      cameraTilt: Math.max(-22, Math.min(22, Math.round(s.cameraTilt + dTilt))),
    })),
  resetCameraPtz: () => set({ cameraPan: 0, cameraTilt: 0 }),
  showVoiceHud: (msg, durationMs = 2800) => {
    set({ voiceHudMessage: msg });
    if (typeof window !== 'undefined') {
      window.clearTimeout(voiceHudTimer);
      voiceHudTimer = window.setTimeout(() => {
        set((s) => (s.voiceHudMessage === msg ? { voiceHudMessage: null } : s));
      }, durationMs);
    }
  },

  togglePip: () => {
    const next = !get().pipPinned;
    if (typeof window !== 'undefined') {
      window.clearTimeout(pipGhostTimer);
    }
    if (next) {
      set({ pipGhosting: true, pipPinned: true });
      if (typeof window !== 'undefined') {
        pipGhostTimer = window.setTimeout(() => {
          set({ pipGhosting: false });
        }, 280);
      }
    } else {
      set({ pipPinned: false, pipGhosting: false });
    }
  },

  setHoveredTarget: (hoveredTarget) => set({ hoveredTarget }),
  setSelectedTarget: (selectedTarget) => set({ selectedTarget }),
  setSearchQuery: (searchQuery) => set({ searchQuery }),

  flashKeycap: (key) => {
    set({ activeKeycap: key });
    if (typeof window !== 'undefined') {
      window.clearTimeout(keycapTimer);
      keycapTimer = window.setTimeout(() => {
        set((s) => (s.activeKeycap === key ? { activeKeycap: null } : s));
      }, 240);
    }
  },

  toggleSound: () => set((s) => ({ soundEnabled: !s.soundEnabled })),
  setScrollProgress: (scrollProgress) => set({ scrollProgress }),
}));

/** Map physical Kelvin (1900K - 6500K) to MenuBarHome DesignTokens.Spectrum hex */
export function kelvinToHex(kelvin: number): string {
  const k = Math.max(1900, Math.min(6500, kelvin));
  const stops = [
    { k: 1900, r: 250, g: 158, b: 41 },
    { k: 3000, r: 255, g: 204, b: 138 },
    { k: 4200, r: 255, g: 234, b: 200 },
    { k: 6500, r: 164, g: 215, b: 255 },
  ];
  for (let i = 0; i < stops.length - 1; i++) {
    const a = stops[i];
    const b = stops[i + 1];
    if (k >= a.k && k <= b.k) {
      const t = (k - a.k) / (b.k - a.k);
      const r = Math.round(a.r + (b.r - a.r) * t);
      const g = Math.round(a.g + (b.g - a.g) * t);
      const bl = Math.round(a.b + (b.b - a.b) * t);
      return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${bl.toString(16).padStart(2, '0')}`;
    }
  }
  return '#ffcc8a';
}
