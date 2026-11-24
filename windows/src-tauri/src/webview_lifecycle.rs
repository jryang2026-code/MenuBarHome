//! WebView2 L1+L2 memory reduction and cold-start `panel-ready` anti-white-flash handshake (P1-4B).
//!
//! Design invariants (verified against reports 07, 10 & 11):
//! * L1 Dormant (`SetMemoryUsageTargetLevel(Low)`): triggered 15 s after the main flyout hides
//!   and restored to `Normal` immediately on `TrayIconEvent::Enter` or panel present. Keeps JS
//!   timers, safety alerts, and cloud refresh alive. Never calls `SetProcessWorkingSetSize(-1, -1)`.
//! * L2 Secondary window `DestroyWhenIdle(60s)` (EcoPaste pattern): closing the settings window
//!   hides it into `HiddenWarm` for fast reopens; after 60 s idle, emits
//!   `menumijia:settings-before-destroy` with a 500 ms grace period (vetoable via
//!   `settings_keepalive`), then calls `window.destroy()` to reclaim the secondary WebView2 process.
//! * First-frame `panel-ready` handshake: if the user clicks the tray before the cold-launched
//!   WebView2 finishes its first render, Rust defers the present (with a 1.5 s safety timeout) and
//!   shows/uncloaks once `panel_ready` arrives, eliminating blank white frames.

use std::sync::{LazyLock, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Manager, PhysicalPosition, WebviewWindow};

/// Delay after hiding the main flyout before hinting WebView2 `MemoryUsageTargetLevel::Low` (5–30 s).
pub(crate) const PANEL_MEMORY_LOW_DELAY_SECS: u64 = 15;
/// Idle retention window for a closed settings window before destroying its WebView2 process.
pub(crate) const SETTINGS_IDLE_DESTROY_SECS: u64 = 60;
/// Grace period after `menumijia:settings-before-destroy` so the frontend can flush or veto.
pub(crate) const SETTINGS_BEFORE_DESTROY_GRACE_MS: u64 = 500;
/// Safety deadline for the cold-start `panel-ready` handshake so a broken script never blocks open.
pub(crate) const PANEL_READY_FALLBACK_MS: u64 = 1_500;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct WebViewMemoryState {
    generation: u64,
    is_low: bool,
    pending_low: bool,
}

impl WebViewMemoryState {
    pub(crate) fn schedule_low(&mut self) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.pending_low = true;
        self.generation
    }

    pub(crate) fn should_enter_low(&mut self, generation: u64, is_visible: bool) -> bool {
        if !self.pending_low || self.generation != generation || is_visible {
            return false;
        }
        self.pending_low = false;
        if self.is_low {
            return false;
        }
        self.is_low = true;
        true
    }

    /// Cancels any pending transition to `Low` and returns `true` only if the WebView2 was
    /// previously placed into `Low` and needs a `Normal` restoration call.
    pub(crate) fn restore_normal(&mut self) -> bool {
        self.generation = self.generation.wrapping_add(1);
        self.pending_low = false;
        std::mem::replace(&mut self.is_low, false)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum SettingsRetainState {
    #[default]
    Destroyed,
    Open,
    HiddenWarm {
        generation: u64,
    },
    DestroyPending {
        generation: u64,
    },
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct SettingsIdleLifecycle {
    generation: u64,
    state: SettingsRetainState,
}

impl SettingsIdleLifecycle {
    pub(crate) fn mark_open(&mut self) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.state = SettingsRetainState::Open;
        self.generation
    }

    pub(crate) fn mark_hidden(&mut self) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.state = SettingsRetainState::HiddenWarm {
            generation: self.generation,
        };
        self.generation
    }

    pub(crate) fn begin_destroy_grace(&mut self, generation: u64, is_visible: bool) -> bool {
        if is_visible {
            return false;
        }
        match self.state {
            SettingsRetainState::HiddenWarm { generation: g } if g == generation => {
                self.state = SettingsRetainState::DestroyPending { generation };
                true
            }
            _ => false,
        }
    }

    /// Resets a pending idle destroy back into `HiddenWarm` with a fresh generation.
    pub(crate) fn keepalive(&mut self, expected_generation: Option<u64>) -> Option<u64> {
        match self.state {
            SettingsRetainState::HiddenWarm { generation: g }
            | SettingsRetainState::DestroyPending { generation: g }
                if expected_generation.is_none_or(|exp| exp == g) =>
            {
                Some(self.mark_hidden())
            }
            _ => None,
        }
    }

    pub(crate) fn confirm_destroy(&mut self, generation: u64, is_visible: bool) -> bool {
        if is_visible {
            return false;
        }
        match self.state {
            SettingsRetainState::DestroyPending { generation: g } if g == generation => {
                self.state = SettingsRetainState::Destroyed;
                true
            }
            _ => false,
        }
    }

    pub(crate) fn mark_destroyed(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.state = SettingsRetainState::Destroyed;
    }

    #[cfg(test)]
    pub(crate) fn state(&self) -> SettingsRetainState {
        self.state
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PresentDecision<T> {
    PresentNow(T),
    Deferred { start_fallback_timer: bool },
}

#[derive(Debug)]
pub(crate) struct PanelReadyGate<T> {
    ready: bool,
    fallback_armed: bool,
    pending: Option<T>,
}

impl<T> Default for PanelReadyGate<T> {
    fn default() -> Self {
        Self {
            ready: false,
            fallback_armed: false,
            pending: None,
        }
    }
}

impl<T> PanelReadyGate<T> {
    pub(crate) fn try_present(&mut self, payload: T) -> PresentDecision<T> {
        if self.ready {
            return PresentDecision::PresentNow(payload);
        }
        self.pending = Some(payload);
        let start_fallback_timer = !std::mem::replace(&mut self.fallback_armed, true);
        PresentDecision::Deferred {
            start_fallback_timer,
        }
    }

    pub(crate) fn mark_ready(&mut self) -> Option<T> {
        self.ready = true;
        self.fallback_armed = false;
        self.pending.take()
    }

    pub(crate) fn on_fallback_timeout(&mut self) -> Option<T> {
        if self.ready {
            return None;
        }
        self.ready = true;
        self.fallback_armed = false;
        self.pending.take()
    }

    pub(crate) fn cancel_pending(&mut self) {
        self.pending = None;
    }
}

#[derive(Clone)]
pub(crate) struct PendingPanelPresent {
    pub(crate) anchor: Option<PhysicalPosition<f64>>,
    pub(crate) tray_rect: Option<tauri::Rect>,
    pub(crate) after_present_script: Option<&'static str>,
}

static PANEL_MEMORY_STATE: LazyLock<Mutex<WebViewMemoryState>> =
    LazyLock::new(|| Mutex::new(WebViewMemoryState::default()));
static SETTINGS_IDLE_STATE: LazyLock<Mutex<SettingsIdleLifecycle>> =
    LazyLock::new(|| Mutex::new(SettingsIdleLifecycle::default()));
static PANEL_READY_GATE: LazyLock<Mutex<PanelReadyGate<PendingPanelPresent>>> =
    LazyLock::new(|| Mutex::new(PanelReadyGate::default()));

#[cfg(all(windows, not(test)))]
fn apply_webview_memory_level(window: &WebviewWindow, low: bool) {
    let _ = window.with_webview(move |webview| {
        use webview2_com::Microsoft::Web::WebView2::Win32::{
            COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_LOW,
            COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_NORMAL, ICoreWebView2_19,
        };
        use windows::core::Interface;

        let target = if low {
            COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_LOW
        } else {
            COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_NORMAL
        };
        unsafe {
            let Ok(core) = webview.controller().CoreWebView2() else {
                return;
            };
            let Ok(wv19) = core.cast::<ICoreWebView2_19>() else {
                return;
            };
            let _ = wv19.SetMemoryUsageTargetLevel(target);
        }
    });
}

#[cfg(any(not(windows), test))]
fn apply_webview_memory_level(_window: &WebviewWindow, _low: bool) {}

/// Schedules the main WebView2 to enter `MemoryUsageTargetLevel::Low` after the idle window.
pub(crate) fn schedule_panel_low_memory(app: &AppHandle) {
    let Ok(mut state) = PANEL_MEMORY_STATE.lock() else {
        return;
    };
    let generation = state.schedule_low();
    drop(state);

    let app_clone = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(PANEL_MEMORY_LOW_DELAY_SECS));
        let app_for_main = app_clone.clone();
        let _ = app_clone.run_on_main_thread(move || {
            let Some(window) = app_for_main.get_webview_window("main") else {
                return;
            };
            let is_visible = window.is_visible().unwrap_or(false);
            let should_apply = PANEL_MEMORY_STATE
                .lock()
                .map(|mut state| state.should_enter_low(generation, is_visible))
                .unwrap_or(false);
            if should_apply {
                apply_webview_memory_level(&window, true);
            }
        });
    });
}

/// Immediately restores the main WebView2 to `MemoryUsageTargetLevel::Normal` (e.g. before
/// presenting the panel).
pub(crate) fn restore_panel_normal_memory(app: &AppHandle) {
    let needs_restore = PANEL_MEMORY_STATE
        .lock()
        .map(|mut state| state.restore_normal())
        .unwrap_or(false);
    if !needs_restore {
        return;
    }
    let app_clone = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(window) = app_clone.get_webview_window("main") {
            apply_webview_memory_level(&window, false);
        }
    });
}

/// Restores `Normal` memory on `TrayIconEvent::Enter` for instant open, and arms a fresh
/// low-memory timer so a hover without clicking does not leave the hidden WebView2 stuck in
/// `Normal` indefinitely.
pub(crate) fn warm_panel_on_tray_hover(app: &AppHandle) {
    restore_panel_normal_memory(app);
    schedule_panel_low_memory(app);
}

pub(crate) fn settings_mark_open() {
    if let Ok(mut state) = SETTINGS_IDLE_STATE.lock() {
        let _ = state.mark_open();
    }
}

pub(crate) fn settings_mark_destroyed() {
    if let Ok(mut state) = SETTINGS_IDLE_STATE.lock() {
        state.mark_destroyed();
    }
}

fn spawn_settings_idle_timer(app: AppHandle, generation: u64) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(SETTINGS_IDLE_DESTROY_SECS));
        let app_for_grace = app.clone();
        let _ = app.run_on_main_thread(move || {
            let Some(window) = app_for_grace.get_webview_window("settings") else {
                settings_mark_destroyed();
                return;
            };
            let is_visible = window.is_visible().unwrap_or(false);
            let entered_grace = SETTINGS_IDLE_STATE
                .lock()
                .map(|mut state| state.begin_destroy_grace(generation, is_visible))
                .unwrap_or(false);
            if !entered_grace {
                return;
            }
            let script = format!(
                "window.dispatchEvent(new CustomEvent('menumijia:settings-before-destroy', {{ detail: {{ generation: {generation} }} }}))"
            );
            let _ = window.eval(&script);

            let app_for_destroy = app_for_grace.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(SETTINGS_BEFORE_DESTROY_GRACE_MS));
                let app_final = app_for_destroy.clone();
                let _ = app_for_destroy.run_on_main_thread(move || {
                    let Some(window) = app_final.get_webview_window("settings") else {
                        settings_mark_destroyed();
                        return;
                    };
                    let is_visible = window.is_visible().unwrap_or(false);
                    let should_destroy = SETTINGS_IDLE_STATE
                        .lock()
                        .map(|mut state| state.confirm_destroy(generation, is_visible))
                        .unwrap_or(false);
                    if should_destroy {
                        let _ = window.destroy();
                    }
                });
            });
        });
    });
}

/// Transitions the settings window into `HiddenWarm` and schedules `DestroyWhenIdle(60s)`.
pub(crate) fn hide_settings_window_idle(app: &AppHandle, window: &WebviewWindow) -> Result<(), String> {
    window
        .hide()
        .map_err(|err| format!("无法隐藏设置窗口：{err}"))?;
    let generation = SETTINGS_IDLE_STATE
        .lock()
        .map(|mut state| state.mark_hidden())
        .unwrap_or(0);
    spawn_settings_idle_timer(app.clone(), generation);
    Ok(())
}

/// Extends a hidden settings window's idle retention window (e.g. if the frontend vetoes
/// `menumijia:settings-before-destroy`).
#[tauri::command]
pub(crate) fn settings_keepalive(app: AppHandle, generation: Option<u64>) -> bool {
    let next_gen = SETTINGS_IDLE_STATE
        .lock()
        .ok()
        .and_then(|mut state| state.keepalive(generation));
    if let Some(new_gen) = next_gen {
        spawn_settings_idle_timer(app, new_gen);
        true
    } else {
        false
    }
}

pub(crate) fn gate_or_present_panel(
    app: &AppHandle,
    payload: PendingPanelPresent,
) -> Option<PendingPanelPresent> {
    let decision = PANEL_READY_GATE
        .lock()
        .map(|mut gate| gate.try_present(payload.clone()))
        .unwrap_or(PresentDecision::PresentNow(payload));
    match decision {
        PresentDecision::PresentNow(ready_payload) => Some(ready_payload),
        PresentDecision::Deferred {
            start_fallback_timer,
        } => {
            if start_fallback_timer {
                let app_clone = app.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(PANEL_READY_FALLBACK_MS));
                    let pending = PANEL_READY_GATE
                        .lock()
                        .ok()
                        .and_then(|mut gate| gate.on_fallback_timeout());
                    if let Some(pending) = pending {
                        crate::window::finish_deferred_panel_present(&app_clone, pending);
                    }
                });
            }
            None
        }
    }
}

pub(crate) fn cancel_pending_panel_present() {
    if let Ok(mut gate) = PANEL_READY_GATE.lock() {
        gate.cancel_pending();
    }
}

/// Called by the main panel frontend right after its first DOM render + animation frame so
/// cold-launched tray clicks never flash a blank white frame.
#[tauri::command]
pub(crate) fn panel_ready(app: AppHandle) {
    let pending = PANEL_READY_GATE
        .lock()
        .ok()
        .and_then(|mut gate| gate.mark_ready());
    if let Some(pending) = pending {
        crate::window::finish_deferred_panel_present(&app, pending);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn webview_memory_state_guards_generations_visibility_and_redundant_restores() {
        let mut mem = WebViewMemoryState::default();
        // Restoring before ever entering Low is a no-op.
        assert!(!mem.restore_normal());

        let gen1 = mem.schedule_low();
        // Visible panel must not enter Low even if timer fires.
        assert!(!mem.should_enter_low(gen1, true));
        // Stale generation is ignored.
        let gen2 = mem.schedule_low();
        assert!(!mem.should_enter_low(gen1, false));
        // Current hidden generation enters Low once.
        assert!(mem.should_enter_low(gen2, false));
        assert!(!mem.should_enter_low(gen2, false));

        // Tray hover / present restores Normal once.
        assert!(mem.restore_normal());
        assert!(!mem.restore_normal());

        // Hovering before the 15 s timer expires cancels the old timer and re-arms a fresh one
        // so a hover without opening still returns the hidden panel to Low.
        let gen3 = mem.schedule_low();
        assert!(!mem.restore_normal());
        let gen4 = mem.schedule_low();
        assert!(!mem.should_enter_low(gen3, false));
        assert!(mem.should_enter_low(gen4, false));
    }

    #[test]
    fn settings_idle_lifecycle_handles_reopen_keepalive_and_destroy_grace() {
        let mut life = SettingsIdleLifecycle::default();
        life.mark_open();
        assert_eq!(life.state(), SettingsRetainState::Open);

        let g1 = life.mark_hidden();
        assert_eq!(life.state(), SettingsRetainState::HiddenWarm { generation: g1 });

        // Reopening within 60 s invalidates g1.
        life.mark_open();
        assert!(!life.begin_destroy_grace(g1, false));

        // Hide again -> idle timer enters DestroyPending -> keepalive vetoes -> old gen cannot destroy.
        let g2 = life.mark_hidden();
        assert!(life.begin_destroy_grace(g2, false));
        assert_eq!(
            life.state(),
            SettingsRetainState::DestroyPending { generation: g2 }
        );
        let g3 = life.keepalive(Some(g2)).expect("keepalive refreshes hidden timer");
        assert_ne!(g3, g2);
        assert!(!life.confirm_destroy(g2, false));

        // Visible window blocks both grace and destroy.
        assert!(!life.begin_destroy_grace(g3, true));
        assert!(life.begin_destroy_grace(g3, false));
        assert!(!life.confirm_destroy(g3, true));
        assert!(life.confirm_destroy(g3, false));
        assert_eq!(life.state(), SettingsRetainState::Destroyed);
    }

    #[test]
    fn panel_ready_gate_defers_until_first_frame_or_fallback_timeout() {
        let mut gate: PanelReadyGate<&'static str> = PanelReadyGate::default();

        // First click before ready defers and arms the fallback timer once.
        assert_eq!(
            gate.try_present("click-1"),
            PresentDecision::Deferred {
                start_fallback_timer: true
            }
        );
        // Second click replaces pending payload without arming a second timer.
        assert_eq!(
            gate.try_present("click-2"),
            PresentDecision::Deferred {
                start_fallback_timer: false
            }
        );
        // Frontend ready drains latest pending present.
        assert_eq!(gate.mark_ready(), Some("click-2"));
        // Subsequent fallback timeout is a no-op.
        assert_eq!(gate.on_fallback_timeout(), None);
        // Subsequent clicks present immediately.
        assert_eq!(
            gate.try_present("click-3"),
            PresentDecision::PresentNow("click-3")
        );

        // Fallback timeout unblocks if frontend never calls panel_ready.
        let mut timed_out: PanelReadyGate<&'static str> = PanelReadyGate::default();
        assert_eq!(
            timed_out.try_present("cold-click"),
            PresentDecision::Deferred {
                start_fallback_timer: true
            }
        );
        assert_eq!(timed_out.on_fallback_timeout(), Some("cold-click"));
        assert_eq!(timed_out.mark_ready(), None);
    }
}
