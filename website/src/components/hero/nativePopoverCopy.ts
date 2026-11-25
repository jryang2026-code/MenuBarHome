import type { Locale } from '../../content/siteCopy';
import type { CameraFeedId, RoomFilter } from '../../store/homeStore';

export interface NativePopoverStrings {
  menuBarHome: string;
  menuBarTip: string;
  homeTitle: string;
  demoBadge: string;
  activeUnit: string;
  studyClimateShort: string;
  allOffButton: (count: number) => string;
  allOffHolding: string;
  allOffExcludes: string;
  searchPlaceholder: string;
  searchMatches: (count: number) => string;
  searchEmptyTitle: string;
  searchEmptyHint: string;
  voiceHoldHint: string;
  voiceListening: string;
  voiceParserBadge: string;
  voiceCommands: Array<{
    transcript: string;
    feedback: string;
    action: 'ceiling40' | 'curtain50' | 'lampWarm';
  }>;
  rooms: Record<RoomFilter, string>;
  sectionAll: string;
  sectionSearch: string;
  quickDrawerTitle: string;
  forYouLabel: string;
  forYouChips: Array<{
    id: 'ceiling40' | 'curtainsHalf' | 'acCool25' | 'nightLamp';
    label: string;
  }>;
  quickScenesLabel: string;
  deviceRooms: {
    lamp: string;
    ceiling: string;
    lightBar: string;
    curtains: string;
    ac: string;
    plug: string;
    sensor: string;
    camera: string;
  };
  tileLabels: {
    lamp: string;
    ceiling: string;
    curtains: string;
    lightBar: string;
    lightBarOn: string;
    ac: string;
    plug: string;
  };
  lampPresets: {
    candle: string;
    warm: string;
    daylight: string;
  };
  curtainStops: {
    closed: string;
    half: string;
    open: string;
  };
  sensorTitle: string;
  sensorComfy: string;
  sensorSparklineHint: string;
  plugProtectedNote: string;
  cameraCardTitle: string;
  cameraCardSubtitle: string;
  cameraCardAction: string;
  cameraLiveBadge: string;
  cameraWindow: {
    title: string;
    go2rtcBadge: string;
    videoOnlyBadge: string;
    pinPip: string;
    unpinPip: string;
    close: string;
    tabs: {
      live: string;
      wall: string;
      events: string;
    };
    lensWide: string;
    lensTele: string;
    ptzHint: string;
    ptzCenter: string;
    ptzPan: string;
    ptzTilt: string;
    pinnedSwitchesLabel: string;
    porchLampSwitch: string;
    lightBarSwitch: string;
    snapshotBtn: string;
    snapshotSaved: string;
    autoPipNote: string;
    feeds: Record<
      CameraFeedId,
      {
        name: string;
        room: string;
        aspect: string;
        status: string;
      }
    >;
    events: Array<{
      time: string;
      title: string;
      detail: string;
      tag: string;
    }>;
  };
  appearanceLight: string;
  appearanceDark: string;
  statusFooter: string;
  exitFocusShort: string;
  mobilePanelTrigger: string;
  mobileCameraTrigger: string;
  focusCompactBanner: string;
}

export const NATIVE_POPOVER_COPY: Record<Locale, NativePopoverStrings> = {
  en: {
    menuBarHome: 'MenuBarHome',
    menuBarTip: 'Simulated macOS menu bar · ⌥M',
    homeTitle: 'My Home',
    demoBadge: 'Demo',
    activeUnit: 'on',
    studyClimateShort: 'Study 25.8° 58%',
    allOffButton: (count) => (count > 0 ? `All Off ${count}` : 'All Off'),
    allOffHolding: 'Holding 0.6s…',
    allOffExcludes: 'Excl. plug & cam (2)',
    searchPlaceholder: 'Search, pinyin (sftd), or speak…',
    searchMatches: (count) => `${count} match${count === 1 ? '' : 'es'}`,
    searchEmptyTitle: 'No matching device',
    searchEmptyHint: 'Press Return to run with LocalIntentParser',
    voiceHoldHint: 'Click or hold 0.5s to speak (LocalIntentParser)',
    voiceListening: 'Listening · LocalIntentParser',
    voiceParserBadge: 'LocalIntentParser · 0 API key',
    voiceCommands: [
      {
        transcript: 'Set ceiling light to 40%',
        feedback: 'Ceiling Light → 40%',
        action: 'ceiling40',
      },
      {
        transcript: 'Set curtains halfway',
        feedback: 'Motorized Curtains → 50%',
        action: 'curtain50',
      },
      {
        transcript: 'Warm desk lamp to 2200K',
        feedback: 'Mi Desk Lamp 1S → 2200K',
        action: 'lampWarm',
      },
    ],
    rooms: {
      all: 'All',
      study: 'Study',
      living: 'Living',
      entry: 'Entry',
    },
    sectionAll: 'All Devices',
    sectionSearch: 'Search Results',
    quickDrawerTitle: 'Quick Actions & Scenes',
    forYouLabel: 'For You',
    forYouChips: [
      { id: 'ceiling40', label: 'Ceiling 40%' },
      { id: 'curtainsHalf', label: 'Half Sunset' },
      { id: 'acCool25', label: 'Cool 25°C' },
      { id: 'nightLamp', label: 'Soft Night' },
    ],
    quickScenesLabel: 'Room Moods',
    deviceRooms: {
      lamp: 'Study',
      ceiling: 'Living',
      lightBar: 'Study',
      curtains: 'Study',
      ac: 'Study',
      plug: 'Study',
      sensor: 'Study',
      camera: 'Entry',
    },
    tileLabels: {
      lamp: 'Desk Lamp',
      ceiling: 'Ceiling',
      curtains: 'Curtains',
      lightBar: 'Light Bar',
      lightBarOn: 'Desk wash',
      ac: 'Mi Wall AC',
      plug: 'Smart Plug',
    },
    lampPresets: {
      candle: '2200K',
      warm: '3200K',
      daylight: '5000K',
    },
    curtainStops: {
      closed: 'Closed',
      half: 'Half',
      open: 'Sunset Open',
    },
    sensorTitle: 'Study Climate',
    sensorComfy: 'Comfy',
    sensorSparklineHint: '24h history',
    plugProtectedNote: 'Protected · 42W',
    cameraCardTitle: 'Front Doorbell',
    cameraCardSubtitle: 'Entry · go2rtc · Click for Live PTZ',
    cameraCardAction: 'Live',
    cameraLiveBadge: 'LIVE',
    cameraWindow: {
      title: 'Live Camera · Floating Panel',
      go2rtcBadge: 'go2rtc · 127.0.0.1',
      videoOnlyBadge: 'Video only',
      pinPip: 'Pin PiP',
      unpinPip: 'Pinned',
      close: 'Close camera view',
      tabs: {
        live: 'Live View',
        wall: '2×2 Wall',
        events: 'Events (7d)',
      },
      lensWide: '1× Wide',
      lensTele: '3× Tele',
      ptzHint: 'Drag feed to Pan / Tilt PTZ',
      ptzCenter: 'Center',
      ptzPan: 'PAN',
      ptzTilt: 'TILT',
      pinnedSwitchesLabel: 'Pinned quick switches',
      porchLampSwitch: 'Study / Porch Lamp',
      lightBarSwitch: 'Desk Light Bar',
      snapshotBtn: 'Snapshot',
      snapshotSaved: 'Local snapshot saved',
      autoPipNote: 'Muted · 30s auto-PiP',
      feeds: {
        doorbell: {
          name: 'Front Doorbell',
          room: 'Entry · 3:4 Portrait',
          aspect: '2.8mm Wide / 8mm Tele',
          status: '24 fps · 1080p',
        },
        study: {
          name: 'Study PTZ Cam',
          room: 'Study · Desk View',
          aspect: '360° Pan-Tilt',
          status: '25 fps · 2K',
        },
        balcony: {
          name: 'West Balcony',
          room: 'Living · Sunset',
          aspect: 'Wide 130°',
          status: '20 fps · 1080p',
        },
        garage: {
          name: 'Garage Entry',
          room: 'Entry · Covered',
          aspect: 'IR Night Ready',
          status: '15 fps · 1080p',
        },
      },
      events: [
        {
          time: '17:41',
          title: 'Parcel left at doorway',
          detail: 'Front Doorbell · Local clip saved (7d / 500 cap)',
          tag: 'Package',
        },
        {
          time: '17:18',
          title: 'Golden-hour motion detected',
          detail: 'Entry Porch · Auto-opened 30s PiP',
          tag: 'Motion',
        },
        {
          time: '14:05',
          title: 'Doorbell pressed',
          detail: 'Answered via MenuBarHome floating view',
          tag: 'Ring',
        },
      ],
    },
    appearanceLight: 'Switch to Dark appearance',
    appearanceDark: 'Switch to Light appearance',
    statusFooter: 'LAN UDP 54321 · Demo',
    exitFocusShort: 'Esc',
    mobilePanelTrigger: 'Panel',
    mobileCameraTrigger: 'Camera',
    focusCompactBanner: 'Blue iMac macOS Focus · Esc to exit',
  },
  zh: {
    menuBarHome: 'MenuBarHome',
    menuBarTip: '模拟 macOS 菜单栏 · ⌥M',
    homeTitle: '我的家',
    demoBadge: '演示预览',
    activeUnit: '台开启',
    studyClimateShort: '书房 25.8° 58%',
    allOffButton: (count) => (count > 0 ? `全关 ${count} 台` : '全关'),
    allOffHolding: '长按 0.6s…',
    allOffExcludes: '全关不含插座等 2 台',
    searchPlaceholder: '搜索设备、拼音 (sftd) 或语音…',
    searchMatches: (count) => `${count} 台`,
    searchEmptyTitle: '没有匹配的设备',
    searchEmptyHint: '回车将交给本地语义解析器执行',
    voiceHoldHint: '点击或长按 0.5 秒语音指令（免 API Key）',
    voiceListening: '正在听写 · 本地语义解析',
    voiceParserBadge: '本地语义解析 · 免 API Key',
    voiceCommands: [
      {
        transcript: '把吸顶灯调到 40%',
        feedback: '米家吸顶灯 → 40%',
        action: 'ceiling40',
      },
      {
        transcript: '把窗帘拉到一半',
        feedback: '米家电动窗帘 → 50%',
        action: 'curtain50',
      },
      {
        transcript: '书房台灯调暖到 2200K',
        feedback: '米家台灯 1S → 2200K',
        action: 'lampWarm',
      },
    ],
    rooms: {
      all: '全部',
      study: '书房',
      living: '客厅',
      entry: '玄关',
    },
    sectionAll: '全屋设备',
    sectionSearch: '搜索结果',
    quickDrawerTitle: '快捷操作与场景',
    forYouLabel: '猜你想控',
    forYouChips: [
      { id: 'ceiling40', label: '吸顶灯 40%' },
      { id: 'curtainsHalf', label: '窗帘半开' },
      { id: 'acCool25', label: '制冷 25°C' },
      { id: 'nightLamp', label: '柔和夜灯' },
    ],
    quickScenesLabel: '房间氛围',
    deviceRooms: {
      lamp: '书房',
      ceiling: '客厅',
      lightBar: '书房',
      curtains: '书房',
      ac: '书房',
      plug: '书房',
      sensor: '书房',
      camera: '玄关',
    },
    tileLabels: {
      lamp: '米家台灯',
      ceiling: '吸顶灯',
      curtains: '电动窗帘',
      lightBar: '屏幕挂灯',
      lightBarOn: '桌面补光',
      ac: '米家壁挂空调',
      plug: '智能插座',
    },
    lampPresets: {
      candle: '2200K',
      warm: '3200K',
      daylight: '5000K',
    },
    curtainStops: {
      closed: '全关',
      half: '半开',
      open: '落日全开',
    },
    sensorTitle: '书房温湿度计',
    sensorComfy: '舒适',
    sensorSparklineHint: '24 小时趋势',
    plugProtectedNote: '受保护 · 42W',
    cameraCardTitle: '前门门铃摄像头',
    cameraCardSubtitle: '玄关 · go2rtc 直连 · 点击看实时云台',
    cameraCardAction: '实时',
    cameraLiveBadge: '实时',
    cameraWindow: {
      title: '实时画面 · 悬浮窗',
      go2rtcBadge: 'go2rtc · 127.0.0.1',
      videoOnlyBadge: '仅视频',
      pinPip: '置顶画中画',
      unpinPip: '已置顶',
      close: '关闭摄像头画面',
      tabs: {
        live: '实时画面',
        wall: '2×2 画面墙',
        events: '7 天事件',
      },
      lensWide: '1× 广角',
      lensTele: '3× 长焦',
      ptzHint: '按住画面拖拽云台 PTZ',
      ptzCenter: '回中',
      ptzPan: '水平',
      ptzTilt: '俯仰',
      pinnedSwitchesLabel: '置顶快捷开关',
      porchLampSwitch: '书房 / 门厅灯',
      lightBarSwitch: '屏幕挂灯',
      snapshotBtn: '本地抓拍',
      snapshotSaved: '已保存本地截图',
      autoPipNote: '默认静音 · 按铃 30s 弹窗',
      feeds: {
        doorbell: {
          name: '前门门铃摄像头',
          room: '玄关 · 门铃视图',
          aspect: '广角 / 长焦双摄',
          status: '24 fps · 1080p',
        },
        study: {
          name: '书房云台摄像机',
          room: '书房 · 桌面全景',
          aspect: '360° 云台 PTZ',
          status: '25 fps · 2K',
        },
        balcony: {
          name: '西阳台落日视图',
          room: '客厅 · 室外光线',
          aspect: '130° 超广角',
          status: '20 fps · 1080p',
        },
        garage: {
          name: '车库入口摄像机',
          room: '玄关 · 门禁区',
          aspect: '微光全彩夜视',
          status: '15 fps · 1080p',
        },
      },
      events: [
        {
          time: '17:41',
          title: '门口放置快递包裹',
          detail: '前门门铃 · 本地留存（7 天 / 500 条上限）',
          tag: '包裹',
        },
        {
          time: '17:18',
          title: '玄关傍晚有人经过',
          detail: '已按规则弹出 30 秒画中画',
          tag: '移动',
        },
        {
          time: '14:05',
          title: '访客按响门铃',
          detail: '通过 MenuBarHome 悬浮窗查看',
          tag: '按铃',
        },
      ],
    },
    appearanceLight: '切换到深色外观',
    appearanceDark: '切换到浅色外观',
    statusFooter: '局域网 UDP 54321 · 演示',
    exitFocusShort: 'Esc',
    mobilePanelTrigger: '控制面板',
    mobileCameraTrigger: '实时监控',
    focusCompactBanner: '正在操控蓝色 iMac · Esc 退出',
  },
};

/** Authentic 24-hour Study Temperature & Humidity series for inline SensorSparklineView */
export const STUDY_CLIMATE_24H: Array<{ hour: string; temp: number; humidity: number }> = [
  { hour: '18:00', temp: 25.4, humidity: 57 },
  { hour: '20:00', temp: 25.1, humidity: 58 },
  { hour: '22:00', temp: 24.7, humidity: 60 },
  { hour: '00:00', temp: 24.2, humidity: 61 },
  { hour: '02:00', temp: 23.8, humidity: 62 },
  { hour: '04:00', temp: 23.5, humidity: 63 },
  { hour: '06:00', temp: 23.7, humidity: 62 },
  { hour: '08:00', temp: 24.3, humidity: 60 },
  { hour: '10:00', temp: 25.0, humidity: 58 },
  { hour: '12:00', temp: 25.9, humidity: 55 },
  { hour: '14:00', temp: 26.4, humidity: 54 },
  { hour: '16:00', temp: 26.1, humidity: 56 },
  { hour: '17:42', temp: 25.8, humidity: 58 },
];
