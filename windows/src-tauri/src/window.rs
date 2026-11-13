use super::*;
use crate::placement::*;

const FOCUS_LOSS_TRAY_GRACE_MS: u64 = 280;

pub(crate) static PIN_POPOVER: AtomicBool = AtomicBool::new(false);
/// Whether the window manager granted the panel a native backdrop (§1.4 of the control center spec).
static PANEL_BACKDROP_ACRYLIC: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TrayToggleAction {
    Present,
    Hide,
    Noop,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct PanelVisibilityState {
    pub(crate) seq: u64,
    pub(crate) closing: bool,
    pub(crate) focus_loss_ms: Option<u64>,
    pub(crate) dismissed_by_tray_press: bool,
}

impl PanelVisibilityState {
    pub(crate) fn begin_present(&mut self) -> u64 {
        self.seq = self.seq.wrapping_add(1);
        self.closing = false;
        self.focus_loss_ms = None;
        self.dismissed_by_tray_press = false;
        self.seq
    }

    pub(crate) fn begin_hide(&mut self, is_visible: bool) -> Option<u64> {
        if !is_visible {
            self.closing = false;
            return None;
        }
        if self.closing {
            return None;
        }
        self.closing = true;
        self.seq = self.seq.wrapping_add(1);
        Some(self.seq)
    }

    pub(crate) fn complete_hide(&mut self, requested_seq: u64) -> bool {
        if !should_complete_hide(self.closing, self.seq, requested_seq) {
            return false;
        }
        self.closing = false;
        true
    }

    pub(crate) fn abort_hide(&mut self) {
        self.closing = false;
    }

    pub(crate) fn note_focus_loss(&mut self, now_ms: u64) {
        self.focus_loss_ms = Some(now_ms);
    }

    pub(crate) fn note_tray_press_down(&mut self, is_open: bool, now_ms: u64) {
        let recent_focus_loss = self
            .focus_loss_ms
            .take()
            .is_some_and(|ms| now_ms.saturating_sub(ms) < FOCUS_LOSS_TRAY_GRACE_MS);
        self.dismissed_by_tray_press = is_open || recent_focus_loss;
    }

    pub(crate) fn decide_tray_release(&mut self, is_open: bool, now_ms: u64) -> TrayToggleAction {
        let was_dismiss_press = std::mem::replace(&mut self.dismissed_by_tray_press, false);
        let recent_focus_loss = self
            .focus_loss_ms
            .take()
            .is_some_and(|ms| now_ms.saturating_sub(ms) < FOCUS_LOSS_TRAY_GRACE_MS);
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

/// Total logical window width around the fixed 380 px two-island column plus shadow padding on both sides.
pub(crate) fn panel_window_width() -> f64 {
    PANEL_MAIN_WIDTH + PANEL_PADDING * 2.0
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

/// Applies the native backdrop policy (see `backdrop.rs`) and records it for the webview.
pub(crate) fn apply_panel_backdrop(window: &WebviewWindow) {
    PANEL_BACKDROP_ACRYLIC.store(crate::backdrop::apply(window), Ordering::SeqCst);
}

/// What the window manager granted, so the stylesheet can lower its own fill to a tint.
#[tauri::command]
pub(crate) fn panel_backdrop() -> &'static str {
    if PANEL_BACKDROP_ACRYLIC.load(Ordering::SeqCst) {
        "acrylic"
    } else {
        "none"
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

pub(crate) fn note_panel_focus_loss() {
    if let Ok(mut state) = PANEL_VISIBILITY.lock() {
        state.note_focus_loss(now_epoch_ms());
    }
}

pub(crate) fn handle_tray_mouse_down(app: &AppHandle) {
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        let is_visible = app_clone
            .get_webview_window("main")
            .and_then(|window| window.is_visible().ok())
            .unwrap_or(false);
        if let Ok(mut state) = PANEL_VISIBILITY.lock() {
            let is_open = is_visible && !state.closing;
            state.note_tray_press_down(is_open, now_epoch_ms());
        }
    });
}

fn complete_hide_panel_on_main_thread(app: &AppHandle, seq: u64) {
    let should_hide = PANEL_VISIBILITY
        .lock()
        .map(|mut state| state.complete_hide(seq))
        .unwrap_or(false);
    if !should_hide {
        return;
    }
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.hide();
    }
}

fn request_hide_panel_on_main_thread(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let is_visible = window.is_visible().unwrap_or(false);
    let Some(seq) = PANEL_VISIBILITY
        .lock()
        .ok()
        .and_then(|mut state| state.begin_hide(is_visible))
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
        let _ = window.hide();
        return;
    }
    let app_clone = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(200));
        complete_hide_panel(&app_clone, seq);
    });
}

pub(crate) fn complete_hide_panel(app: &AppHandle, seq: u64) {
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        complete_hide_panel_on_main_thread(&app_clone, seq);
    });
}

pub(crate) fn request_hide_panel(app: &AppHandle) {
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        request_hide_panel_on_main_thread(&app_clone);
    });
}

#[tauri::command]
pub(crate) fn hide_panel(app: AppHandle) {
    request_hide_panel(&app);
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
            let _ = position_popover(&window, None);
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

/// Full monitor bounds plus the work area that excludes docked taskbars. A runtime that cannot report
/// a work area falls back to the full bounds, which behaves like a taskbar-free monitor.
pub(crate) fn monitor_rects(monitor: &Monitor) -> (Rect, Rect) {
    let position = monitor.position();
    let size = monitor.size();
    let full = Rect::new(position.x, position.y, size.width as i32, size.height as i32);
    let area = monitor.work_area();
    let work = Rect::new(
        area.position.x,
        area.position.y,
        area.size.width as i32,
        area.size.height as i32,
    );
    if work.width <= 0 || work.height <= 0 {
        (full, full)
    } else {
        (full, work)
    }
}

/// Left offset of the 380 px island column inside the window (`PANEL_PADDING` = 16 px at 1x).
pub(crate) fn main_column_offset(window_width: i32, scale: f64) -> i32 {
    let main = (PANEL_MAIN_WIDTH * scale).round() as i32;
    let padding = (PANEL_PADDING * scale).round() as i32;
    (window_width - main - padding).max(0)
}

pub(crate) fn main_column_inset(window_width: i32, scale: f64) -> i32 {
    main_column_offset(window_width, scale)
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
    let Some(window) = app.get_webview_window("main") else { return false };
    let monitor = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten());
    let scale = monitor.as_ref().map(|m| m.scale_factor()).unwrap_or(1.0);
    let (full, work) = monitor
        .as_ref()
        .map(monitor_rects)
        .unwrap_or((Rect::new(0, 0, 1920, 1080), Rect::new(0, 0, 1920, 1080)));
    let margin = 0;
    // The work area already excludes the taskbar, whichever edge it is docked to (#204). `#app` reserves
    // `PANEL_PADDING` (16 px) around the islands so the visible border sits 16 px off the taskbar edge.
    let max_h = (work.height as f64 / scale).max(480.0);
    let target_h = if height <= 0.0 { max_h } else { (height + PANEL_PADDING * 2.0).min(max_h) };
    let old_pos = window.outer_position().unwrap_or(PhysicalPosition::new(0, 0));
    let old_size = window.outer_size().unwrap_or(PhysicalSize::new(412, 680));
    let left = work.x as f64 + margin as f64;
    let right = work.right() as f64 - margin as f64;
    let target_w = panel_window_width().min((right - left) / scale);
    let x = (old_pos.x as f64).clamp(left, (right - target_w * scale).max(left));
    let new_h = (target_h * scale).round() as i32;
    let corner = current_panel_placement().anchor.corner(taskbar_edge(full, work));
    let y = resized_top(work, margin, old_pos.y, old_size.height as i32, new_h, corner);
    suppress_move_snaps();
    let _ = window.set_size(tauri::LogicalSize::new(target_w, target_h));
    let _ = window.set_position(PhysicalPosition::new(x.round() as i32, y));
    false
}

pub(crate) fn position_popover(window: &WebviewWindow, anchor: Option<PhysicalPosition<f64>>) -> &'static str {
    let win_size = window.outer_size().unwrap_or(PhysicalSize::new(412, 680));
    let win_w = win_size.width as i32;
    let win_h = win_size.height as i32;

    // A tray click knows which display hosts the icon; the other paths follow the window's monitor.
    let monitor = anchor
        .and_then(|pos| window.monitor_from_point(pos.x, pos.y).ok().flatten())
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());

    let Some(monitor) = monitor else {
        if let Some(pos) = anchor {
            let x = (pos.x as i32 - win_w / 2).max(0);
            let y = (pos.y as i32 - win_h).max(0);
            suppress_move_snaps();
            let _ = window.set_position(PhysicalPosition::new(x, y));
        }
        return "bottom";
    };

    let (full, work) = monitor_rects(&monitor);
    let scale = monitor.scale_factor();
    let margin = 0;
    let preference = current_panel_placement().anchor;
    let edge = taskbar_edge(full, work);
    // A panel sized for a larger display has to fit this monitor before it is placed (#204 review).
    let fitted_h = fit_panel_height(work, margin, win_h);
    let (x, y) = place(&PlacementInput {
        monitor: full,
        work,
        window: (win_w, fitted_h),
        margin,
        anchor: anchor.map(|pos| (pos.x.round() as i32, pos.y.round() as i32)),
        preference,
        main_inset: main_column_inset(win_w, scale),
        main_width: (PANEL_MAIN_WIDTH * scale).round() as i32,
    });
    suppress_move_snaps();
    if fitted_h != win_h {
        let _ = window.set_size(PhysicalSize::new(win_size.width, fitted_h as u32));
    }
    let _ = window.set_position(PhysicalPosition::new(x, y));
    flyout_edge_name(edge, preference)
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
    let size = window.outer_size().unwrap_or(PhysicalSize::new(412, 680));
    let win_w = size.width as i32;
    let win_h = size.height as i32;
    let center = (position.x + win_w / 2, position.y + win_h / 2);
    let Some(monitor) = window
        .monitor_from_point(center.0 as f64, center.1 as f64)
        .ok()
        .flatten()
        .or_else(|| window.current_monitor().ok().flatten())
    else {
        return;
    };
    let (full, work) = monitor_rects(&monitor);
    let scale = monitor.scale_factor();
    let margin = 0;
    // Fit the destination work area before placing: an over-tall panel would otherwise pin its top and
    // leave its bottom offscreen (#204 review).
    let fitted_h = fit_panel_height(work, margin, win_h);
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
        main_inset: main_column_inset(win_w, scale),
        main_width: (PANEL_MAIN_WIDTH * scale).round() as i32,
    });
    suppress_move_snaps();
    if fitted_h != win_h {
        let _ = window.set_size(PhysicalSize::new(size.width, fitted_h as u32));
    }
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

fn present_panel_on_main_thread(app: &AppHandle, anchor: Option<PhysicalPosition<f64>>) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let seq = PANEL_VISIBILITY
        .lock()
        .map(|mut state| state.begin_present())
        .unwrap_or(1);
    let edge = position_popover(&window, anchor);
    let script = format!(
        "window.dispatchEvent(new CustomEvent('menumijia:panel-present', {{ detail: {{ seq: {seq}, edge: '{edge}' }} }}))"
    );
    let _ = window.eval(&script);
    let _ = window.show();
    let _ = window.set_focus();
}

pub(crate) fn present_panel(app: &AppHandle, anchor: Option<PhysicalPosition<f64>>) {
    present_panel_and_eval(app, anchor, None);
}

pub(crate) fn present_panel_and_eval(
    app: &AppHandle,
    anchor: Option<PhysicalPosition<f64>>,
    after_present_script: Option<&'static str>,
) {
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        present_panel_on_main_thread(&app_clone, anchor);
        if let Some(script) = after_present_script {
            if let Some(window) = app_clone.get_webview_window("main") {
                let _ = window.eval(script);
            }
        }
    });
}

pub(crate) fn toggle_main_window(app: &AppHandle, anchor: Option<PhysicalPosition<f64>>, from_tray_click: bool) {
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        let Some(window) = app_clone.get_webview_window("main") else {
            return;
        };
        let is_visible = window.is_visible().unwrap_or(false);
        let action = if let Ok(mut state) = PANEL_VISIBILITY.lock() {
            let is_open = is_visible && !state.closing;
            if from_tray_click {
                state.decide_tray_release(is_open, now_epoch_ms())
            } else if is_open {
                TrayToggleAction::Hide
            } else {
                TrayToggleAction::Present
            }
        } else if is_visible {
            TrayToggleAction::Hide
        } else {
            TrayToggleAction::Present
        };
        match action {
            TrayToggleAction::Hide => request_hide_panel_on_main_thread(&app_clone),
            TrayToggleAction::Present => present_panel_on_main_thread(&app_clone, anchor),
            TrayToggleAction::Noop => {}
        }
    });
}
