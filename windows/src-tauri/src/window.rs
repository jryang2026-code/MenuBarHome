use super::*;
use crate::placement::*;

const SAME_CLICK_FALLBACK_MS: u64 = 65;
const SAME_CLICK_SPATIAL_MS: u64 = 250;
/// Logical padding added around the tray icon rect for same-click focus-loss hit-testing.
const TRAY_RECT_PAD_LOGICAL_PX: f64 = 8.0;
/// Logical fallback slop when only cursor coordinates (no tray rect) are available.
const TRAY_CURSOR_SLOP_LOGICAL_PX: f64 = 24.0;
const MAX_TRAY_HOLD_MS: u64 = 5_000;
const DEFAULT_PANEL_LOGICAL_HEIGHT: f64 = 680.0;
const WIN32_WS_EX_TOOLWINDOW: u32 = 0x0000_0080;
const WIN32_WS_EX_APPWINDOW: u32 = 0x0004_0000;

pub(crate) static PIN_POPOVER: AtomicBool = AtomicBool::new(false);
static SETTINGS_ALLOW_CLOSE: AtomicBool = AtomicBool::new(false);
static PANEL_LOGICAL_HEIGHT_BITS: AtomicU64 =
    AtomicU64::new(DEFAULT_PANEL_LOGICAL_HEIGHT.to_bits());

pub(crate) fn desired_panel_logical_height() -> f64 {
    let val = f64::from_bits(PANEL_LOGICAL_HEIGHT_BITS.load(Ordering::SeqCst));
    if val.is_finite() && val >= 0.0 {
        val
    } else {
        DEFAULT_PANEL_LOGICAL_HEIGHT
    }
}

pub(crate) fn remember_panel_logical_height(height: f64) {
    if height.is_finite() && height >= 0.0 {
        PANEL_LOGICAL_HEIGHT_BITS.store(height.to_bits(), Ordering::SeqCst);
    }
}

/// Computes the target Win32 extended style for a tray flyout: adds `WS_EX_TOOLWINDOW` and strips
/// `WS_EX_APPWINDOW` so the flyout never appears in `Alt+Tab` / `Win+Tab` or resurrects a taskbar
/// button after `explorer.exe` restarts.
pub(crate) fn tool_window_ex_style(current_ex_style: u32) -> u32 {
    (current_ex_style & !WIN32_WS_EX_APPWINDOW) | WIN32_WS_EX_TOOLWINDOW
}

fn sanitize_scale(scale: f64) -> f64 {
    if scale.is_finite() && scale > 0.0 {
        scale
    } else {
        1.0
    }
}

/// Computes the physical `(width, height)` for the panel on a destination monitor using the
/// remembered logical size and the destination monitor's `scale_factor()`, never the stale
/// `outer_size()` from a previous monitor with a different DPI.
pub(crate) fn compute_target_physical_size(
    logical_w: f64,
    requested_logical_h: f64,
    work: Rect,
    margin: i32,
    scale: f64,
) -> (i32, i32) {
    let safe_scale = sanitize_scale(scale);
    let avail_w = (work.width - margin * 2).max(1);
    let avail_h = (work.height - margin * 2).max(1);
    let work_logical_w = (avail_w as f64) / safe_scale;
    let work_logical_h = (avail_h as f64) / safe_scale;
    let target_logical_w = logical_w.min(work_logical_w).max(1.0);
    let target_logical_h = clamp_outer_panel_height(requested_logical_h, work_logical_h);
    let phys_w = ((target_logical_w * safe_scale).round() as i32).clamp(1, avail_w);
    let phys_h = fit_panel_height(work, margin, (target_logical_h * safe_scale).round() as i32);
    (phys_w, phys_h)
}

/// Re-clamps an existing panel rect into `work` after a `ScaleFactorChanged` transition.
/// Returns `Some((x, y, w, h))` only when the bounds actually need adjustment (idempotent).
pub(crate) fn reclamped_bounds_for_scale(
    current_pos: (i32, i32),
    current_size: (i32, i32),
    work: Rect,
    margin: i32,
    logical_w: f64,
    requested_logical_h: f64,
    scale: f64,
) -> Option<(i32, i32, i32, i32)> {
    let (target_w, target_h) =
        compute_target_physical_size(logical_w, requested_logical_h, work, margin, scale);
    let min_x = work.x + margin;
    let min_y = work.y + margin;
    let max_x = (work.right() - target_w - margin).max(min_x);
    let max_y = (work.bottom() - target_h - margin).max(min_y);
    let clamped_x = current_pos.0.clamp(min_x, max_x);
    let clamped_y = current_pos.1.clamp(min_y, max_y);
    if (clamped_x, clamped_y, target_w, target_h)
        == (current_pos.0, current_pos.1, current_size.0, current_size.1)
    {
        None
    } else {
        Some((clamped_x, clamped_y, target_w, target_h))
    }
}

pub(crate) fn physical_rect_from_tauri(rect: tauri::Rect, scale: f64) -> Rect {
    let safe_scale = sanitize_scale(scale);
    let pos = rect.position.to_physical::<i32>(safe_scale);
    let size = rect.size.to_physical::<u32>(safe_scale);
    Rect::new(pos.x, pos.y, size.width as i32, size.height as i32)
}

pub(crate) fn consume_settings_allow_close(flag: &AtomicBool) -> bool {
    flag.swap(false, Ordering::SeqCst)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TrayToggleAction {
    Present,
    Hide,
    Noop,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FocusLossMark {
    at_ms: u64,
    cursor: Option<(i32, i32)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TrayPressMark {
    at_ms: u64,
    dismissed: bool,
}

fn is_same_tray_click_focus_loss(
    mark: FocusLossMark,
    now_ms: u64,
    tray_cursor: Option<(i32, i32)>,
    tray_rect: Option<Rect>,
    scale: f64,
) -> bool {
    let elapsed = now_ms.saturating_sub(mark.at_ms);
    let safe_scale = sanitize_scale(scale);
    match mark.cursor {
        Some((fx, fy)) => {
            if let Some(rect) = tray_rect.filter(|r| r.width > 0 && r.height > 0) {
                let pad_px = (TRAY_RECT_PAD_LOGICAL_PX * safe_scale).round() as i32;
                elapsed <= SAME_CLICK_SPATIAL_MS
                    && point_in_expanded_rect((fx, fy), rect, pad_px)
            } else if let Some((tx, ty)) = tray_cursor {
                let slop_px = (TRAY_CURSOR_SLOP_LOGICAL_PX * safe_scale).round() as i32;
                elapsed <= SAME_CLICK_SPATIAL_MS
                    && (fx - tx).abs() <= slop_px
                    && (fy - ty).abs() <= slop_px
            } else {
                elapsed <= SAME_CLICK_FALLBACK_MS
            }
        }
        None => elapsed <= SAME_CLICK_FALLBACK_MS,
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct PanelVisibilityState {
    pub(crate) seq: u64,
    pub(crate) closing: bool,
    return_focus_to_tray: bool,
    focus_loss: Option<FocusLossMark>,
    tray_press: Option<TrayPressMark>,
}

impl PanelVisibilityState {
    pub(crate) fn begin_present(&mut self) -> u64 {
        self.seq = self.seq.wrapping_add(1);
        self.closing = false;
        self.return_focus_to_tray = false;
        self.focus_loss = None;
        self.tray_press = None;
        self.seq
    }

    pub(crate) fn begin_hide(&mut self, is_visible: bool) -> Option<u64> {
        self.begin_hide_with_focus(is_visible, false)
    }

    pub(crate) fn begin_hide_with_focus(
        &mut self,
        is_visible: bool,
        return_focus: bool,
    ) -> Option<u64> {
        if !is_visible {
            self.closing = false;
            self.return_focus_to_tray = false;
            self.focus_loss = None;
            return None;
        }
        if self.closing {
            return None;
        }
        self.closing = true;
        self.return_focus_to_tray = return_focus;
        self.seq = self.seq.wrapping_add(1);
        Some(self.seq)
    }

    pub(crate) fn complete_hide(&mut self, requested_seq: u64) -> bool {
        self.complete_hide_with_focus(requested_seq).is_some()
    }

    pub(crate) fn complete_hide_with_focus(&mut self, requested_seq: u64) -> Option<bool> {
        if !should_complete_hide(self.closing, self.seq, requested_seq) {
            return None;
        }
        self.closing = false;
        self.focus_loss = None;
        Some(std::mem::take(&mut self.return_focus_to_tray))
    }

    pub(crate) fn abort_hide(&mut self) {
        self.closing = false;
        self.return_focus_to_tray = false;
        self.focus_loss = None;
    }

    pub(crate) fn clear_tray_press(&mut self) {
        self.tray_press = None;
    }

    pub(crate) fn note_focus_loss(&mut self, now_ms: u64, cursor: Option<(i32, i32)>) {
        // If focus moved elsewhere during the dismiss animation (e.g. a mouse click outside),
        // do not yank keyboard focus back to the taskbar when the hide completes.
        if self.closing {
            self.return_focus_to_tray = false;
        }
        self.focus_loss = Some(FocusLossMark {
            at_ms: now_ms,
            cursor,
        });
    }

    pub(crate) fn note_tray_press_down(
        &mut self,
        is_open: bool,
        now_ms: u64,
        cursor: Option<(i32, i32)>,
        tray_rect: Option<Rect>,
        scale: f64,
    ) {
        let same_click_focus_loss = self.focus_loss.take().is_some_and(|mark| {
            self.closing && is_same_tray_click_focus_loss(mark, now_ms, cursor, tray_rect, scale)
        });
        self.tray_press = Some(TrayPressMark {
            at_ms: now_ms,
            dismissed: is_open || same_click_focus_loss,
        });
    }

    pub(crate) fn decide_tray_release(
        &mut self,
        is_open: bool,
        now_ms: u64,
        cursor: Option<(i32, i32)>,
        tray_rect: Option<Rect>,
        scale: f64,
    ) -> TrayToggleAction {
        let active_press = self
            .tray_press
            .take()
            .filter(|press| now_ms.saturating_sub(press.at_ms) <= MAX_TRAY_HOLD_MS);
        let saw_down = active_press.is_some();
        let was_dismiss_press = active_press.is_some_and(|press| press.dismissed);
        let recent_focus_loss = self.focus_loss.take().is_some_and(|mark| {
            !saw_down
                && self.closing
                && is_same_tray_click_focus_loss(mark, now_ms, cursor, tray_rect, scale)
        });
        if is_open {
            TrayToggleAction::Hide
        } else if was_dismiss_press || recent_focus_loss {
            TrayToggleAction::Noop
        } else {
            TrayToggleAction::Present
        }
    }
}

static PANEL_VISIBILITY: LazyLock<std::sync::Mutex<PanelVisibilityState>> =
    LazyLock::new(|| std::sync::Mutex::new(PanelVisibilityState::default()));

/// Window pixels reserved around the card column for the panel's own drop shadow. `#app { padding }`
/// in `styles.css` carries the same value on all four sides.
pub(crate) const PANEL_PADDING: f64 = 16.0;
/// Logical width of the Win11 `Win+N` + `Win+A` two-island flyout column (matches native `Win+A` 360–380 epx).
pub(crate) const PANEL_MAIN_WIDTH: f64 = 380.0;
pub(crate) const CLASSIC_MAIN_WIDTH: f64 = 440.0;
pub(crate) const PANEL_MIN_WORK_HEIGHT: f64 = 480.0;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum PanelTheme {
    Fluent,
    #[default]
    Classic,
}

impl PanelTheme {
    pub(crate) const fn main_width(self) -> f64 {
        match self { Self::Fluent => PANEL_MAIN_WIDTH, Self::Classic => CLASSIC_MAIN_WIDTH }
    }

    pub(crate) const fn window_width(self) -> f64 {
        self.main_width() + PANEL_PADDING * 2.0
    }

    pub(crate) const fn window_width_for_backdrop(self, supports_backdrop: bool) -> f64 {
        if crate::win_theme::classic_uses_native_chrome(self, supports_backdrop) {
            self.main_width()
        } else {
            self.window_width()
        }
    }

    const fn as_u8(self) -> u8 {
        match self { Self::Fluent => 0, Self::Classic => 1 }
    }

    const fn from_u8(raw: u8) -> Self {
        if raw == 0 { Self::Fluent } else { Self::Classic }
    }
}

static ACTIVE_PANEL_THEME: std::sync::atomic::AtomicU8 =
    std::sync::atomic::AtomicU8::new(PanelTheme::Classic.as_u8());

pub(crate) fn active_panel_theme() -> PanelTheme {
    PanelTheme::from_u8(ACTIVE_PANEL_THEME.load(Ordering::SeqCst))
}

pub(crate) fn set_active_panel_theme(theme: PanelTheme) {
    ACTIVE_PANEL_THEME.store(theme.as_u8(), Ordering::SeqCst);
}

pub(crate) fn panel_window_width() -> f64 {
    active_panel_theme().window_width()
}

pub(crate) fn effective_panel_window_width() -> f64 {
    active_panel_theme()
        .window_width_for_backdrop(crate::win_theme::current_supports_system_backdrop())
}

pub(crate) fn effective_main_column_inset(scale: f64) -> i32 {
    if crate::win_theme::classic_uses_native_chrome(
        active_panel_theme(),
        crate::win_theme::current_supports_system_backdrop(),
    ) {
        0
    } else {
        main_column_inset(scale)
    }
}

pub(crate) fn sync_main_window_chrome(window: &WebviewWindow, visible: bool) {
    let snapshot = crate::win_theme::current_theme_snapshot();
    let theme = active_panel_theme();
    let native_classic =
        crate::win_theme::classic_uses_native_chrome(theme, snapshot.supports_system_backdrop);
    let _ = window.set_shadow(native_classic);
    crate::win_theme::apply_window_corner_preference(window, native_classic);
    if snapshot.windows_build > 0 {
        apply_dark_titlebar(window, !snapshot.apps_use_light_theme);
    }
    crate::win_theme::apply_window_backdrop(
        window,
        crate::win_theme::desired_panel_backdrop(theme, snapshot.supports_system_backdrop, visible),
    );
}

pub(crate) fn sync_settings_window_chrome(window: &WebviewWindow) {
    let snapshot = crate::win_theme::current_theme_snapshot();
    let dark = if snapshot.windows_build > 0 {
        !snapshot.apps_use_light_theme
    } else {
        matches!(window.theme(), Ok(tauri::Theme::Dark))
    };
    apply_dark_titlebar(window, dark);
    crate::win_theme::apply_window_backdrop(
        window,
        crate::win_theme::desired_settings_backdrop(snapshot.supports_system_backdrop),
    );
}

pub(crate) fn clamp_outer_panel_height(requested_outer_height: f64, work_logical_height: f64) -> f64 {
    let max_h = work_logical_height.max(PANEL_MIN_WORK_HEIGHT);
    if requested_outer_height <= 0.0 {
        max_h
    } else {
        requested_outer_height.min(max_h)
    }
}

/// Pure guard ensuring a delayed close callback never hides a panel that was reopened in the meantime.
pub(crate) fn should_complete_hide(closing: bool, active_seq: u64, requested_seq: u64) -> bool {
    closing && active_seq == requested_seq
}

/// Maps the monitor taskbar edge and placement preference to the Win11 flyout slide origin edge.
pub(crate) fn flyout_edge_name(edge: TaskbarEdge, preference: PanelAnchor) -> &'static str {
    match preference {
        PanelAnchor::Auto => match edge {
            TaskbarEdge::Top => "top",
            TaskbarEdge::Left => "left",
            TaskbarEdge::Right => "right",
            TaskbarEdge::Bottom | TaskbarEdge::None => "bottom",
        },
        PanelAnchor::TopLeft | PanelAnchor::TopRight => "top",
        PanelAnchor::BottomLeft | PanelAnchor::BottomRight => "bottom",
    }
}

/// Reports whether the flyout is currently open so cold-launched WebView2 can park its swapchain
/// at opacity 0 before the very first Win32 `ShowWindow`.
#[tauri::command]
pub(crate) fn panel_is_visible(app: AppHandle) -> bool {
    let visible = app
        .get_webview_window("main")
        .and_then(|window| window.is_visible().ok())
        .unwrap_or(false);
    let closing = PANEL_VISIBILITY
        .lock()
        .map(|state| state.closing)
        .unwrap_or(false);
    visible && !closing
}

fn physical_point(pos: Option<PhysicalPosition<f64>>) -> Option<(i32, i32)> {
    pos.map(|p| (p.x.round() as i32, p.y.round() as i32))
}

#[cfg(all(windows, not(test)))]
fn current_cursor_position() -> Option<(i32, i32)> {
    #[repr(C)]
    struct WinPoint {
        x: i32,
        y: i32,
    }
    #[link(name = "user32")]
    extern "system" {
        fn GetCursorPos(point: *mut WinPoint) -> i32;
    }
    let mut point = WinPoint { x: 0, y: 0 };
    if unsafe { GetCursorPos(&mut point) } != 0 {
        Some((point.x, point.y))
    } else {
        None
    }
}

#[cfg(any(not(windows), test))]
fn current_cursor_position() -> Option<(i32, i32)> {
    None
}

pub(crate) fn note_panel_focus_loss() {
    let cursor = current_cursor_position();
    if let Ok(mut state) = PANEL_VISIBILITY.lock() {
        state.note_focus_loss(now_epoch_ms(), cursor);
    }
}

fn monitor_scale_at(window: &WebviewWindow, anchor: Option<PhysicalPosition<f64>>) -> f64 {
    let monitor = anchor
        .and_then(|pos| window.monitor_from_point(pos.x, pos.y).ok().flatten())
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());
    sanitize_scale(monitor.map(|m| m.scale_factor()).unwrap_or(1.0))
}

#[cfg(all(windows, not(test)))]
fn set_window_bounds_sync(window: &WebviewWindow, x: i32, y: i32, w: i32, h: i32) {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        SetWindowPos, SWP_NOACTIVATE, SWP_NOZORDER,
    };

    let safe_w = w.max(1);
    let safe_h = h.max(1);
    let Ok(raw_hwnd) = window.hwnd() else {
        let _ = window.set_size(PhysicalSize::new(safe_w as u32, safe_h as u32));
        let _ = window.set_position(PhysicalPosition::new(x, y));
        return;
    };
    let hwnd = (raw_hwnd.0 as usize) as HWND;
    let ok = unsafe {
        SetWindowPos(
            hwnd,
            std::ptr::null_mut(),
            x,
            y,
            safe_w,
            safe_h,
            SWP_NOZORDER | SWP_NOACTIVATE,
        )
    };
    if ok == 0 {
        let _ = window.set_size(PhysicalSize::new(safe_w as u32, safe_h as u32));
        let _ = window.set_position(PhysicalPosition::new(x, y));
    }
}

#[cfg(any(not(windows), test))]
fn set_window_bounds_sync(window: &WebviewWindow, x: i32, y: i32, w: i32, h: i32) {
    let _ = window.set_size(PhysicalSize::new(w.max(1) as u32, h.max(1) as u32));
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

#[cfg(all(windows, not(test)))]
pub(crate) fn apply_tool_window_style(window: &WebviewWindow) {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetWindowLongW, SetWindowLongW, SetWindowPos, GWL_EXSTYLE, SWP_FRAMECHANGED,
        SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER,
    };

    let Ok(raw_hwnd) = window.hwnd() else {
        return;
    };
    let hwnd = (raw_hwnd.0 as usize) as HWND;
    let current = unsafe { GetWindowLongW(hwnd, GWL_EXSTYLE) } as u32;
    let next = tool_window_ex_style(current);
    if next != current {
        unsafe {
            let _ = SetWindowLongW(hwnd, GWL_EXSTYLE, next as i32);
            let _ = SetWindowPos(
                hwnd,
                std::ptr::null_mut(),
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
            );
        }
    }
}

#[cfg(any(not(windows), test))]
pub(crate) fn apply_tool_window_style(_window: &WebviewWindow) {}

#[cfg(all(windows, not(test)))]
pub(crate) fn set_window_cloaked(window: &WebviewWindow, cloaked: bool) {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_CLOAK};

    let Ok(raw_hwnd) = window.hwnd() else {
        return;
    };
    let hwnd = (raw_hwnd.0 as usize) as HWND;
    let value: i32 = if cloaked { 1 } else { 0 };
    unsafe {
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_CLOAK as u32,
            &value as *const i32 as *const core::ffi::c_void,
            std::mem::size_of::<i32>() as u32,
        );
    }
}

#[cfg(any(not(windows), test))]
pub(crate) fn set_window_cloaked(_window: &WebviewWindow, _cloaked: bool) {}

pub(crate) fn handle_tray_mouse_down(
    app: &AppHandle,
    anchor: Option<PhysicalPosition<f64>>,
    tray_rect: Option<tauri::Rect>,
) {
    let cursor = physical_point(anchor);
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        let (is_visible, scale) = app_clone
            .get_webview_window("main")
            .map(|window| {
                (
                    window.is_visible().unwrap_or(false),
                    monitor_scale_at(&window, anchor),
                )
            })
            .unwrap_or((false, 1.0));
        let phys_rect = tray_rect.map(|r| physical_rect_from_tauri(r, scale));
        if let Ok(mut state) = PANEL_VISIBILITY.lock() {
            let is_open = is_visible && !state.closing;
            state.note_tray_press_down(is_open, now_epoch_ms(), cursor, phys_rect, scale);
        }
    });
}

#[cfg(all(windows, not(test)))]
fn return_focus_to_tray(app: &AppHandle) {
    use windows_sys::Win32::Foundation::{HWND, RECT, S_OK};
    use windows_sys::Win32::UI::Shell::{
        Shell_NotifyIconGetRect, Shell_NotifyIconW, NIM_SETFOCUS, NOTIFYICONDATAW,
        NOTIFYICONIDENTIFIER,
    };

    let Some(tray) = app.tray_by_id("main-tray") else {
        return;
    };
    let Ok(raw_hwnd) = tray.with_inner_tray_icon(|inner| inner.window_handle() as usize) else {
        return;
    };
    if raw_hwnd == 0 {
        return;
    }
    let tray_hwnd = raw_hwnd as HWND;

    // `tray-icon` assigns its private `uID` from a process-wide counter starting at 1, and
    // `TrayIconBuilder::new()` may consume one before `TrayIcon::new`. Probe `Shell_NotifyIconGetRect`
    // first to locate the exact `uID`, then fall back to trying the first few IDs directly.
    let mut resolved_uid: Option<u32> = None;
    for candidate in 1..=8 {
        let mut ident: NOTIFYICONIDENTIFIER = unsafe { std::mem::zeroed() };
        ident.cbSize = std::mem::size_of::<NOTIFYICONIDENTIFIER>() as u32;
        ident.hWnd = tray_hwnd;
        ident.uID = candidate;
        let mut rect: RECT = unsafe { std::mem::zeroed() };
        if unsafe { Shell_NotifyIconGetRect(&ident, &mut rect) } == S_OK {
            resolved_uid = Some(candidate);
            break;
        }
    }

    let send_focus = |uid: u32| -> bool {
        let mut nid: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
        nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
        nid.hWnd = tray_hwnd;
        nid.uID = uid;
        unsafe { Shell_NotifyIconW(NIM_SETFOCUS, &nid) != 0 }
    };

    if let Some(uid) = resolved_uid {
        let _ = send_focus(uid);
        return;
    }
    for candidate in 1..=8 {
        if send_focus(candidate) {
            break;
        }
    }
}

#[cfg(any(not(windows), test))]
fn return_focus_to_tray(_app: &AppHandle) {}

fn complete_hide_panel_on_main_thread(app: &AppHandle, seq: u64) {
    let Some(return_focus) = PANEL_VISIBILITY
        .lock()
        .ok()
        .and_then(|mut state| state.complete_hide_with_focus(seq))
    else {
        return;
    };
    if return_focus {
        return_focus_to_tray(app);
    }
    if let Some(window) = app.get_webview_window("main") {
        crate::win_theme::apply_window_backdrop(&window, crate::win_theme::BackdropKind::None);
        set_window_cloaked(&window, true);
        let _ = window.hide();
        crate::webview_lifecycle::schedule_panel_low_memory(app);
    }
}

fn request_hide_panel_on_main_thread_with_focus(app: &AppHandle, return_focus: bool) {
    crate::webview_lifecycle::cancel_pending_panel_present();
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let is_visible = window.is_visible().unwrap_or(false);
    let Some(seq) = PANEL_VISIBILITY
        .lock()
        .ok()
        .and_then(|mut state| state.begin_hide_with_focus(is_visible, return_focus))
    else {
        return;
    };
    let edge = current_flyout_edge(&window, None);
    let script = format!(
        "window.dispatchEvent(new CustomEvent('menumijia:panel-dismiss', {{ detail: {{ seq: {seq}, edge: '{edge}' }} }}))"
    );
    if window.eval(&script).is_err() {
        if let Ok(mut state) = PANEL_VISIBILITY.lock() {
            state.abort_hide();
        }
        if return_focus {
            return_focus_to_tray(app);
        }
        crate::win_theme::apply_window_backdrop(&window, crate::win_theme::BackdropKind::None);
        set_window_cloaked(&window, true);
        let _ = window.hide();
        crate::webview_lifecycle::schedule_panel_low_memory(app);
        return;
    }
    let app_clone = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(230));
        complete_hide_panel(&app_clone, seq);
    });
}

fn request_hide_panel_on_main_thread(app: &AppHandle) {
    request_hide_panel_on_main_thread_with_focus(app, false);
}

pub(crate) fn complete_hide_panel(app: &AppHandle, seq: u64) {
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        complete_hide_panel_on_main_thread(&app_clone, seq);
    });
}

pub(crate) fn request_hide_panel_with_focus(app: &AppHandle, return_focus: bool) {
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        request_hide_panel_on_main_thread_with_focus(&app_clone, return_focus);
    });
}

pub(crate) fn request_hide_panel(app: &AppHandle) {
    request_hide_panel_with_focus(app, false);
}

#[tauri::command]
pub(crate) fn hide_panel(app: AppHandle, return_focus: Option<bool>) {
    request_hide_panel_with_focus(&app, return_focus.unwrap_or(false));
}

#[tauri::command]
pub(crate) fn finish_hide_panel(app: AppHandle, seq: u64) {
    complete_hide_panel(&app, seq);
}

#[tauri::command]
pub(crate) fn quit_app(app: AppHandle) {
    shutdown_camera_daemons();
    app.exit(0);
}

#[tauri::command]
pub(crate) fn set_pin_popover(pin: bool) {
    PIN_POPOVER.store(pin, Ordering::SeqCst);
}

/// The persisted placement the settings sheet shows and every open honours (#204).
#[tauri::command]
pub(crate) fn panel_placement() -> PanelPlacement {
    current_panel_placement()
}

#[tauri::command]
pub(crate) fn set_panel_placement(app: AppHandle, anchor: PanelAnchor) -> Result<(), String> {
    let saved = store_panel_placement(PanelPlacement { anchor });
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            let _ = position_popover(&window, None, None);
        }
    }
    saved
}

/// The panel has no title bar, so a press on the header hands over to the OS move loop (#204).
#[tauri::command]
pub(crate) fn start_panel_drag(app: AppHandle, window: WebviewWindow) {
    // A header press is user movement from here on: stop ignoring `Moved` events even if the panel was
    // placed moments ago, and let the settle watcher end the session once the pointer rests.
    USER_DRAG_ACTIVE.store(true, Ordering::SeqCst);
    USER_MOVES_SEEN.store(false, Ordering::SeqCst);
    PROGRAMMATIC_MOVE_UNTIL_MS.store(0, Ordering::SeqCst);
    schedule_drag_settle(app);
    let _ = window.start_dragging();
}

/// Panel placement preference (auto or a fixed work-area corner). It lives beside the window rather
/// than in the webview's local storage because a drag has to save it from the window event loop (#204).
static PANEL_PLACEMENT: LazyLock<RwLock<PanelPlacement>> =
    LazyLock::new(|| RwLock::new(PanelPlacement::default()));

/// Until this timestamp, `Moved` events come from our own placement calls, not from a drag.
static PROGRAMMATIC_MOVE_UNTIL_MS: AtomicU64 = AtomicU64::new(0);
/// Set from a header press until the drag settles; while it is set, placement calls must not swallow
/// the movement the user is producing (#204 review).
static USER_DRAG_ACTIVE: AtomicBool = AtomicBool::new(false);
/// Whether the current drag session actually moved the window, so a plain click never snaps it.
static USER_MOVES_SEEN: AtomicBool = AtomicBool::new(false);
/// Last user-driven move; the drag is over once the window stops moving for a moment.
static MOVE_SNAP_DEADLINE_MS: AtomicU64 = AtomicU64::new(0);
static MOVE_SNAP_SCHEDULED: AtomicBool = AtomicBool::new(false);

pub(crate) fn current_panel_placement() -> PanelPlacement {
    PANEL_PLACEMENT.read().map(|guard| *guard).unwrap_or_default()
}

pub(crate) fn remember_panel_placement(placement: PanelPlacement) {
    if let Ok(mut guard) = PANEL_PLACEMENT.write() {
        *guard = placement;
    }
}

pub(crate) fn store_panel_placement(placement: PanelPlacement) -> Result<(), String> {
    remember_panel_placement(placement);
    match panel_placement_path() {
        Some(path) => write_panel_placement(&path, placement),
        None => Ok(()),
    }
}

pub(crate) fn read_panel_placement(path: &std::path::Path) -> PanelPlacement {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

pub(crate) fn write_panel_placement(path: &std::path::Path, placement: PanelPlacement) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("无法保存面板位置：{error}"))?;
    }
    let body = serde_json::to_string(&placement).map_err(|error| error.to_string())?;
    std::fs::write(path, body).map_err(|error| format!("无法保存面板位置：{error}"))
}

#[cfg(test)]
pub(crate) fn panel_placement_path() -> Option<std::path::PathBuf> {
    None
}

#[cfg(not(test))]
pub(crate) fn panel_placement_path() -> Option<std::path::PathBuf> {
    Some(app_state_dir()?.join("panel-placement.json"))
}

pub(crate) fn load_panel_placement() {
    if let Some(path) = panel_placement_path() {
        remember_panel_placement(read_panel_placement(&path));
    }
}

#[cfg(all(windows, not(test)))]
fn autohide_taskbar_edge_and_thickness(monitor: Rect) -> Option<(TaskbarEdge, i32)> {
    use windows_sys::Win32::Foundation::{HWND, RECT};
    use windows_sys::Win32::UI::Shell::{
        SHAppBarMessage, ABE_BOTTOM, ABE_LEFT, ABE_RIGHT, ABE_TOP, ABM_GETSTATE,
        ABM_GETTASKBARPOS, ABS_AUTOHIDE, APPBARDATA,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        FindWindowExW, FindWindowW, GetWindowRect, IsWindowVisible,
    };

    let primary_class: Vec<u16> = "Shell_TrayWnd\0".encode_utf16().collect();
    let taskbar_hwnd = unsafe { FindWindowW(primary_class.as_ptr(), std::ptr::null()) };
    let mut abd: APPBARDATA = unsafe { std::mem::zeroed() };
    abd.cbSize = std::mem::size_of::<APPBARDATA>() as u32;
    abd.hWnd = taskbar_hwnd;

    let state = unsafe { SHAppBarMessage(ABM_GETSTATE, &mut abd) };
    if (state & (ABS_AUTOHIDE as usize)) == 0 {
        return None;
    }

    if unsafe { SHAppBarMessage(ABM_GETTASKBARPOS, &mut abd) } == 0 {
        return None;
    }

    let normalized_edge = match abd.uEdge {
        ABE_LEFT => 0,
        ABE_TOP => 1,
        ABE_RIGHT => 2,
        ABE_BOTTOM => 3,
        _ => return None,
    };
    let (primary_edge, _) = taskbar_edge_from_appbar(
        normalized_edge,
        abd.rc.left,
        abd.rc.top,
        abd.rc.right,
        abd.rc.bottom,
    )?;
    let primary_rect = Rect::new(
        abd.rc.left,
        abd.rc.top,
        abd.rc.right.saturating_sub(abd.rc.left),
        abd.rc.bottom.saturating_sub(abd.rc.top),
    );

    let mut secondary_rects = Vec::new();
    let secondary_class: Vec<u16> = "Shell_SecondaryTrayWnd\0".encode_utf16().collect();
    let mut sec_hwnd: HWND = std::ptr::null_mut();
    for _ in 0..32 {
        sec_hwnd = unsafe {
            FindWindowExW(
                std::ptr::null_mut(),
                sec_hwnd,
                secondary_class.as_ptr(),
                std::ptr::null(),
            )
        };
        if sec_hwnd.is_null() {
            break;
        }
        if unsafe { IsWindowVisible(sec_hwnd) } == 0 {
            continue;
        }
        let mut rc: RECT = unsafe { std::mem::zeroed() };
        if unsafe { GetWindowRect(sec_hwnd, &mut rc) } != 0 {
            secondary_rects.push(Rect::new(
                rc.left,
                rc.top,
                rc.right.saturating_sub(rc.left),
                rc.bottom.saturating_sub(rc.top),
            ));
        }
    }

    autohide_taskbar_on_monitor(monitor, primary_edge, primary_rect, &secondary_rects)
}

#[cfg(any(not(windows), test))]
fn autohide_taskbar_edge_and_thickness(_monitor: Rect) -> Option<(TaskbarEdge, i32)> {
    None
}

/// Full monitor bounds plus the work area that excludes docked (or auto-hidden) taskbars. A
/// runtime that cannot report a work area falls back to the full bounds, which behaves like a
/// taskbar-free monitor.
pub(crate) fn monitor_rects(monitor: &Monitor) -> (Rect, Rect) {
    let position = monitor.position();
    let size = monitor.size();
    let full = Rect::new(position.x, position.y, size.width as i32, size.height as i32);
    let area = monitor.work_area();
    let raw_work = Rect::new(
        area.position.x,
        area.position.y,
        area.size.width as i32,
        area.size.height as i32,
    );
    let base_work = if raw_work.width <= 0 || raw_work.height <= 0 {
        full
    } else {
        raw_work
    };
    let work = match autohide_taskbar_edge_and_thickness(full) {
        Some((edge, thickness)) => {
            inset_work_area_for_autohide_taskbar(full, base_work, edge, thickness)
        }
        None => base_work,
    };
    (full, work)
}

pub(crate) fn main_column_inset(scale: f64) -> i32 {
    (PANEL_PADDING * scale).round() as i32
}

pub(crate) fn current_flyout_edge(
    window: &WebviewWindow,
    anchor: Option<PhysicalPosition<f64>>,
) -> &'static str {
    let monitor = anchor
        .and_then(|pos| window.monitor_from_point(pos.x, pos.y).ok().flatten())
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());
    let (full, work) = monitor
        .as_ref()
        .map(monitor_rects)
        .unwrap_or((Rect::new(0, 0, 1920, 1080), Rect::new(0, 0, 1920, 1080)));
    flyout_edge_name(taskbar_edge(full, work), current_panel_placement().anchor)
}

/// Resizes the two-island Win11 flyout height while keeping the 380 px column anchored to its work-area corner.
#[tauri::command]
pub(crate) fn set_panel_height(app: AppHandle, height: f64) -> bool {
    remember_panel_logical_height(height);
    let Some(window) = app.get_webview_window("main") else { return false };
    let monitor = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten());
    let scale = sanitize_scale(monitor.as_ref().map(|m| m.scale_factor()).unwrap_or(1.0));
    let (full, work) = monitor
        .as_ref()
        .map(monitor_rects)
        .unwrap_or((Rect::new(0, 0, 1920, 1080), Rect::new(0, 0, 1920, 1080)));
    let margin = 0;
    // The work area already excludes the taskbar, whichever edge it is docked to (#204). `#app` reserves
    // `PANEL_PADDING` (16 px) around the islands so the visible border sits 16 px off the taskbar edge.
    let target_h = clamp_outer_panel_height(height, work.height as f64 / scale);
    let (new_w, new_h) = compute_target_physical_size(effective_panel_window_width(), target_h, work, margin, scale);
    let old_pos = window.outer_position().unwrap_or(PhysicalPosition::new(0, 0));
    let old_size = window.outer_size().unwrap_or(PhysicalSize::new(new_w as u32, new_h as u32));
    let work_left = work.x + margin;
    let work_right = work.right() - margin;
    let x = old_pos.x.clamp(work_left, (work_right - new_w).max(work_left));
    let corner = current_panel_placement().anchor.corner(taskbar_edge(full, work));
    let y = resized_top(work, margin, old_pos.y, old_size.height as i32, new_h, corner);
    suppress_move_snaps();
    set_window_bounds_sync(&window, x, y, new_w, new_h);
    false
}

#[tauri::command]
pub(crate) fn set_panel_geometry(app: AppHandle, theme: PanelTheme, height: f64) -> bool {
    set_active_panel_theme(theme);
    remember_panel_logical_height(height);
    let Some(window) = app.get_webview_window("main") else { return false };
    let monitor = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten());
    let scale = sanitize_scale(monitor.as_ref().map(|m| m.scale_factor()).unwrap_or(1.0));
    let (full, work) = monitor
        .as_ref()
        .map(monitor_rects)
        .unwrap_or((Rect::new(0, 0, 1920, 1080), Rect::new(0, 0, 1920, 1080)));
    let margin = 0;
    let target_h = clamp_outer_panel_height(height, work.height as f64 / scale);
    let (new_w, new_h) = compute_target_physical_size(
        theme.window_width_for_backdrop(crate::win_theme::current_supports_system_backdrop()),
        target_h,
        work,
        margin,
        scale,
    );
    let old_pos = window.outer_position().unwrap_or(PhysicalPosition::new(0, 0));
    let old_size = window.outer_size().unwrap_or(PhysicalSize::new(new_w as u32, new_h as u32));
    let work_left = work.x + margin;
    let work_right = work.right() - margin;
    let corner = current_panel_placement().anchor.corner(taskbar_edge(full, work));
    let x = resized_x(old_pos.x, old_size.width as i32, new_w, work_left, work_right, !corner.left);
    let y = resized_top(work, margin, old_pos.y, old_size.height as i32, new_h, corner);
    suppress_move_snaps();
    sync_main_window_chrome(&window, window.is_visible().unwrap_or(false));
    set_window_bounds_sync(&window, x, y, new_w, new_h);
    true
}

pub(crate) fn position_popover(
    window: &WebviewWindow,
    anchor: Option<PhysicalPosition<f64>>,
    tray_rect: Option<tauri::Rect>,
) -> &'static str {
    // A tray click knows which display hosts the icon; the other paths follow the window's monitor.
    let monitor = anchor
        .and_then(|pos| window.monitor_from_point(pos.x, pos.y).ok().flatten())
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());

    let logical_w = effective_panel_window_width();
    let requested_logical_h = desired_panel_logical_height();

    let Some(monitor) = monitor else {
        let win_w = logical_w.round() as i32;
        let win_h = if requested_logical_h > 0.0 {
            requested_logical_h.round() as i32
        } else {
            DEFAULT_PANEL_LOGICAL_HEIGHT as i32
        };
        if let Some(pos) = anchor {
            let x = (pos.x as i32 - win_w / 2).max(0);
            let y = (pos.y as i32 - win_h).max(0);
            suppress_move_snaps();
            set_window_bounds_sync(window, x, y, win_w, win_h);
        }
        return "bottom";
    };

    let (full, work) = monitor_rects(&monitor);
    let scale = sanitize_scale(monitor.scale_factor());
    let margin = 0;
    let preference = current_panel_placement().anchor;
    let edge = taskbar_edge(full, work);
    // Compute physical bounds from the remembered logical dimensions and the destination monitor's
    // scale factor instead of reading the stale `outer_size()` from a previous DPI display.
    let (win_w, win_h) = compute_target_physical_size(logical_w, requested_logical_h, work, margin, scale);
    let phys_tray_rect = tray_rect.map(|r| physical_rect_from_tauri(r, scale));
    let effective_anchor = tray_anchor_point(work, phys_tray_rect, physical_point(anchor), edge);
    let (x, y) = place(&PlacementInput {
        monitor: full,
        work,
        window: (win_w, win_h),
        margin,
        anchor: effective_anchor,
        preference,
        main_inset: effective_main_column_inset(scale),
        main_width: (active_panel_theme().main_width() * scale).round() as i32,
    });
    suppress_move_snaps();
    set_window_bounds_sync(window, x, y, win_w, win_h);
    flyout_edge_name(edge, preference)
}

/// Secondary clamp invoked on `WindowEvent::ScaleFactorChanged` so a cross-DPI transition never
/// leaves a visible panel clipped off-screen after `WM_DPICHANGED`.
pub(crate) fn reclamp_panel_for_scale_change(window: &WebviewWindow, new_scale: f64) {
    if USER_DRAG_ACTIVE.load(Ordering::SeqCst) {
        return;
    }
    if !window.is_visible().unwrap_or(false) {
        return;
    }
    let Some(monitor) = window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| window.primary_monitor().ok().flatten())
    else {
        return;
    };
    let (_, work) = monitor_rects(&monitor);
    let Ok(pos) = window.outer_position() else {
        return;
    };
    let Ok(size) = window.outer_size() else {
        return;
    };
    let Some((x, y, w, h)) = reclamped_bounds_for_scale(
        (pos.x, pos.y),
        (size.width as i32, size.height as i32),
        work,
        0,
        effective_panel_window_width(),
        desired_panel_logical_height(),
        new_scale,
    ) else {
        return;
    };
    suppress_move_snaps();
    set_window_bounds_sync(window, x, y, w, h);
}

/// Whether the primary mouse button is still held. A drag that pauses without emitting `Moved` events
/// is not finished, so the settle watcher must wait for the release (#204 review).
#[cfg(all(windows, not(test)))]
pub(crate) fn primary_button_down() -> bool {
    #[link(name = "user32")]
    extern "system" {
        fn GetAsyncKeyState(vkey: i32) -> i16;
        fn GetSystemMetrics(index: i32) -> i32;
    }
    // "Swap primary and secondary buttons" makes the header's logical-primary press arrive on the right
    // button, so ask which physical button is primary before sampling it.
    const SM_SWAPBUTTON: i32 = 23;
    let swapped = unsafe { GetSystemMetrics(SM_SWAPBUTTON) != 0 };
    key_state_is_down(unsafe { GetAsyncKeyState(primary_button_virtual_key(swapped)) })
}

#[cfg(any(not(windows), test))]
pub(crate) fn primary_button_down() -> bool {
    false
}

/// Ignore `Moved` events caused by our own placement calls; the window covers the IPC round trips.
/// A running drag keeps the window: arming here would swallow the movement the user is producing.
pub(crate) fn suppress_move_snaps() {
    let drag_active = USER_DRAG_ACTIVE.load(Ordering::SeqCst);
    if let Some(deadline) = move_suppression_deadline(drag_active, now_epoch_ms()) {
        PROGRAMMATIC_MOVE_UNTIL_MS.store(deadline, Ordering::SeqCst);
    }
}

/// Watches one native drag until the window is still **and** the pointer has been released, then ends
/// the session. Only a drag that actually moved the window snaps, so a plain header click changes
/// nothing.
pub(crate) fn schedule_drag_settle(app: AppHandle) {
    MOVE_SNAP_DEADLINE_MS.store(now_epoch_ms() + DRAG_SETTLE_MS, Ordering::SeqCst);
    if MOVE_SNAP_SCHEDULED.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        loop {
            let now = now_epoch_ms();
            let quiet_until = MOVE_SNAP_DEADLINE_MS.load(Ordering::SeqCst);
            // Only a released pointer finishes the drag; a pause while the button is still down is not
            // a drop, so keep the quiet window rolling instead of snapping an intermediate corner.
            let held = USER_DRAG_ACTIVE.load(Ordering::SeqCst) && primary_button_down();
            if drag_settle_finished(now, quiet_until, held) {
                break;
            }
            if now >= quiet_until {
                MOVE_SNAP_DEADLINE_MS.store(now + DRAG_SETTLE_MS, Ordering::SeqCst);
            }
            std::thread::sleep(Duration::from_millis(60));
        }
        let moved = USER_MOVES_SEEN.swap(false, Ordering::SeqCst);
        USER_DRAG_ACTIVE.store(false, Ordering::SeqCst);
        MOVE_SNAP_SCHEDULED.store(false, Ordering::SeqCst);
        if !moved {
            return;
        }
        if let Some(window) = app.get_webview_window("main") {
            snap_panel_to_work_area(&window);
        }
    });
}

/// A drag emits `Moved` on every mouse step; keep the session alive until the pointer is released.
pub(crate) fn note_user_move(app: &AppHandle) {
    let drag_active = USER_DRAG_ACTIVE.load(Ordering::SeqCst);
    let suppressed_until = PROGRAMMATIC_MOVE_UNTIL_MS.load(Ordering::SeqCst);
    if !move_is_user_driven(drag_active, now_epoch_ms(), suppressed_until) {
        return;
    }
    USER_MOVES_SEEN.store(true, Ordering::SeqCst);
    schedule_drag_settle(app.clone());
}

/// Drag-to-move lands on the nearest work-area corner, and that corner becomes the preference.
pub(crate) fn snap_panel_to_work_area(window: &WebviewWindow) {
    let Ok(position) = window.outer_position() else { return };
    let size = window.outer_size().unwrap_or(PhysicalSize::new(472, 680));
    let cur_w = size.width as i32;
    let cur_h = size.height as i32;
    let center = (position.x + cur_w / 2, position.y + cur_h / 2);
    let Some(monitor) = window
        .monitor_from_point(center.0 as f64, center.1 as f64)
        .ok()
        .flatten()
        .or_else(|| window.current_monitor().ok().flatten())
    else {
        return;
    };
    let (full, work) = monitor_rects(&monitor);
    let scale = sanitize_scale(monitor.scale_factor());
    let margin = 0;
    // Compute destination physical bounds at the target monitor's scale so dragging across mixed-DPI
    // monitors fits cleanly on the drop display.
    let (win_w, fitted_h) = compute_target_physical_size(
        effective_panel_window_width(),
        desired_panel_logical_height(),
        work,
        margin,
        scale,
    );
    // Judge the drop by where the fitted panel lands, not by the oversized source rect.
    let dropped_center = (position.x + win_w / 2, position.y + fitted_h / 2);
    let anchor = PanelAnchor::nearest(work, dropped_center);
    // A drop inside the current quadrant still snaps the window back to its corner; only a different
    // corner needs a write, so an unchanged preference never rewrites the file (#204 review).
    if anchor != current_panel_placement().anchor {
        let _ = store_panel_placement(PanelPlacement { anchor });
    }
    let (x, y) = place(&PlacementInput {
        monitor: full,
        work,
        window: (win_w, fitted_h),
        margin,
        anchor: None,
        preference: anchor,
        main_inset: effective_main_column_inset(scale),
        main_width: (active_panel_theme().main_width() * scale).round() as i32,
    });
    suppress_move_snaps();
    set_window_bounds_sync(window, x, y, win_w, fitted_h);
}

fn present_panel_immediately_on_main_thread(
    app: &AppHandle,
    anchor: Option<PhysicalPosition<f64>>,
    tray_rect: Option<tauri::Rect>,
    after_present_script: Option<&'static str>,
) {
    crate::webview_lifecycle::restore_panel_normal_memory(app);
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let seq = PANEL_VISIBILITY
        .lock()
        .map(|mut state| state.begin_present())
        .unwrap_or(1);
    let was_visible = window.is_visible().unwrap_or(false);
    if !was_visible {
        set_window_cloaked(&window, true);
    }
    let edge = position_popover(&window, anchor, tray_rect);
    apply_tool_window_style(&window);
    sync_main_window_chrome(&window, true);
    let script = format!(
        "window.dispatchEvent(new CustomEvent('menumijia:panel-present', {{ detail: {{ seq: {seq}, edge: '{edge}' }} }}))"
    );
    let _ = window.eval(&script);
    if !was_visible {
        let _ = window.show();
    }
    set_window_cloaked(&window, false);
    if !window.is_focused().unwrap_or(false) {
        let _ = window.set_focus();
    }
    if let Some(after_script) = after_present_script {
        let _ = window.eval(after_script);
    }
}

fn present_panel_for_user_on_main_thread(
    app: &AppHandle,
    anchor: Option<PhysicalPosition<f64>>,
    tray_rect: Option<tauri::Rect>,
    after_present_script: Option<&'static str>,
) {
    crate::webview_lifecycle::restore_panel_normal_memory(app);
    let payload = crate::webview_lifecycle::PendingPanelPresent {
        anchor,
        tray_rect,
        after_present_script,
    };
    if let Some(ready_payload) = crate::webview_lifecycle::gate_or_present_panel(app, payload) {
        present_panel_immediately_on_main_thread(
            app,
            ready_payload.anchor,
            ready_payload.tray_rect,
            ready_payload.after_present_script,
        );
    }
}

pub(crate) fn finish_deferred_panel_present(
    app: &AppHandle,
    pending: crate::webview_lifecycle::PendingPanelPresent,
) {
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        present_panel_immediately_on_main_thread(
            &app_clone,
            pending.anchor,
            pending.tray_rect,
            pending.after_present_script,
        );
    });
}

pub(crate) fn present_panel_for_user(app: &AppHandle, anchor: Option<PhysicalPosition<f64>>) {
    present_panel_for_user_and_eval(app, anchor, None);
}

pub(crate) fn present_panel_for_user_and_eval(
    app: &AppHandle,
    anchor: Option<PhysicalPosition<f64>>,
    after_present_script: Option<&'static str>,
) {
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        present_panel_for_user_on_main_thread(&app_clone, anchor, None, after_present_script);
    });
}

pub(crate) fn toggle_main_window(
    app: &AppHandle,
    anchor: Option<PhysicalPosition<f64>>,
    tray_rect: Option<tauri::Rect>,
    from_tray_click: bool,
) {
    let cursor = physical_point(anchor);
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        let Some(window) = app_clone.get_webview_window("main") else {
            return;
        };
        let is_visible = window.is_visible().unwrap_or(false);
        let scale = monitor_scale_at(&window, anchor);
        let phys_rect = tray_rect.map(|r| physical_rect_from_tauri(r, scale));
        let action = if let Ok(mut state) = PANEL_VISIBILITY.lock() {
            let is_open = is_visible && !state.closing;
            if from_tray_click {
                state.decide_tray_release(is_open, now_epoch_ms(), cursor, phys_rect, scale)
            } else {
                state.clear_tray_press();
                if is_open {
                    TrayToggleAction::Hide
                } else {
                    TrayToggleAction::Present
                }
            }
        } else if is_visible {
            TrayToggleAction::Hide
        } else {
            TrayToggleAction::Present
        };
        match action {
            TrayToggleAction::Hide => request_hide_panel_on_main_thread(&app_clone),
            TrayToggleAction::Present => {
                present_panel_for_user_on_main_thread(&app_clone, anchor, tray_rect, None)
            }
            TrayToggleAction::Noop => {}
        }
    });
}

pub(crate) fn sanitize_settings_tab(raw: Option<&str>) -> &'static str {
    match raw.map(str::trim) {
        Some("connection") => "connection",
        Some("assistant") => "assistant",
        Some("safety") | Some("system") => "safety",
        Some("about") => "about",
        _ => "general",
    }
}

pub(crate) fn sanitize_settings_anchor(raw: Option<&str>) -> Option<&str> {
    let trimmed = raw?.trim();
    if trimmed.is_empty()
        || trimmed.len() > 64
        || !trimmed.bytes().all(|b| b.is_ascii_alphanumeric())
    {
        return None;
    }
    Some(trimmed)
}

#[cfg(all(windows, not(test)))]
fn apply_dark_titlebar(window: &WebviewWindow, dark: bool) {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::Graphics::Dwm::{
        DwmSetWindowAttribute, DWMWA_USE_IMMERSIVE_DARK_MODE,
    };

    let Ok(raw_hwnd) = window.hwnd() else {
        return;
    };
    let hwnd = (raw_hwnd.0 as usize) as HWND;
    let enabled: i32 = if dark { 1 } else { 0 };
    unsafe {
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE as u32,
            &enabled as *const i32 as *const core::ffi::c_void,
            std::mem::size_of::<i32>() as u32,
        );
    }
}

#[cfg(any(not(windows), test))]
fn apply_dark_titlebar(_window: &WebviewWindow, _dark: bool) {}

#[tauri::command]
pub(crate) async fn open_settings_window(
    app: AppHandle,
    tab: Option<String>,
    anchor: Option<String>,
) -> Result<bool, String> {
    let sanitized = sanitize_settings_tab(tab.as_deref());
    let sanitized_anchor = sanitize_settings_anchor(anchor.as_deref());
    let has_explicit_tab = tab.as_deref().is_some_and(|raw| !raw.trim().is_empty());
    let anchor_js = match sanitized_anchor {
        Some(a) => format!("'{a}'"),
        None => "null".to_string(),
    };
    request_hide_panel(&app);
    if let Some(window) = app.get_webview_window("settings") {
        crate::webview_lifecycle::settings_mark_open();
        sync_settings_window_chrome(&window);
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        if has_explicit_tab || sanitized_anchor.is_some() {
            let tab_js = if has_explicit_tab {
                format!("'{sanitized}'")
            } else {
                "null".to_string()
            };
            let script = format!(
                "window.dispatchEvent(new CustomEvent('menumijia:select-settings-tab', {{ detail: {{ tab: {tab_js}, anchor: {anchor_js} }} }}))"
            );
            let _ = window.eval(&script);
        }
        return Ok(true);
    }
    let tab_init = if has_explicit_tab || sanitized_anchor.is_none() {
        format!("'{sanitized}'")
    } else {
        "null".to_string()
    };
    let init_script = format!(
        "window.__MENUMIJIA_WINDOW_MODE__ = 'settings'; window.__MENUMIJIA_SETTINGS_TAB__ = {tab_init}; window.__MENUMIJIA_SETTINGS_ANCHOR__ = {anchor_js};"
    );
    SETTINGS_ALLOW_CLOSE.store(false, Ordering::SeqCst);
    let supports_backdrop = crate::win_theme::current_supports_system_backdrop();
    let settings_win = tauri::WebviewWindowBuilder::new(
        &app,
        "settings",
        tauri::WebviewUrl::App(std::path::PathBuf::from("index.html")),
    )
    .title("MenuBarHome 设置")
    .inner_size(780.0, 620.0)
    .min_inner_size(680.0, 520.0)
    .resizable(true)
    .decorations(true)
    .transparent(supports_backdrop)
    .scroll_bar_style(tauri::webview::ScrollBarStyle::FluentOverlay)
    .always_on_top(false)
    .skip_taskbar(false)
    .center()
    .initialization_script(&init_script)
    .build()
    .map_err(|err| format!("无法打开设置窗口：{err}"))?;
    sync_settings_window_chrome(&settings_win);
    crate::webview_lifecycle::settings_mark_open();
    let win_for_events = settings_win.clone();
    settings_win.on_window_event(move |event| match event {
        WindowEvent::ThemeChanged(_) => {
            sync_settings_window_chrome(&win_for_events);
        }
        WindowEvent::CloseRequested { api, .. } => {
            if consume_settings_allow_close(&SETTINGS_ALLOW_CLOSE) {
                return;
            }
            api.prevent_close();
            if win_for_events
                .eval("window.dispatchEvent(new CustomEvent('menumijia:request-close-settings'))")
                .is_err()
            {
                let _ = win_for_events.destroy();
            }
        }
        WindowEvent::Destroyed => {
            SETTINGS_ALLOW_CLOSE.store(false, Ordering::SeqCst);
            crate::webview_lifecycle::settings_mark_destroyed();
        }
        _ => {}
    });
    Ok(true)
}

#[tauri::command]
pub(crate) fn close_settings_window(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("settings") {
        crate::webview_lifecycle::hide_settings_window_idle(&app, &window)?;
    }
    Ok(())
}

#[tauri::command]
pub(crate) fn notify_settings_changed(app: AppHandle, source_label: Option<String>) -> Result<(), String> {
    let target = if source_label.as_deref() == Some("settings") {
        "main"
    } else {
        "settings"
    };
    if let Some(window) = app.get_webview_window(target) {
        let _ = window.eval("window.dispatchEvent(new CustomEvent('menumijia:settings-sync'))");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panel_window_geometry_preserves_outer_heights_and_work_area_clamp() {
        assert_eq!(PanelTheme::default(), PanelTheme::Classic);
        assert_eq!(panel_window_width(), 472.0);
        set_active_panel_theme(PanelTheme::Fluent);
        assert_eq!(panel_window_width(), 412.0);
        assert_eq!(PanelTheme::Fluent.main_width(), 380.0);
        assert_eq!(PanelTheme::Fluent.window_width(), 412.0);
        assert_eq!(PanelTheme::Classic.main_width(), 440.0);
        assert_eq!(PanelTheme::Classic.window_width(), 472.0);
        assert_eq!(PanelTheme::Classic.window_width_for_backdrop(true), 440.0);
        assert_eq!(PanelTheme::Classic.window_width_for_backdrop(false), 472.0);
        assert_eq!(PanelTheme::Fluent.window_width_for_backdrop(true), 412.0);
        assert_eq!(PanelTheme::Fluent.window_width_for_backdrop(false), 412.0);
        set_active_panel_theme(PanelTheme::Classic);
        assert_eq!(panel_window_width(), 472.0);
        assert_eq!(
            serde_json::from_str::<PanelTheme>(r#""classic""#).unwrap(),
            PanelTheme::Classic
        );
        assert_eq!(
            serde_json::from_str::<PanelTheme>(r#""fluent""#).unwrap(),
            PanelTheme::Fluent
        );
        assert_eq!(clamp_outer_panel_height(680.0, 1040.0), 680.0);
        assert_eq!(clamp_outer_panel_height(580.0, 1040.0), 580.0);
        assert_eq!(clamp_outer_panel_height(780.0, 720.0), 720.0);
        assert_eq!(clamp_outer_panel_height(0.0, 1040.0), 1040.0);
        assert_eq!(clamp_outer_panel_height(680.0, 400.0), 480.0);
        assert_eq!(clamp_outer_panel_height(0.0, 400.0), 480.0);
        assert_eq!(main_column_inset(1.0), 16);
        assert_eq!(main_column_inset(1.5), 24);
    }

    #[test]
    fn settings_tab_slug_sanitizes_legacy_and_unknown_values() {
        assert_eq!(sanitize_settings_tab(None), "general");
        assert_eq!(sanitize_settings_tab(Some("")), "general");
        assert_eq!(sanitize_settings_tab(Some("general")), "general");
        assert_eq!(sanitize_settings_tab(Some("connection")), "connection");
        assert_eq!(sanitize_settings_tab(Some("assistant")), "assistant");
        assert_eq!(sanitize_settings_tab(Some("safety")), "safety");
        assert_eq!(sanitize_settings_tab(Some("system")), "safety");
        assert_eq!(sanitize_settings_tab(Some("about")), "about");
        assert_eq!(sanitize_settings_tab(Some("foo'; alert(1)//")), "general");
    }

    #[test]
    fn settings_anchor_slug_sanitizes_empty_and_unsafe_values() {
        assert_eq!(sanitize_settings_anchor(None), None);
        assert_eq!(sanitize_settings_anchor(Some("")), None);
        assert_eq!(sanitize_settings_anchor(Some("   ")), None);
        assert_eq!(
            sanitize_settings_anchor(Some("miCloudRegion")),
            Some("miCloudRegion")
        );
        assert_eq!(
            sanitize_settings_anchor(Some(" miAccount ")),
            Some("miAccount")
        );
        assert_eq!(sanitize_settings_anchor(Some("foo'; alert(1)//")), None);
        assert_eq!(sanitize_settings_anchor(Some(&"a".repeat(65))), None);
    }

    #[test]
    fn settings_allow_close_flag_consumes_once() {
        let flag = AtomicBool::new(false);
        assert!(!consume_settings_allow_close(&flag));
        flag.store(true, Ordering::SeqCst);
        assert!(consume_settings_allow_close(&flag));
        assert!(!consume_settings_allow_close(&flag));
    }

    #[test]
    fn mixed_dpi_target_size_and_scale_reclamp_stay_inside_work_area() {
        // 100% 1080p display -> 150% 1440p display: physical size scales cleanly from logical dims.
        let work_150 = Rect::new(1920, 0, 2560, 1368);
        assert_eq!(
            compute_target_physical_size(472.0, 680.0, work_150, 0, 1.5),
            (708, 1020)
        );
        // Short 150% laptop screen (1920x1080 -> 1008px work height) clamps height to work area.
        let short_150 = Rect::new(0, 0, 1920, 1008);
        assert_eq!(
            compute_target_physical_size(472.0, 740.0, short_150, 0, 1.5),
            (708, 1008)
        );
        // Invalid scale falls back safely to 1.0.
        assert_eq!(
            compute_target_physical_size(472.0, 680.0, Rect::new(0, 0, 1920, 1032), 0, 0.0),
            (472, 680)
        );

        // ScaleFactorChanged secondary clamp pulls a clipped right/bottom edge back inside `work`
        // and is idempotent once already clamped.
        let clipped = reclamped_bounds_for_scale(
            (1920 + 2560 - 472, 1368 - 680),
            (472, 680),
            work_150,
            0,
            472.0,
            680.0,
            1.5,
        );
        assert_eq!(clipped, Some((1920 + 2560 - 708, 1368 - 1020, 708, 1020)));
        assert_eq!(
            reclamped_bounds_for_scale(
                (1920 + 2560 - 708, 1368 - 1020),
                (708, 1020),
                work_150,
                0,
                472.0,
                680.0,
                1.5,
            ),
            None
        );
    }

    #[test]
    fn tool_window_ex_style_adds_toolwindow_and_strips_appwindow() {
        let initial = WIN32_WS_EX_APPWINDOW | 0x0000_0008; // WS_EX_TOPMOST
        let updated = tool_window_ex_style(initial);
        assert_ne!(updated & WIN32_WS_EX_TOOLWINDOW, 0);
        assert_eq!(updated & WIN32_WS_EX_APPWINDOW, 0);
        assert_ne!(updated & 0x0000_0008, 0);
        // Idempotent when applied again.
        assert_eq!(tool_window_ex_style(updated), updated);
    }

    #[test]
    fn tray_rect_hit_test_scales_padding_on_high_dpi_displays() {
        // 4K 200% DPI tray icon: 64x64 physical px, padded by 8 * 2.0 = 16 px on each side.
        let icon_rect = Rect::new(3520, 2080, 64, 64);
        let mut state = PanelVisibilityState::default();
        let _ = state.begin_present();
        // Focus loss at the far corner of the icon + 12px jitter (44px from opposite edge, which
        // would have exceeded the old unscaled 36px slop from cursor center).
        state.note_focus_loss(1_000, Some((3520 - 12, 2080 - 12)));
        let _ = state.begin_hide(true);
        state.note_tray_press_down(false, 1_040, Some((3578, 2138)), Some(icon_rect), 2.0);
        assert_eq!(
            state.decide_tray_release(false, 1_090, Some((3578, 2138)), Some(icon_rect), 2.0),
            TrayToggleAction::Noop
        );

        // Click well outside the padded rect still reopens the panel.
        let _ = state.begin_present();
        state.note_focus_loss(2_000, Some((3480, 2080)));
        let _ = state.begin_hide(true);
        state.note_tray_press_down(false, 2_040, Some((3552, 2112)), Some(icon_rect), 2.0);
        assert_eq!(
            state.decide_tray_release(false, 2_090, Some((3552, 2112)), Some(icon_rect), 2.0),
            TrayToggleAction::Present
        );
    }
}
