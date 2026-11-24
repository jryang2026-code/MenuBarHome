use super::*;

pub(crate) const CAMERA_PIP_WINDOW_LABEL: &str = "camera-pip";
const PIP_DEFAULT_LANDSCAPE_W: f64 = 420.0;
const PIP_DEFAULT_LANDSCAPE_H: f64 = 324.0;
const PIP_MIN_LANDSCAPE_W: f64 = 280.0;
const PIP_MIN_LANDSCAPE_H: f64 = 220.0;

const PIP_DEFAULT_PORTRAIT_W: f64 = 300.0;
const PIP_DEFAULT_PORTRAIT_H: f64 = 472.0;
const PIP_MIN_PORTRAIT_W: f64 = 220.0;
const PIP_MIN_PORTRAIT_H: f64 = 320.0;

const PIP_MARGIN_LOGICAL_PX: f64 = 16.0;
const MAX_STORED_CAMERA_BOUNDS: usize = 64;
const PIP_PROGRAMMATIC_SUPPRESS_MS: u64 = 350;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CameraPipBounds {
    pub(crate) x: i32,
    pub(crate) y: i32,
    pub(crate) logical_width: f64,
    pub(crate) logical_height: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CameraPipBoundsStore {
    cameras: HashMap<String, CameraPipBounds>,
}

#[derive(Default)]
struct CameraPipRuntimeState {
    active_camera_id: Option<String>,
    active_is_portrait: bool,
    latest_state_json: Option<String>,
    bounds: HashMap<String, CameraPipBounds>,
}

static CAMERA_PIP_STATE: LazyLock<RwLock<CameraPipRuntimeState>> =
    LazyLock::new(|| RwLock::new(CameraPipRuntimeState::default()));
static PIP_PROGRAMMATIC_UNTIL_MS: AtomicU64 = AtomicU64::new(0);
static PIP_ALLOW_SILENT_CLOSE: AtomicBool = AtomicBool::new(false);

pub(crate) fn pip_default_logical_size(is_portrait: bool) -> (f64, f64) {
    if is_portrait {
        (PIP_DEFAULT_PORTRAIT_W, PIP_DEFAULT_PORTRAIT_H)
    } else {
        (PIP_DEFAULT_LANDSCAPE_W, PIP_DEFAULT_LANDSCAPE_H)
    }
}

pub(crate) fn pip_min_logical_size(is_portrait: bool) -> (f64, f64) {
    if is_portrait {
        (PIP_MIN_PORTRAIT_W, PIP_MIN_PORTRAIT_H)
    } else {
        (PIP_MIN_LANDSCAPE_W, PIP_MIN_LANDSCAPE_H)
    }
}

/// Computes the physical `(width, height)` for the PiP window on a destination monitor using
/// logical dimensions and that monitor's `scale_factor()`, clamping to the monitor work area.
pub(crate) fn compute_pip_physical_size(
    logical_w: f64,
    logical_h: f64,
    work: Rect,
    margin: i32,
    scale: f64,
    is_portrait: bool,
) -> (i32, i32) {
    let safe_scale = sanitize_scale(scale);
    let avail_w = (work.width - margin * 2).max(1);
    let avail_h = (work.height - margin * 2).max(1);
    let work_logical_w = (avail_w as f64) / safe_scale;
    let work_logical_h = (avail_h as f64) / safe_scale;
    let (default_w, default_h) = pip_default_logical_size(is_portrait);
    let (min_w, min_h) = pip_min_logical_size(is_portrait);
    let req_w = if logical_w.is_finite() && logical_w > 0.0 {
        logical_w
    } else {
        default_w
    };
    let req_h = if logical_h.is_finite() && logical_h > 0.0 {
        logical_h
    } else {
        default_h
    };
    let clamped_logical_w = req_w.max(min_w).min(work_logical_w).max(1.0);
    let clamped_logical_h = req_h.max(min_h).min(work_logical_h).max(1.0);
    let phys_w = ((clamped_logical_w * safe_scale).round() as i32).clamp(1, avail_w);
    let phys_h = ((clamped_logical_h * safe_scale).round() as i32).clamp(1, avail_h);
    (phys_w, phys_h)
}

/// Resolves physical `(x, y, width, height)` for a camera PiP window inside `work`.
/// When `force_top_right` is true or no saved bounds exist, docks to the top-right corner.
pub(crate) fn place_pip_bounds(
    saved: Option<CameraPipBounds>,
    work: Rect,
    scale: f64,
    is_portrait: bool,
    force_top_right: bool,
) -> (i32, i32, i32, i32) {
    let safe_scale = sanitize_scale(scale);
    let margin = (PIP_MARGIN_LOGICAL_PX * safe_scale).round() as i32;
    let (default_w, default_h) = pip_default_logical_size(is_portrait);
    let (req_w, req_h) = saved
        .map(|b| (b.logical_width, b.logical_height))
        .unwrap_or((default_w, default_h));
    let (phys_w, phys_h) =
        compute_pip_physical_size(req_w, req_h, work, margin, safe_scale, is_portrait);
    let min_x = work.x + margin;
    let min_y = work.y + margin;
    let max_x = (work.right() - margin - phys_w).max(min_x);
    let max_y = (work.bottom() - margin - phys_h).max(min_y);
    let (x, y) = match saved {
        Some(b) if !force_top_right => (b.x.clamp(min_x, max_x), b.y.clamp(min_y, max_y)),
        _ => (max_x, min_y),
    };
    (x, y, phys_w, phys_h)
}

/// Secondary clamp invoked on `WindowEvent::ScaleFactorChanged` so a mixed-DPI transition never
/// leaves the PiP window clipped off-screen. Returns `None` when already within bounds.
pub(crate) fn reclamped_pip_bounds_for_scale(
    current_pos: (i32, i32),
    current_size: (i32, i32),
    work: Rect,
    logical_w: f64,
    logical_h: f64,
    scale: f64,
    is_portrait: bool,
) -> Option<(i32, i32, i32, i32)> {
    let safe_scale = sanitize_scale(scale);
    let margin = (PIP_MARGIN_LOGICAL_PX * safe_scale).round() as i32;
    let (target_w, target_h) =
        compute_pip_physical_size(logical_w, logical_h, work, margin, safe_scale, is_portrait);
    let min_x = work.x + margin;
    let min_y = work.y + margin;
    let max_x = (work.right() - margin - target_w).max(min_x);
    let max_y = (work.bottom() - margin - target_h).max(min_y);
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

fn suppress_pip_bounds_capture() {
    PIP_PROGRAMMATIC_UNTIL_MS.store(
        now_epoch_ms().saturating_add(PIP_PROGRAMMATIC_SUPPRESS_MS),
        Ordering::SeqCst,
    );
}

#[cfg(test)]
fn pip_bounds_path() -> Option<std::path::PathBuf> {
    None
}

#[cfg(not(test))]
fn pip_bounds_path() -> Option<std::path::PathBuf> {
    Some(app_state_dir()?.join("camera-pip-bounds.json"))
}

pub(crate) fn read_pip_bounds_store(path: &std::path::Path) -> HashMap<String, CameraPipBounds> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    let Ok(store) = serde_json::from_str::<CameraPipBoundsStore>(&text) else {
        return HashMap::new();
    };
    store
        .cameras
        .into_iter()
        .filter(|(k, b)| {
            !k.trim().is_empty()
                && b.logical_width.is_finite()
                && b.logical_width > 0.0
                && b.logical_height.is_finite()
                && b.logical_height > 0.0
        })
        .take(MAX_STORED_CAMERA_BOUNDS)
        .collect()
}

pub(crate) fn write_pip_bounds_store(
    path: &std::path::Path,
    bounds: &HashMap<String, CameraPipBounds>,
) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("无法保存摄像机小窗位置：{error}"))?;
    }
    let trimmed: HashMap<String, CameraPipBounds> = bounds
        .iter()
        .take(MAX_STORED_CAMERA_BOUNDS)
        .map(|(k, v)| (k.clone(), *v))
        .collect();
    let body = serde_json::to_string(&CameraPipBoundsStore { cameras: trimmed })
        .map_err(|error| error.to_string())?;
    std::fs::write(path, body).map_err(|error| format!("无法保存摄像机小窗位置：{error}"))
}

pub(crate) fn load_camera_pip_bounds() {
    let Some(path) = pip_bounds_path() else {
        return;
    };
    let loaded = read_pip_bounds_store(&path);
    if let Ok(mut guard) = CAMERA_PIP_STATE.write() {
        guard.bounds = loaded;
    }
}

fn persist_camera_pip_bounds_snapshot() {
    let Some(path) = pip_bounds_path() else {
        return;
    };
    let snapshot = CAMERA_PIP_STATE
        .read()
        .ok()
        .map(|guard| guard.bounds.clone());
    if let Some(map) = snapshot {
        let _ = write_pip_bounds_store(&path, &map);
    }
}

fn capture_window_bounds_for_active_camera(window: &WebviewWindow, persist: bool) {
    let Ok(pos) = window.outer_position() else {
        return;
    };
    let Ok(size) = window.outer_size() else {
        return;
    };
    if size.width == 0 || size.height == 0 {
        return;
    }
    let scale = sanitize_scale(
        window
            .current_monitor()
            .ok()
            .flatten()
            .or_else(|| window.primary_monitor().ok().flatten())
            .map(|m| m.scale_factor())
            .unwrap_or(1.0),
    );
    let logical_width = (size.width as f64) / scale;
    let logical_height = (size.height as f64) / scale;
    if !logical_width.is_finite() || !logical_height.is_finite() {
        return;
    }
    let updated = if let Ok(mut guard) = CAMERA_PIP_STATE.write() {
        if let Some(camera_id) = guard.active_camera_id.clone() {
            guard.bounds.insert(
                camera_id,
                CameraPipBounds {
                    x: pos.x,
                    y: pos.y,
                    logical_width,
                    logical_height,
                },
            );
            true
        } else {
            false
        }
    } else {
        false
    };
    if updated && persist {
        persist_camera_pip_bounds_snapshot();
    }
}

fn reclamp_pip_for_scale_change(window: &WebviewWindow, new_scale: f64) {
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
    let (logical_w, logical_h, is_portrait) = CAMERA_PIP_STATE
        .read()
        .ok()
        .map(|guard| {
            let portrait = guard.active_is_portrait;
            let (def_w, def_h) = pip_default_logical_size(portrait);
            let dims = guard
                .active_camera_id
                .as_ref()
                .and_then(|id| guard.bounds.get(id))
                .map(|b| (b.logical_width, b.logical_height))
                .unwrap_or((def_w, def_h));
            (dims.0, dims.1, portrait)
        })
        .unwrap_or((PIP_DEFAULT_LANDSCAPE_W, PIP_DEFAULT_LANDSCAPE_H, false));
    let Some((x, y, w, h)) = reclamped_pip_bounds_for_scale(
        (pos.x, pos.y),
        (size.width as i32, size.height as i32),
        work,
        logical_w,
        logical_h,
        new_scale,
        is_portrait,
    ) else {
        return;
    };
    suppress_pip_bounds_capture();
    set_window_bounds_sync(window, x, y, w, h);
}

#[cfg(all(windows, not(test)))]
fn show_pip_window_no_activate(window: &WebviewWindow) {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::UI::WindowsAndMessaging::{ShowWindow, SW_SHOWNOACTIVATE};

    if let Ok(raw_hwnd) = window.hwnd() {
        let hwnd = (raw_hwnd.0 as usize) as HWND;
        unsafe {
            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        }
    } else {
        let _ = window.show();
    }
}

#[cfg(any(not(windows), test))]
fn show_pip_window_no_activate(window: &WebviewWindow) {
    let _ = window.show();
}

fn target_monitor_for_pip(
    window: &WebviewWindow,
    saved: Option<CameraPipBounds>,
    force_top_right: bool,
) -> Option<Monitor> {
    if !force_top_right {
        if let Some(b) = saved {
            if let Ok(Some(m)) = window.monitor_from_point(b.x as f64, b.y as f64) {
                return Some(m);
            }
        }
    }
    window
        .primary_monitor()
        .ok()
        .flatten()
        .or_else(|| window.current_monitor().ok().flatten())
}

fn notify_main_pip_closed(app: &AppHandle) {
    if let Some(main_win) = app.get_webview_window("main") {
        let _ = main_win.eval("window.dispatchEvent(new CustomEvent('menumijia:camera-pip-closed'))");
    }
}

fn position_pip_window(
    window: &WebviewWindow,
    saved: Option<CameraPipBounds>,
    is_portrait: bool,
    force_top_right: bool,
) {
    let monitor = target_monitor_for_pip(window, saved, force_top_right);
    let (_, work) = monitor
        .as_ref()
        .map(monitor_rects)
        .unwrap_or((Rect::new(0, 0, 1920, 1080), Rect::new(0, 0, 1920, 1080)));
    let scale = sanitize_scale(monitor.as_ref().map(|m| m.scale_factor()).unwrap_or(1.0));
    let (x, y, w, h) = place_pip_bounds(saved, work, scale, is_portrait, force_top_right);
    suppress_pip_bounds_capture();
    set_window_bounds_sync(window, x, y, w, h);
}

#[tauri::command]
pub(crate) async fn open_camera_pip_window(
    app: AppHandle,
    camera_id: String,
    title: Option<String>,
    is_portrait: Option<bool>,
    force_top_right: Option<bool>,
    steal_focus: Option<bool>,
) -> Result<bool, String> {
    let trimmed_id = camera_id.trim().to_string();
    if trimmed_id.is_empty() {
        return Err("摄像机 ID 不能为空".to_string());
    }
    let portrait = is_portrait.unwrap_or(false);
    let top_right = force_top_right.unwrap_or(false);
    let should_focus = steal_focus.unwrap_or(true);
    let window_title = title
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| format!("{s} · MenuBarHome"))
        .unwrap_or_else(|| "MenuBarHome 摄像机".to_string());

    if let Some(existing) = app.get_webview_window(CAMERA_PIP_WINDOW_LABEL) {
        let previous_id = CAMERA_PIP_STATE
            .read()
            .ok()
            .and_then(|g| g.active_camera_id.clone());
        if previous_id.as_deref() != Some(trimmed_id.as_str()) {
            capture_window_bounds_for_active_camera(&existing, true);
        }
        let saved = if let Ok(mut guard) = CAMERA_PIP_STATE.write() {
            guard.active_camera_id = Some(trimmed_id.clone());
            guard.active_is_portrait = portrait;
            guard.bounds.get(&trimmed_id).copied()
        } else {
            None
        };
        let (min_w, min_h) = pip_min_logical_size(portrait);
        let _ = existing.set_title(&window_title);
        let _ = existing.set_min_size(Some(tauri::LogicalSize::new(min_w, min_h)));
        let _ = existing.set_always_on_top(true);
        position_pip_window(&existing, saved, portrait, top_right);
        apply_tool_window_style(&existing);
        let _ = existing.unminimize();
        if should_focus {
            let _ = existing.show();
            let _ = existing.set_focus();
        } else {
            show_pip_window_no_activate(&existing);
        }
        set_window_cloaked(&existing, false);
        return Ok(true);
    }

    let saved = if let Ok(mut guard) = CAMERA_PIP_STATE.write() {
        guard.active_camera_id = Some(trimmed_id.clone());
        guard.active_is_portrait = portrait;
        guard.bounds.get(&trimmed_id).copied()
    } else {
        None
    };

    let (def_w, def_h) = pip_default_logical_size(portrait);
    let (min_w, min_h) = pip_min_logical_size(portrait);
    let init_w = saved.map(|b| b.logical_width).unwrap_or(def_w).max(min_w);
    let init_h = saved.map(|b| b.logical_height).unwrap_or(def_h).max(min_h);
    let init_script = "window.__MENUMIJIA_WINDOW_MODE__ = 'camera-pip';";

    PIP_ALLOW_SILENT_CLOSE.store(false, Ordering::SeqCst);
    let pip_win = tauri::WebviewWindowBuilder::new(
        &app,
        CAMERA_PIP_WINDOW_LABEL,
        tauri::WebviewUrl::App(std::path::PathBuf::from("index.html")),
    )
    .title(&window_title)
    .inner_size(init_w, init_h)
    .min_inner_size(min_w, min_h)
    .resizable(true)
    .decorations(false)
    .transparent(true)
    .shadow(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .focused(should_focus)
    .visible(false)
    .initialization_script(init_script)
    .build()
    .map_err(|err| format!("无法打开摄像机独立小窗：{err}"))?;

    set_window_cloaked(&pip_win, true);
    apply_tool_window_style(&pip_win);
    position_pip_window(&pip_win, saved, portrait, top_right);

    let win_for_events = pip_win.clone();
    let app_for_events = app.clone();
    pip_win.on_window_event(move |event| match event {
        WindowEvent::Moved(_) | WindowEvent::Resized(_) => {
            if now_epoch_ms() >= PIP_PROGRAMMATIC_UNTIL_MS.load(Ordering::SeqCst) {
                capture_window_bounds_for_active_camera(&win_for_events, false);
            }
        }
        WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
            reclamp_pip_for_scale_change(&win_for_events, *scale_factor);
        }
        WindowEvent::CloseRequested { .. } => {
            capture_window_bounds_for_active_camera(&win_for_events, true);
        }
        WindowEvent::Destroyed => {
            let silent = PIP_ALLOW_SILENT_CLOSE.swap(false, Ordering::SeqCst);
            if let Ok(mut guard) = CAMERA_PIP_STATE.write() {
                guard.active_camera_id = None;
                guard.latest_state_json = None;
            }
            if !silent {
                notify_main_pip_closed(&app_for_events);
            }
        }
        _ => {}
    });

    if should_focus {
        let _ = pip_win.show();
        let _ = pip_win.set_focus();
    } else {
        show_pip_window_no_activate(&pip_win);
    }
    set_window_cloaked(&pip_win, false);
    Ok(true)
}

#[tauri::command]
pub(crate) fn close_camera_pip_window(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(CAMERA_PIP_WINDOW_LABEL) {
        capture_window_bounds_for_active_camera(&window, true);
        PIP_ALLOW_SILENT_CLOSE.store(true, Ordering::SeqCst);
        if let Err(err) = window.close() {
            PIP_ALLOW_SILENT_CLOSE.store(false, Ordering::SeqCst);
            return Err(format!("无法关闭摄像机小窗：{err}"));
        }
    }
    if let Ok(mut guard) = CAMERA_PIP_STATE.write() {
        guard.active_camera_id = None;
        guard.latest_state_json = None;
    }
    Ok(())
}

pub(crate) fn close_camera_pip_on_exit(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(CAMERA_PIP_WINDOW_LABEL) {
        capture_window_bounds_for_active_camera(&window, true);
        PIP_ALLOW_SILENT_CLOSE.store(true, Ordering::SeqCst);
        let _ = window.close();
    }
}

#[tauri::command]
pub(crate) fn start_camera_pip_drag(window: WebviewWindow) {
    if window.label() == CAMERA_PIP_WINDOW_LABEL {
        let _ = window.start_dragging();
    }
}

#[tauri::command]
pub(crate) fn sync_camera_pip_state(app: AppHandle, payload_json: String) -> Result<(), String> {
    if let Ok(mut guard) = CAMERA_PIP_STATE.write() {
        guard.latest_state_json = Some(payload_json.clone());
    }
    if let Some(pip_win) = app.get_webview_window(CAMERA_PIP_WINDOW_LABEL) {
        let encoded = serde_json::to_string(&payload_json).map_err(|e| e.to_string())?;
        let script = format!(
            "window.dispatchEvent(new CustomEvent('menumijia:camera-pip-state', {{ detail: {encoded} }}))"
        );
        let _ = pip_win.eval(&script);
    }
    Ok(())
}

#[tauri::command]
pub(crate) fn get_camera_pip_state() -> Option<String> {
    CAMERA_PIP_STATE
        .read()
        .ok()
        .and_then(|guard| guard.latest_state_json.clone())
}

#[tauri::command]
pub(crate) fn camera_pip_action(app: AppHandle, action_json: String) -> Result<(), String> {
    if let Some(main_win) = app.get_webview_window("main") {
        let encoded = serde_json::to_string(&action_json).map_err(|e| e.to_string())?;
        let script = format!(
            "window.dispatchEvent(new CustomEvent('menumijia:camera-pip-action', {{ detail: {encoded} }}))"
        );
        let _ = main_win.eval(&script);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pip_defaults_and_clamping_respect_portrait_and_mixed_dpi() {
        let work_100 = Rect::new(0, 0, 1920, 1040);
        // Landscape default docks top-right with 16px margin.
        let (x, y, w, h) = place_pip_bounds(None, work_100, 1.0, false, false);
        assert_eq!((w, h), (420, 324));
        assert_eq!((x, y), (1920 - 16 - 420, 16));

        // 3:4 portrait doorbell default docks top-right with portrait dimensions.
        let (px, py, pw, ph) = place_pip_bounds(None, work_100, 1.0, true, false);
        assert_eq!((pw, ph), (300, 472));
        assert_eq!((px, py), (1920 - 16 - 300, 16));

        // Mixed-DPI 150% monitor scales logical dims and clamps saved off-screen coords back on-screen.
        let work_150 = Rect::new(1920, 0, 2560, 1368);
        let saved_offscreen = CameraPipBounds {
            x: 9999,
            y: 9999,
            logical_width: 480.0,
            logical_height: 360.0,
        };
        let (cx, cy, cw, ch) = place_pip_bounds(Some(saved_offscreen), work_150, 1.5, false, false);
        assert_eq!((cw, ch), (720, 540));
        assert_eq!((cx, cy), (1920 + 2560 - 24 - 720, 1368 - 24 - 540));

        // force_top_right overrides saved position (used by auto-open) while preserving remembered size.
        let (tx, ty, tw, th) = place_pip_bounds(Some(saved_offscreen), work_150, 1.5, false, true);
        assert_eq!((tw, th), (720, 540));
        assert_eq!((tx, ty), (1920 + 2560 - 24 - 720, 24));
    }

    #[test]
    fn pip_scale_reclamp_pulls_clipped_window_in_and_is_idempotent() {
        let work_150 = Rect::new(1920, 0, 2560, 1368);
        let clipped = reclamped_pip_bounds_for_scale(
            (1920 + 2560 - 300, 1368 - 200),
            (420, 324),
            work_150,
            420.0,
            324.0,
            1.5,
            false,
        );
        assert_eq!(clipped, Some((1920 + 2560 - 24 - 630, 1368 - 24 - 486, 630, 486)));
        assert_eq!(
            reclamped_pip_bounds_for_scale(
                (1920 + 2560 - 24 - 630, 1368 - 24 - 486),
                (630, 486),
                work_150,
                420.0,
                324.0,
                1.5,
                false,
            ),
            None
        );
    }

    #[test]
    fn pip_bounds_store_round_trips_and_filters_invalid_entries() {
        let temp = std::env::temp_dir().join(format!(
            "mbh-camera-pip-bounds-{}.json",
            now_epoch_ms()
        ));
        let mut map = HashMap::new();
        map.insert(
            "cam.1".to_string(),
            CameraPipBounds {
                x: 120,
                y: 80,
                logical_width: 440.0,
                logical_height: 330.0,
            },
        );
        write_pip_bounds_store(&temp, &map).unwrap();
        let loaded = read_pip_bounds_store(&temp);
        assert_eq!(loaded.get("cam.1"), map.get("cam.1"));
        let _ = std::fs::remove_file(&temp);
    }
}
