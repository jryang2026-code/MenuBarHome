export type Locale = 'en' | 'zh';
export type PlatformOS = 'macos' | 'windows';

export const RELEASE_URLS = {
  repo: 'https://github.com/jryang2026-code/MenuBarHome',
  release: 'https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.4.0',
  macDmg:
    'https://github.com/jryang2026-code/MenuBarHome/releases/download/v1.4.0/MenuBarHome-1.4.0.dmg',
  macSha256:
    'https://github.com/jryang2026-code/MenuBarHome/releases/download/v1.4.0/MenuBarHome-1.4.0.dmg.sha256',
  macSbom:
    'https://github.com/jryang2026-code/MenuBarHome/releases/download/v1.4.0/MenuBarHome-1.4.0-macos.spdx.json',
  winExe:
    'https://github.com/jryang2026-code/MenuBarHome/releases/download/v1.4.0/MenuBarHome-1.4.0-windows-x64-setup.exe',
  winMsi:
    'https://github.com/jryang2026-code/MenuBarHome/releases/download/v1.4.0/MenuBarHome-1.4.0-windows-x64.msi',
  winSha256:
    'https://github.com/jryang2026-code/MenuBarHome/releases/download/v1.4.0/MenuBarHome-1.4.0-windows-x64.sha256',
  winSbom:
    'https://github.com/jryang2026-code/MenuBarHome/releases/download/v1.4.0/MenuBarHome-1.4.0-windows-x64.spdx.json',
  devicesDoc:
    'https://github.com/jryang2026-code/MenuBarHome/blob/main/docs/DEVICES.md',
  faqDoc: 'https://github.com/jryang2026-code/MenuBarHome/blob/main/docs/FAQ.md',
  securityDoc:
    'https://github.com/jryang2026-code/MenuBarHome/blob/main/SECURITY.md',
  zhReadme:
    'https://github.com/jryang2026-code/MenuBarHome/blob/main/README_ZH.md',
} as const;

export const INSTALL_COMMANDS = {
  macos: `brew tap jryang2026-code/tap
brew trust --cask jryang2026-code/tap/menubarhome
brew install --cask jryang2026-code/tap/menubarhome`,
  windows: `$url = "https://github.com/jryang2026-code/MenuBarHome/releases/download/v1.4.0/MenuBarHome-1.4.0-windows-x64-setup.exe"
Invoke-WebRequest $url -OutFile "MenuBarHome-1.4.0-windows-x64-setup.exe"
Get-FileHash .\\MenuBarHome-1.4.0-windows-x64-setup.exe -Algorithm SHA256`,
} as const;

export interface FeatureCopy {
  id: string;
  title: string;
  body: string;
  theme: 'sand' | 'paper';
  badge?: string;
}

export interface CameraEventItem {
  time: string;
  title: string;
  zone: string;
}

export interface CameraSpotlightCopy {
  eyebrow: string;
  title: string;
  titlePrefix: string;
  titleAccent: string;
  body: string;
  ctaOpen: string;
  ctaHint: string;
  specs: string[];
  modalTitle: string;
  modalSubtitle: string;
  liveBadge: string;
  loopbackBadge: string;
  videoOnlyBadge: string;
  ptzDragHint: string;
  resetView: string;
  lensWide: string;
  lensTele: string;
  modeLive: string;
  modePip: string;
  modeWall: string;
  pinnedSwitchesLabel: string;
  porchLightLabel: string;
  deskLampLabel: string;
  eventsTitle: string;
  eventsMeta: string;
  closeLabel: string;
  autoOpenNote: string;
  events: CameraEventItem[];
}

export interface GitHubStatsCopy {
  starsLabel: string;
  downloadsLabel: string;
  totalDownloadsLabel: string;
  liveLabel: string;
}

export interface StarInviteCopy {
  eyebrow: string;
  title: string;
  titlePrefix: string;
  titleAccent: string;
  body: string;
  cta: string;
  ctaStarred: string;
  postDownloadNudge: string;
}

export interface ShortcutItem {
  label: string;
  macKeys: string[];
  winKeys: string[];
  note?: string;
}

export interface SiteDictionary {
  skipToContent: string;
  nav: {
    features: string;
    shortcuts: string;
    github: string;
    download: string;
    star: string;
    starred: string;
    langToggle: string;
    langAria: string;
  };
  stats: GitHubStatsCopy;
  starInvite: StarInviteCopy;
  hero: {
    eyebrow?: string;
    h1: string;
    h1Prefix?: string;
    h1Accent?: string;
    lead: string;
    downloadMac: string;
    downloadWin: string;
    switchToWin: string;
    switchToMac: string;
    secondaryCta: string;
    focusImacLabel: string;
    exitFocusLabel: string;
    focusBannerHint: string;
    specLine: string;
    stageHint: string;
    soundOn: string;
    soundOff: string;
    launch3D: string;
    presets: {
      evening: string;
      focus: string;
      movie: string;
    };
    hud: {
      open: string;
      step: string;
      pinyin: string;
      dragHint: string;
    };
    popover: {
      homeTitle: string;
      activeSuffix: string;
      allOffLabel: string;
      holdHint: string;
      holdingLabel: string;
      searchPlaceholder: string;
      deskTab: string;
      ceilingTab: string;
      lampName: string;
      ceilingName: string;
      lightBarName: string;
      lightBarOn: string;
      curtainsName: string;
      curtainsOpen: string;
      curtainsHalf: string;
      curtainsClosed: string;
      curtainSunHint: string;
      acName: string;
      acOff: string;
      acCool: string;
      plugName: string;
      plugProtected: string;
      doorbellName: string;
      doorbellPin: string;
      doorbellPinned: string;
      videoOnly: string;
      brightness: string;
      kelvin: string;
      undoBannerPrefix: string;
      undoBannerSuffix: string;
      undoAction: string;
      offLabel: string;
    };
  };
  features: {
    eyebrow?: string;
    h2: string;
    h2Prefix?: string;
    h2Accent?: string;
    lead: string;
    pauseDemos: string;
    resumeDemos: string;
    cameraSpotlight: CameraSpotlightCopy;
    items: FeatureCopy[];
  };
  shortcuts: {
    h2: string;
    lead: string;
    items: ShortcutItem[];
    ecosystemLabel: string;
    ecosystemItems: Array<{ name: string; detail: string }>;
  };
  download: {
    h2: string;
    lead: string;
    macTab: string;
    winTab: string;
    macCta: string;
    macSize: string;
    winCta: string;
    winSize: string;
    winMsiLink: string;
    terminalHeaderMac: string;
    terminalHeaderWin: string;
    copy: string;
    copied: string;
    shaLink: string;
    sbomLink: string;
    verifyPrefix: string;
    signingMac: string;
    signingWin: string;
    footprintNote: string;
    stats: GitHubStatsCopy;
    starInvite: StarInviteCopy;
  };
  footer: {
    meta: string;
    links: {
      github: string;
      devices: string;
      faq: string;
      security: string;
      zhReadme: string;
    };
    copyright: string;
  };
}

const EN_STATS: GitHubStatsCopy = {
  starsLabel: 'Stars',
  downloadsLabel: 'Downloads',
  totalDownloadsLabel: 'Total downloads',
  liveLabel: 'GitHub live',
};

const EN_STAR_INVITE: StarInviteCopy = {
  eyebrow: 'MIT Open Source',
  title: 'Built in the open, light up a star.',
  titlePrefix: 'Built in the open, ',
  titleAccent: 'light up a star.',
  body: 'MenuBarHome is free and MIT-licensed with zero telemetry. A GitHub star helps more desktop users find it.',
  cta: 'Star on GitHub',
  ctaStarred: 'Starred on GitHub',
  postDownloadNudge: 'Like MenuBarHome? Leave a star on GitHub.',
};

const ZH_STATS: GitHubStatsCopy = {
  starsLabel: 'Stars',
  downloadsLabel: '次下载',
  totalDownloadsLabel: '累计下载',
  liveLabel: 'GitHub 实时',
};

const ZH_STAR_INVITE: StarInviteCopy = {
  eyebrow: 'MIT 开源免费',
  title: '开源共建，点亮一颗星。',
  titlePrefix: '开源共建，',
  titleAccent: '点亮一颗星。',
  body: 'MenuBarHome 完全开源、零遥测。一颗 GitHub Star，能让更多 macOS 与 Windows 用户发现它。',
  cta: '去 GitHub 点星',
  ctaStarred: '已去 GitHub 点星',
  postDownloadNudge: '下载已开始，顺手去 GitHub 点颗星支持开源？',
};

export const SITE_COPY: Record<Locale, SiteDictionary> = {
  en: {
    skipToContent: 'Skip to main content',
    nav: {
      features: 'Features',
      shortcuts: 'Shortcuts',
      github: 'GitHub',
      download: 'Download',
      star: 'Star',
      starred: 'Starred',
      langToggle: '中文',
      langAria: 'Switch language to Chinese',
    },
    stats: EN_STATS,
    starInvite: EN_STAR_INVITE,
    hero: {
      eyebrow: 'v1.4.0 · macOS & Windows',
      h1: 'Smart home, in the menu bar.',
      h1Prefix: 'Smart home, in the ',
      h1Accent: 'menu bar.',
      lead: 'Direct Mi Home QR or Home Assistant for lights, AC, curtains, and PTZ cameras.',
      downloadMac: 'Download for macOS',
      downloadWin: 'Download for Windows',
      switchToWin: 'Also for Windows 11',
      switchToMac: 'Also for macOS',
      secondaryCta: 'Focus iMac',
      focusImacLabel: 'Focus iMac',
      exitFocusLabel: 'Back to Study',
      focusBannerHint: 'Blue iMac focused · Esc to return',
      specLine: 'v1.4.0 · 1.2% idle CPU · MIT',
      stageHint: 'Click the Blue iMac to open macOS',
      soundOn: 'Sound On',
      soundOff: 'Sound Off',
      launch3D: 'Launch 3D Study',
      presets: {
        evening: 'Sunset',
        focus: 'Focus',
        movie: 'Cinema',
      },
      hud: {
        open: 'Search',
        step: 'Dim',
        pinyin: 'sftd → Lamp',
        dragHint: 'Drag to orbit',
      },
      popover: {
        homeTitle: 'Golden-Hour Study',
        activeSuffix: 'on',
        allOffLabel: 'Hold All Off',
        holdHint: 'Hold 0.6s',
        holdingLabel: 'Holding...',
        searchPlaceholder: 'Search room or pinyin (sftd)',
        deskTab: 'Desk Lamp',
        ceilingTab: 'Ceiling Light',
        lampName: 'Mi Desk Lamp 1S',
        ceilingName: 'Mi Ceiling Light',
        lightBarName: 'Monitor Light Bar',
        lightBarOn: 'Asymmetric desk wash',
        curtainsName: 'Motorized Curtains',
        curtainsOpen: 'Open · Sunset in',
        curtainsHalf: 'Half · Soft sun',
        curtainsClosed: 'Closed · Cozy',
        curtainSunHint: 'Sunset',
        acName: 'Mi Wall AC',
        acOff: 'Standby',
        acCool: 'Cool',
        plugName: 'Mi Smart Plug',
        plugProtected: 'Protected · 42W',
        doorbellName: 'Front Doorbell',
        doorbellPin: 'Pin PiP',
        doorbellPinned: 'Pinned',
        videoOnly: 'Video only',
        brightness: 'Brightness',
        kelvin: 'Warmth',
        undoBannerPrefix: 'Turned off',
        undoBannerSuffix: 'devices · Plug protected',
        undoAction: 'Undo',
        offLabel: 'Off',
      },
    },
    features: {
      eyebrow: 'Why MenuBarHome',
      h2: 'Every room, one keystroke.',
      h2Prefix: 'Every room, ',
      h2Accent: 'one keystroke.',
      lead: 'Native desktop control built around your keyboard, LAN, and live cameras.',
      pauseDemos: 'Pause motion',
      resumeDemos: 'Play motion',
      cameraSpotlight: {
        eyebrow: 'go2rtc loopback',
        title: 'Live cameras, drag PTZ, and doorbell PiP',
        titlePrefix: 'Live cameras, drag PTZ, and ',
        titleAccent: 'doorbell PiP',
        body: 'Stream Xiaomi cameras via local go2rtc with drag PTZ, dual-lens zoom, and 3:4 doorbell PiP.',
        ctaOpen: 'Open live camera',
        ctaHint: 'Click to test PTZ drag, dual-lens & PiP',
        specs: ['go2rtc 127.0.0.1', 'PTZ + Dual-Lens', '3:4 Doorbell PiP'],
        modalTitle: 'Front Doorbell & Study Camera',
        modalSubtitle: 'go2rtc loopback · Muted by default',
        liveBadge: 'LIVE',
        loopbackBadge: '127.0.0.1 · Basic Auth',
        videoOnlyBadge: 'Video only',
        ptzDragHint: 'Drag viewport or tap arrows to pan and tilt',
        resetView: 'Center PTZ',
        lensWide: '1× Wide',
        lensTele: '3× Telephoto',
        modeLive: 'Live PTZ',
        modePip: '3:4 Doorbell PiP',
        modeWall: '2×2 Still Wall',
        pinnedSwitchesLabel: 'Pinned switches (up to 2)',
        porchLightLabel: 'Entry Porch Light',
        deskLampLabel: 'Mi Desk Lamp 1S',
        eventsTitle: 'Local Event History',
        eventsMeta: '7d · 500 local',
        closeLabel: 'Close camera',
        autoOpenNote: 'Auto-open PiP countdown: 30s default',
        events: [
          { time: '17:41:12', title: 'Doorbell pressed · Auto-open PiP', zone: 'Front Entry' },
          { time: '17:18:04', title: 'Motion detected · Sunset glare filtered', zone: 'Porch' },
          { time: '16:05:39', title: 'Parcel placed at door', zone: 'Front Entry' },
        ],
      },
      items: [
        {
          id: 'bridge',
          title: 'Mi Home QR, zero home server',
          body: 'Scan one QR across six Xiaomi regions or fuse Home Assistant over local UDP 54321.',
          theme: 'paper',
          badge: 'UDP 54321',
        },
        {
          id: 'search',
          title: 'Pinyin search, zero focus theft',
          body: 'Press ⌥M, type sftd to toggle Desk Lamp, and dim via ←/→ inside a non-activating NSPanel.',
          theme: 'sand',
          badge: '⌥M · sftd',
        },
        {
          id: 'voice',
          title: 'Hold to talk, zero API key',
          body: 'Hold ⌥M 0.5s for offline LocalIntentParser commands, with optional Apple Intelligence, Ollama, or DeepSeek.',
          theme: 'sand',
          badge: '0.5s · 0 API',
        },
        {
          id: 'context',
          title: '23 desktop triggers, LIFO restore',
          body: 'React to displays, lid sleep, mic, camera, and meetings; a 32-frame stack restores prior lights.',
          theme: 'paper',
          badge: '23 triggers',
        },
        {
          id: 'all-off',
          title: 'Guarded 0.6s Hold All Off',
          body: 'A 0.6s hold dims lights while plugs, cameras, and valves stay protected, with 15s Undo.',
          theme: 'paper',
          badge: '0.6s · 15s Undo',
        },
        {
          id: 'privacy',
          title: 'Native 1.2% CPU and local MCP',
          body: 'Swift 6 (112–113 MB RAM, 0 deps) and Tauri v2 with Keychain storage, Raycast, and read-only MCP.',
          theme: 'sand',
          badge: '1.2% CPU · MCP',
        },
      ],
    },
    shortcuts: {
      h2: 'MenuBarHome shortcuts and CLI tools.',
      lead: 'Open, search by pinyin, dim lights, and run moods from the keyboard.',
      items: [
        { label: 'Toggle panel', macKeys: ['⌥', 'M'], winKeys: ['Alt', 'M'] },
        { label: 'Hold to talk (0.5s)', macKeys: ['Hold ⌥', 'M'], winKeys: ['Hold Alt', 'M'] },
        { label: 'Name or pinyin search', macKeys: ['s', 'f', 't', 'd'], winKeys: ['s', 'f', 't', 'd'] },
        { label: 'Toggle focused device', macKeys: ['↩'], winKeys: ['Enter'], note: 'Space' },
        { label: 'Step brightness, Kelvin, or temp', macKeys: ['←', '→'], winKeys: ['←', '→'] },
        { label: 'Scenes and Moods drawer', macKeys: ['⌘', 'K'], winKeys: ['Ctrl', 'K'] },
        { label: 'Jump to top 9 devices', macKeys: ['1', '…', '9'], winKeys: ['1', '…', '9'] },
        { label: 'Custom global hotkeys', macKeys: ['8 slots'], winKeys: ['8 slots'] },
        { label: 'Hold All Off with 15s Undo', macKeys: ['Hold 0.6s'], winKeys: ['Hold 0.6s'] },
        { label: 'CLI, Raycast, Shortcuts, and MCP', macKeys: ['mijia-mcp'], winKeys: ['mijia-mcp'] },
      ],
      ecosystemLabel: 'Companion stack',
      ecosystemItems: [
        { name: 'Raycast', detail: '3 views · 3 hotkeys · 3 AI tools' },
        { name: 'Python CLI', detail: 'scripts/mijia · Alfred & SwiftBar' },
        { name: 'Apple Shortcuts', detail: '8 App Intents · menubarhome://' },
        { name: 'Local MCP', detail: 'scripts/mijia-mcp --read-only' },
      ],
    },
    download: {
      h2: 'Get MenuBarHome.',
      lead: 'MIT open source for macOS 14+ and Windows 11, with offline Demo Mode on first launch.',
      macTab: 'macOS 14+ Universal',
      winTab: 'Windows 11 x64',
      macCta: 'Download for macOS',
      macSize: 'v1.4.0 .dmg · 36.7\u00A0MB · arm64 & x86_64 · Swift 6',
      winCta: 'Download for Windows',
      winSize: 'v1.4.0 .exe · 11.5\u00A0MB · Tauri v2 · Fluent 2 & Classic',
      winMsiLink: 'Windows .msi installer (15.4\u00A0MB)',
      terminalHeaderMac: 'Or install via Homebrew Cask',
      terminalHeaderWin: 'Or download and verify SHA-256 in PowerShell',
      copy: 'Copy',
      copied: 'Copied',
      shaLink: 'SHA-256 checksum',
      sbomLink: 'SPDX 2.3 SBOM',
      verifyPrefix: 'Verify build artifacts:',
      signingMac:
        'Locally signed without paid Apple notarization. Allow first launch in System Settings → Privacy & Security → Open Anyway (or xattr -dr com.apple.quarantine /Applications/MenuBarHome.app); updates verify offline Ed25519.',
      signingWin:
        'Unsigned open-source installer. On SmartScreen prompt, choose More info → Run anyway and verify the release SHA-256 checksum.',
      footprintNote: '1.2% idle CPU · 112–113\u00A0MB RSS · 0 Swift deps',
      stats: EN_STATS,
      starInvite: EN_STAR_INVITE,
    },
    footer: {
      meta: 'MenuBarHome 1.4.0 · MIT License · Unaffiliated with Xiaomi',
      links: {
        github: 'GitHub',
        devices: 'Supported Devices (32+)',
        faq: 'FAQ',
        security: 'Security & Privacy',
        zhReadme: '中文 README',
      },
      copyright: '© 2026 MenuBarHome Contributors',
    },
  },
  zh: {
    skipToContent: '跳至正文内容',
    nav: {
      features: '核心特性',
      shortcuts: '快捷键',
      github: 'GitHub',
      download: '下载',
      star: '点星',
      starred: '已点星',
      langToggle: 'EN',
      langAria: 'Switch language to English',
    },
    stats: ZH_STATS,
    starInvite: ZH_STAR_INVITE,
    hero: {
      eyebrow: 'v1.4.0 · macOS 与 Windows',
      h1: '把家留在菜单栏。',
      h1Prefix: '把家留在',
      h1Accent: '菜单栏。',
      lead: '米家扫码或融合 Home Assistant，用键盘直控灯光、空调、窗帘与云台摄像头。',
      downloadMac: '下载 macOS 版',
      downloadWin: '下载 Windows 11 版',
      switchToWin: '也有 Windows 11 版',
      switchToMac: '也有 macOS 版',
      secondaryCta: '聚焦操控 iMac',
      focusImacLabel: '聚焦 iMac',
      exitFocusLabel: '返回书房',
      focusBannerHint: '已聚焦蓝色 iMac · 按 Esc 返回',
      specLine: 'v1.4.0 · 空闲 1.2% CPU · MIT',
      stageHint: '点击蓝色 iMac 操控 macOS',
      soundOn: '音效开',
      soundOff: '音效关',
      launch3D: '启动 3D 书房',
      presets: {
        evening: '日落傍晚',
        focus: '专注办公',
        movie: '拉帘观影',
      },
      hud: {
        open: '搜索',
        step: '调光',
        pinyin: 'sftd → 台灯',
        dragHint: '拖拽微调视角',
      },
      popover: {
        homeTitle: '傍晚书房',
        activeSuffix: '台开启',
        allOffLabel: '长按全关',
        holdHint: '长按 0.6 秒',
        holdingLabel: '长按中...',
        searchPlaceholder: '搜索房间或拼音首字母 (sftd)',
        deskTab: '米家台灯',
        ceilingTab: '米家吸顶灯',
        lampName: '米家台灯 1S',
        ceilingName: '米家吸顶灯',
        lightBarName: '显示器挂灯',
        lightBarOn: '非对称桌面补光',
        curtainsName: '米家电动窗帘',
        curtainsOpen: '全开 · 落日洒入',
        curtainsHalf: '半开 · 柔和余晖',
        curtainsClosed: '闭合 · 静谧室内',
        curtainSunHint: '落日开合',
        acName: '米家壁挂空调',
        acOff: '已待机',
        acCool: '制冷',
        plugName: '米家智能插座',
        plugProtected: '受保护 · 42W',
        doorbellName: '前门门铃',
        doorbellPin: '置顶画中画',
        doorbellPinned: '已置顶',
        videoOnly: '仅视频',
        brightness: '亮度',
        kelvin: '色温',
        undoBannerPrefix: '已关闭',
        undoBannerSuffix: '台设备 · 插座受保护',
        undoAction: '撤销',
        offLabel: '已关闭',
      },
    },
    features: {
      eyebrow: '核心长板',
      h2: '全屋设备，一步直达。',
      h2Prefix: '全屋设备，',
      h2Accent: '一步直达。',
      lead: '围绕键盘效率、局域网直连与桌面情境打造的原生控制中心。',
      pauseDemos: '暂停演示动效',
      resumeDemos: '播放演示动效',
      cameraSpotlight: {
        eyebrow: 'go2rtc 本地回环',
        title: '实时摄像头、拖拽云台与门铃画中画',
        titlePrefix: '实时摄像头、拖拽云台与',
        titleAccent: '门铃画中画',
        body: '内置本地 go2rtc 桥接，桌面直开拖拽云台、广角长焦双摄与 3:4 置顶门铃画中画。',
        ctaOpen: '打开实时画面',
        ctaHint: '点击体验拖拽云台、双摄切换与快捷开关',
        specs: ['go2rtc 本地回环', '云台 + 双摄切换', '3:4 门铃画中画'],
        modalTitle: '前门门铃与书房摄像机',
        modalSubtitle: 'go2rtc 本地回环 · 默认静音',
        liveBadge: '实时',
        loopbackBadge: '127.0.0.1 · Basic Auth',
        videoOnlyBadge: '仅视频',
        ptzDragHint: '拖拽画面或点方向键控制云台转动',
        resetView: '云台回中',
        lensWide: '1× 广角',
        lensTele: '3× 长焦',
        modeLive: '实时云台',
        modePip: '3:4 门铃画中画',
        modeWall: '2×2 画面墙',
        pinnedSwitchesLabel: '画中画快捷开关（最多 2 个）',
        porchLightLabel: '玄关门廊灯',
        deskLampLabel: '米家台灯 1S',
        eventsTitle: '本地事件记录',
        eventsMeta: '7 天 · 500 条',
        closeLabel: '关闭画面',
        autoOpenNote: '门铃按响自动弹窗倒计时：默认 30 秒',
        events: [
          { time: '17:41:12', title: '前门门铃按响 · 自动弹起画中画', zone: '入户门廊' },
          { time: '17:18:04', title: '检测到门口移动 · 已过滤夕阳反光', zone: '玄关外侧' },
          { time: '16:05:39', title: '快递已放置门口', zone: '入户门廊' },
        ],
      },
      items: [
        {
          id: 'bridge',
          title: '米家扫码直连，免家庭服务器',
          body: '扫码直连小米云 6 大区域或融合 Home Assistant，支持局域网 AES UDP 54321 直控。',
          theme: 'paper',
          badge: 'UDP 54321',
        },
        {
          id: 'search',
          title: '拼音首字母秒搜，不抢焦点',
          body: '按 ⌥M 输入 sftd 直达书房台灯，方向键调光；非激活 NSPanel 不打断当前窗口。',
          theme: 'sand',
          badge: '⌥M · sftd',
        },
        {
          id: 'voice',
          title: '长按 0.5s 说话，零 API Key',
          body: '长按 ⌥M 0.5 秒离线执行 LocalIntentParser 指令，可选接 Apple Intelligence 或 Ollama。',
          theme: 'sand',
          badge: '0.5s · 0 API',
        },
        {
          id: 'context',
          title: '23 项桌面触发器，会后还原',
          body: '响应外接屏、合盖、摄像头与会议自动补光，32 帧 LIFO 栈在结束后还原灯光。',
          theme: 'paper',
          badge: '23 触发器',
        },
        {
          id: 'all-off',
          title: '0.6s 长按全关，15 秒撤销',
          body: '长按 0.6 秒才触发全关，插座、摄像头与水阀默认受保护，15 秒内可一键撤销。',
          theme: 'paper',
          badge: '0.6s · 15s 撤销',
        },
        {
          id: 'privacy',
          title: '1.2% 轻量占用与本地 MCP',
          body: 'Swift 6 零依赖（112–113 MB）与 Tauri v2，凭据独存钥匙串，支持 Raycast 与只读 MCP。',
          theme: 'sand',
          badge: '1.2% CPU · MCP',
        },
      ],
    },
    shortcuts: {
      h2: 'MenuBarHome 快捷键与工具链。',
      lead: '呼出面板、拼音搜索、调光与切换氛围，全程双手不离键盘。',
      items: [
        { label: '打开或收起面板', macKeys: ['⌥', 'M'], winKeys: ['Alt', 'M'] },
        { label: '长按说话（0.5 秒）', macKeys: ['长按 ⌥', 'M'], winKeys: ['长按 Alt', 'M'] },
        { label: '名称或拼音首字母搜索', macKeys: ['s', 'f', 't', 'd'], winKeys: ['s', 'f', 't', 'd'] },
        { label: '切换选中设备开关', macKeys: ['↩'], winKeys: ['Enter'], note: 'Space' },
        { label: '调节亮度、色温或温度', macKeys: ['←', '→'], winKeys: ['←', '→'] },
        { label: '场景与氛围抽屉', macKeys: ['⌘', 'K'], winKeys: ['Ctrl', 'K'] },
        { label: '直达置顶前 9 台设备', macKeys: ['1', '…', '9'], winKeys: ['1', '…', '9'] },
        { label: '自定义全局热键', macKeys: ['8 组'], winKeys: ['8 组'] },
        { label: '长按全关与 15 秒撤销', macKeys: ['长按 0.6s'], winKeys: ['长按 0.6s'] },
        { label: 'CLI、Raycast、快捷指令与 MCP', macKeys: ['mijia-mcp'], winKeys: ['mijia-mcp'] },
      ],
      ecosystemLabel: '开放生态栈',
      ecosystemItems: [
        { name: 'Raycast 扩展', detail: '3 视图 · 3 热键 · 3 AI 工具' },
        { name: 'Python CLI', detail: 'scripts/mijia · Alfred & SwiftBar' },
        { name: 'Apple 快捷指令', detail: '8 项 App Intents · menubarhome://' },
        { name: '本地 MCP 服务', detail: 'scripts/mijia-mcp --read-only' },
      ],
    },
    download: {
      h2: '获取 MenuBarHome。',
      lead: 'MIT 开源免费，支持 macOS 14+ 与 Windows 11，首次启动可免登录体验离线 Demo。',
      macTab: 'macOS 14+ 通用版',
      winTab: 'Windows 11 x64',
      macCta: '下载 macOS 安装包',
      macSize: 'v1.4.0 .dmg · 36.7\u00A0MB · arm64 & x86_64 · Swift 6',
      winCta: '下载 Windows 安装包',
      winSize: 'v1.4.0 .exe · 11.5\u00A0MB · Tauri v2 · Fluent 2 与 Classic',
      winMsiLink: 'Windows .msi 企业安装包（15.4\u00A0MB）',
      terminalHeaderMac: '或通过 Homebrew Cask 安装',
      terminalHeaderWin: '或在 PowerShell 中下载并校验 SHA-256',
      copy: '复制',
      copied: '已复制',
      shaLink: 'SHA-256 校验值',
      sbomLink: 'SPDX 2.3 SBOM',
      verifyPrefix: '构建完整性校验：',
      signingMac:
        '个人开源项目采用本地签名，首次打开请在「系统设置 → 隐私与安全性」点击「仍要打开」（或运行 xattr -dr com.apple.quarantine /Applications/MenuBarHome.app）；更新支持离线 Ed25519 验签。',
      signingWin:
        '无商业代码签名证书。若 SmartScreen 提示，点「更多信息 → 仍要运行」并核对官方 SHA-256 校验值。',
      footprintNote: '空闲 1.2% CPU · 112–113\u00A0MB 内存 · 零第三方 Swift 依赖',
      stats: ZH_STATS,
      starInvite: ZH_STAR_INVITE,
    },
    footer: {
      meta: 'MenuBarHome 1.4.0 · MIT 开源协议 · 与小米官方无隶属关系',
      links: {
        github: 'GitHub',
        devices: '支持设备清单 (32+)',
        faq: '常见问题',
        security: '安全与隐私',
        zhReadme: '中文说明',
      },
      copyright: '© 2026 MenuBarHome Contributors',
    },
  },
};
