use super::*;

struct WindowInit {
    state: *mut AppStateSlot,
    adopted: *mut bool,
}

struct OleGuard;

impl Drop for OleGuard {
    fn drop(&mut self) {
        // SAFETY: OleGuard exists only after successful OleInitialize and drops
        // on the same UI thread after the window revoked its drop target.
        unsafe { OleUninitialize() };
    }
}

pub(super) fn run() -> io::Result<()> {
    run_unsafe()
}

fn minimum_track_width(window: HWND, state: &AppState) -> i32 {
    let mut outer = RECT::default();
    let mut client = RECT::default();
    // SAFETY: window is the live top-level HWND and outer remains writable for
    // the duration of this synchronous query.
    let got_outer = unsafe { GetWindowRect(window, &mut outer) } != 0;
    // SAFETY: window is the live top-level HWND and client remains writable for
    // the duration of this synchronous query.
    let got_client = unsafe { GetClientRect(window, &mut client) } != 0;
    let nonclient_width = if got_outer && got_client {
        ((outer.right - outer.left) - (client.right - client.left)).max(0)
    } else {
        0
    };
    let density = state.resolved_appearance().appearance.density;
    let rail_width = density.minimum_density().map_or(0, |minimum| {
        state
            .font_metrics
            .rail_metrics(minimum, state.dpi)
            .rail_width
    });
    let baseline_rail_width = density
        .minimum_density()
        .map_or(0, |minimum| minimum.metrics(state.dpi).rail_width);
    let workspace_divider_width = i32::from(rail_width > 0).saturating_mul(2);
    let measured_content_width = scale_dip(minimum_content_width_dip(), state.dpi)
        .saturating_add(
            rail_width
                .saturating_sub(baseline_rail_width)
                .saturating_mul(2),
        )
        .saturating_add(workspace_divider_width)
        .max(
            rail_width
                .saturating_mul(2)
                .saturating_add(state.font_metrics.empty_state_minimum_width(state.dpi))
                .saturating_add(workspace_divider_width),
        );
    scale_dip(INITIAL_WIDTH, state.dpi).max(measured_content_width.saturating_add(nonclient_width))
}

fn nonclient_height(window: HWND) -> i32 {
    let mut outer = RECT::default();
    let mut client = RECT::default();
    // SAFETY: window is live and outer is writable for this synchronous query.
    let got_outer = unsafe { GetWindowRect(window, &mut outer) } != 0;
    // SAFETY: window is live and client is writable for this synchronous query.
    let got_client = unsafe { GetClientRect(window, &mut client) } != 0;
    if !got_outer || !got_client {
        return 0;
    }
    ((outer.bottom - outer.top) - (client.bottom - client.top)).max(0)
}

fn minimum_track_height(window: HWND, state: &AppState) -> i32 {
    let appearance = state.resolved_appearance().appearance;
    minimum_main_client_height_with_safety(
        state.dpi,
        state.font_metrics,
        appearance.density,
        appearance.show_empty_safety,
    )
    .saturating_add(nonclient_height(window))
}

fn requested_minimum_track_size(window: HWND, state: &AppState) -> WindowTrackSize {
    WindowTrackSize {
        width: minimum_track_width(window, state),
        height: minimum_track_height(window, state),
    }
}

fn nearest_monitor_work_area(window: HWND) -> io::Result<RECT> {
    // SAFETY: window is live; the nearest-monitor query dereferences no caller
    // memory and returns a borrowed monitor identifier.
    let monitor = unsafe { MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST) };
    if monitor.is_null() {
        return Err(io::Error::last_os_error());
    }
    let mut monitor_info = MONITORINFO {
        cbSize: u32::try_from(size_of::<MONITORINFO>())
            .map_err(|_| io::Error::other("invalid monitor info size"))?,
        ..MONITORINFO::default()
    };
    // SAFETY: monitor is live and monitor_info has its exact structure size and
    // remains writable for this synchronous query.
    if unsafe { GetMonitorInfoW(monitor, &mut monitor_info) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let work = monitor_info.rcWork;
    if work.right <= work.left || work.bottom <= work.top {
        return Err(io::Error::other("invalid monitor work area"));
    }
    Ok(work)
}

fn effective_minimum_track_size(window: HWND, state: &AppState) -> io::Result<WindowTrackSize> {
    let requested = requested_minimum_track_size(window, state);
    let work = nearest_monitor_work_area(window)?;
    constrain_minimum_track_size_to_work_area(
        requested.width,
        requested.height,
        work.right - work.left,
        work.bottom - work.top,
    )
    .ok_or_else(|| io::Error::other("invalid minimum track size"))
}

fn recommended_track_height(window: HWND, state: &AppState) -> i32 {
    let appearance = state.resolved_appearance().appearance;
    recommended_main_client_height_with_safety(
        state.dpi,
        state.font_metrics,
        appearance.density,
        appearance.show_empty_safety,
    )
    .saturating_add(nonclient_height(window))
}

fn initial_dpi_size(window: HWND, state: &AppState) -> (i32, i32) {
    let requested = WindowTrackSize {
        width: minimum_track_width(window, state),
        height: scale_dip(INITIAL_HEIGHT, state.dpi).max(recommended_track_height(window, state)),
    };
    let effective = nearest_monitor_work_area(window)
        .ok()
        .and_then(|work| {
            constrain_minimum_track_size_to_work_area(
                requested.width,
                requested.height,
                work.right - work.left,
                work.bottom - work.top,
            )
        })
        .unwrap_or(requested);
    (effective.width, effective.height)
}

fn resize_to_initial_dpi(window: HWND, width: i32, height: i32) -> io::Result<()> {
    // SAFETY: window is the newly created hidden top-level HWND. The flags keep
    // its system-selected position and z-order while applying physical pixels
    // derived from the window's actual DPI before the first ShowWindow call.
    if unsafe {
        SetWindowPos(
            window,
            null_mut(),
            0,
            0,
            width,
            height,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn has_window_state(window: HWND) -> bool {
    !app_state_slot(window).is_null()
}

fn valid_focus_target(window: HWND, target: HWND) -> bool {
    if target.is_null() {
        return false;
    }
    // SAFETY: all calls are non-owning value queries. Requiring a live direct
    // child, enabled state, and effective visibility rejects stale HWNDs and
    // hidden menu-only rail buttons at the final action boundary.
    unsafe {
        IsWindow(target) != 0
            && GetParent(target) == window
            && IsWindowEnabled(target) != 0
            && IsWindowVisible(target) != 0
    }
}

fn navigation_focus_target(window: HWND, message: &MSG) -> Option<HWND> {
    let mut state_lease = try_app_state(window)?;
    let target = handle_focus_navigation(state_lease.state_mut(), message)?;
    drop(state_lease);
    valid_focus_target(window, target).then_some(target)
}

fn restored_focus_target(window: HWND, state: &mut AppState) -> Option<HWND> {
    let target = restore_child_focus(state)?;
    valid_focus_target(window, target).then_some(target)
}

fn apply_focus_target(target: HWND) {
    // SAFETY: callers validate target after releasing every AppState reference;
    // SetFocus may synchronously emit BN_SETFOCUS and reenter window_proc.
    unsafe { SetFocus(target) };
}

fn ensure_minimum_track_size(window: HWND, state: &AppState) -> io::Result<()> {
    let mut rect = RECT::default();
    // SAFETY: window is the live top-level HWND owned by this UI thread.
    if unsafe { GetWindowRect(window, &mut rect) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let work = nearest_monitor_work_area(window)?;
    let requested = requested_minimum_track_size(window, state);
    let minimum = constrain_minimum_track_size_to_work_area(
        requested.width,
        requested.height,
        work.right - work.left,
        work.bottom - work.top,
    )
    .ok_or_else(|| io::Error::other("invalid minimum track size"))?;
    let current_width = rect.right - rect.left;
    let current_height = rect.bottom - rect.top;
    if current_width >= minimum.width && current_height >= minimum.height {
        return Ok(());
    }
    let placement = fit_widened_window_to_work_area(
        rect.left,
        work.left,
        work.right,
        minimum.width.max(current_width),
    )
    .ok_or_else(|| io::Error::other("invalid monitor work area"))?;
    let work_height = work.bottom - work.top;
    let height = minimum.height.max(current_height).min(work_height);
    let latest_y = work.bottom - height;
    let y = rect.top.clamp(work.top, latest_y);
    // SAFETY: the live window is resized within the nearest monitor work area
    // without changing activation or z-order.
    if unsafe {
        SetWindowPos(
            window,
            null_mut(),
            placement.x,
            y,
            placement.width,
            height,
            SWP_NOZORDER | SWP_NOACTIVATE,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn run_unsafe() -> io::Result<()> {
    if process_is_elevated()? {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "관리자 권한으로는 실행할 수 없습니다. 일반 사용자 권한으로 다시 실행해 주세요.",
        ));
    }
    // SAFETY: OleInitialize requires a null reserved pointer, initializes the
    // UI thread as STA, and is balanced by OleGuard on this same thread.
    let ole_status = unsafe { OleInitialize(null()) };
    if ole_status < 0 {
        return Err(io::Error::other(format!(
            "OLE initialization failed: 0x{:08X}",
            ole_status as u32
        )));
    }
    let _ole = OleGuard;
    // A failed WinRT initialization does not block the native workbench. System
    // theme resolution then falls back to the documented light/native path.
    let _winrt = WinRtGuard::initialize();
    let controls = INITCOMMONCONTROLSEX {
        dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
        dwICC: ICC_LISTVIEW_CLASSES | ICC_WIN95_CLASSES,
    };
    // SAFETY: controls is initialized with its exact structure size and lives through InitCommonControlsEx.
    unsafe { InitCommonControlsEx(&controls) };
    // SAFETY: A null module name requests the current process module and dereferences no caller memory.
    let instance = unsafe { GetModuleHandleW(null()) };
    if instance.is_null() {
        return Err(io::Error::last_os_error());
    }
    let class_name = wide("DarkReNamerWindow");
    // SAFETY: instance is the current live module and int_resource encodes the linked APP_ICON resource.
    let icon = unsafe { LoadIconW(instance, int_resource(resource_ids::APP_ICON)) };
    let window_class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(window_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        hIcon: icon,
        // SAFETY: A null instance plus IDC_ARROW is the documented predefined-cursor request.
        hCursor: unsafe { LoadCursorW(null_mut(), IDC_ARROW) },
        hbrBackground: (COLOR_WINDOW + 1) as *mut c_void,
        lpszMenuName: null(),
        lpszClassName: class_name.as_ptr(),
        hIconSm: icon,
    };
    // SAFETY: WNDCLASSEXW is initialized and its class name and callback remain valid during registration.
    if unsafe { RegisterClassExW(&window_class) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let title = wide("DarkReNamer");
    let runtime = initialize_safe_runtime()?;
    let startup_recovery_pending = runtime.recovery_locked
        && !runtime.collision_observed
        && runtime.active_journal.is_some()
        && runtime.staged_journal.is_none()
        && runtime.blocked_journals.is_empty();
    let startup_notice = (!startup_recovery_pending)
        .then(|| runtime.status.clone())
        .flatten();
    let state: *mut AppStateSlot = CallbackState::into_raw(AppState::new(runtime));
    let mut adopted = false;
    let mut init = WindowInit {
        state,
        adopted: &mut adopted,
    };
    // SAFETY: instance is the current module; class_name/title and stack WindowInit
    // storage remain allocated throughout this synchronous CreateWindowExW call.
    let window = unsafe {
        CreateWindowExW(
            WS_EX_APPWINDOW,
            class_name.as_ptr(),
            title.as_ptr(),
            WS_OVERLAPPEDWINDOW | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            INITIAL_WIDTH,
            INITIAL_HEIGHT,
            null_mut(),
            null_mut(),
            instance,
            (&mut init as *mut WindowInit).cast(),
        )
    };
    if window.is_null() {
        if !adopted {
            // SAFETY: WM_NCCREATE did not adopt state, so this is the sole Box::from_raw for the still-owned Box::into_raw allocation.
            unsafe { drop(Box::from_raw(state)) };
        }
        return Err(io::Error::last_os_error());
    }
    // The menu was intentionally created but not attached during WM_CREATE.
    // Attach it now, outside that callback's AppState lease, so synchronous
    // owner-draw measurement can safely borrow the rendering state.
    // SAFETY: window is the live top-level HWND and the private message carries
    // no pointers or borrowed data.
    unsafe { SendMessageW(window, WM_APP_MENU_REDRAW, 0, 0) };
    let Some(state_lease) = try_app_state(window) else {
        // SAFETY: the created window did not retain its required AppState and
        // is destroyed before returning the initialization failure.
        unsafe { DestroyWindow(window) };
        return Err(io::Error::other("window state was not adopted"));
    };
    let (initial_width, initial_height) = initial_dpi_size(window, state_lease.state());
    drop(state_lease);
    if let Err(error) = resize_to_initial_dpi(window, initial_width, initial_height) {
        // SAFETY: window is still hidden and owns the adopted AppState. Its
        // normal teardown reclaims children, GDI resources, and the state.
        unsafe { DestroyWindow(window) };
        return Err(error);
    }
    let accelerators = match AcceleratorTable::create() {
        Ok(accelerators) => accelerators,
        Err(error) => {
            // SAFETY: window is still hidden and owns the adopted AppState. Its
            // normal teardown reclaims children, GDI resources, and the state.
            unsafe { DestroyWindow(window) };
            return Err(error);
        }
    };
    // SAFETY: window is the non-null top-level HWND just created and remains owned by this UI thread.
    unsafe {
        ShowWindow(window, SW_SHOW);
        UpdateWindow(window);
    }
    if startup_recovery_pending {
        confirm_startup_recovery(window);
    } else if let Some(notice) = startup_notice {
        message(window, &notice, "DarkReNamer - 복구 상태");
    }
    let mut message = MSG::default();
    loop {
        // SAFETY: message is writable MSG storage outliving GetMessageW; null HWND requests this thread queue.
        let result = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if result == -1 {
            let error = io::Error::last_os_error();
            if let Some(mut state_lease) = try_app_state(window) {
                cancel_appearance_dialog(window, state_lease.state_mut());
            }
            finish_apply_after_message_loop_failure(window);
            // SAFETY: window is the live top-level HWND created above and this
            // path destroys it only after any worker reached terminal handoff.
            unsafe { DestroyWindow(window) };
            return Err(error);
        }
        if result == 0 {
            break;
        }
        let state_is_live = has_window_state(window);
        let appearance_dialog = if state_is_live {
            try_app_state(window)
                .and_then(|state_lease| active_appearance_dialog(state_lease.state()))
        } else {
            None
        };
        // The owned appearance dialog gets native Tab/Shift+Tab/Esc/Enter
        // handling before owner accelerators can consume the key.
        if let Some(dialog) = appearance_dialog
            // SAFETY: dialog is a live owned top-level HWND and message is the
            // current thread-queue value populated by GetMessageW.
            && unsafe { IsDialogMessageW(dialog, &message) } != 0
        {
            continue;
        }
        if state_is_live && accelerators.translate(window, &message) {
            continue;
        }
        if state_is_live && let Some(target) = navigation_focus_target(window, &message) {
            apply_focus_target(target);
            continue;
        }
        // SAFETY: window is the live top-level owner and message was populated
        // by GetMessageW. Existing accelerators are handled first; dialog-style
        // navigation then provides Tab and Shift+Tab across direct children.
        if state_is_live && unsafe { IsDialogMessageW(window, &message) } != 0 {
            continue;
        }
        // SAFETY: message was initialized by GetMessageW and remains valid through synchronous translation and dispatch.
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    Ok(())
}

pub(super) fn handle_list_marquee_begin(list_window: HWND, lparam: LPARAM) -> Option<LRESULT> {
    let header = lparam as *const NMHDR;
    if header.is_null()
        // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix for this
        // synchronous callback; the null pointer was rejected above.
        || unsafe { (*header).hwndFrom } != list_window
    {
        return None;
    }
    // Read the notification code only after validating the exact source HWND.
    // SAFETY: same live NMHDR prefix and verified ListView sender as above.
    if unsafe { (*header).code } != LVN_MARQUEEBEGIN {
        return None;
    }
    // Query native state rather than the model: refresh can temporarily make
    // the two counts differ, while marquee selection acts on rendered rows.
    // SAFETY: list_window is the live sender verified from this synchronous
    // notification, and LVM_GETITEMCOUNT has no pointer payload.
    let item_count = unsafe { SendMessageW(list_window, LVM_GETITEMCOUNT, 0, 0) };
    Some(if item_count == 0 { 1 } else { 0 })
}

const fn repaints_menu_bottom_edge(message: u32) -> bool {
    matches!(message, WM_NCPAINT | WM_NCACTIVATE)
}

pub(super) const fn suppresses_busy_callback_message(message: u32) -> bool {
    matches!(message, WM_COMMAND | WM_NOTIFY | WM_CLOSE | WM_TIMER) || message >= WM_APP
}

pub(super) fn handle_empty_safety_copy(
    state_lease: CallbackStateLease<AppState, DropTargetRegistrations>,
    wparam: WPARAM,
) -> LRESULT {
    let safety = state_lease.state().empty_safety;
    let mode = if wparam == 0 {
        RailMode::MenuOnly
    } else {
        RailMode::Compact
    };
    let text = empty_state_safety_copy(mode);
    run_after_callback_state_release(state_lease, || set_status(safety, text));
    0
}

pub(super) fn handle_status_render_timer(
    window: HWND,
    state_lease: CallbackStateLease<AppState, DropTargetRegistrations>,
) -> LRESULT {
    // Stop the coalescing timer only after the caller acquired the state lease.
    // A busy nested WM_TIMER cannot call this helper and leaves it installed.
    // SAFETY: window owns this exact timer identifier; killing an absent timer
    // is harmless and carries no callback payload.
    unsafe { KillTimer(window, STATUS_RENDER_TIMER_ID) };
    let state = state_lease.state();
    let status_message = state.status_message;
    let status_count = state.status_count;
    let message_text = state.ui_status.message_text().to_owned();
    let count_text = state.ui_status.count_text();
    run_after_callback_state_release(state_lease, || {
        set_status(status_message, &message_text);
        set_status(status_count, &count_text);
    });
    0
}

fn run_prepared_command_action_after_state_release<T, R>(
    state_lease: CallbackStateLease<T, R>,
    window: HWND,
    action: Option<PreparedCommandAction>,
    select_file_dialog: impl FnOnce(HWND, PreparedFileDialogKind) -> PreparedFileDialogSelection,
    select_task_dialog: impl FnOnce(HWND, &PreparedTaskDialogSpec) -> io::Result<i32>,
) -> Option<()> {
    run_after_callback_state_release(state_lease, || {
        action.map(|action| {
            run_prepared_command_action(window, action, select_file_dialog, select_task_dialog);
        })
    })
}

fn run_prepared_worker_task_dialog_after_state_release<T, R>(
    state_lease: CallbackStateLease<T, R>,
    window: HWND,
    prepared: Option<PreparedWorkerTaskDialog>,
    select: impl FnOnce(HWND, &PreparedTaskDialogSpec) -> io::Result<i32>,
) {
    run_after_callback_state_release(state_lease, || {
        if let Some(prepared) = prepared {
            run_prepared_worker_task_dialog(window, prepared, select);
        }
    });
}

unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        let create = lparam as *const CREATESTRUCTW;
        if !create.is_null() {
            // SAFETY: For WM_NCCREATE, Windows supplies a non-null CREATESTRUCTW in lparam that remains readable for this callback.
            let init = unsafe { (*create).lpCreateParams as *mut WindowInit };
            if !init.is_null() {
                // SAFETY: lpCreateParams is the live WindowInit passed to CreateWindowExW; adopted and state remain valid for this synchronous callback.
                unsafe {
                    *(*init).adopted = true;
                    SetWindowLongPtrW(window, GWLP_USERDATA, (*init).state as isize);
                }
            }
        }
    }
    let state_slot = app_state_slot(window);
    if message == WM_APP_SHOW_DEFERRED_MESSAGE {
        if app_callback_is_busy(window) {
            // The successful post may be consumed by a nested modal loop while
            // the originating callback still owns AppState. Keep retrying with
            // a pointer-free timer until that lease ends.
            // SAFETY: this exact timer belongs to the still-live owner.
            unsafe { SetTimer(window, DEFERRED_MESSAGE_TIMER_ID, 1, None) };
            return 0;
        }
        // Kill before MessageBoxW starts another modal loop; the HWND may be
        // destroyed or reused before that loop returns.
        // SAFETY: an absent fallback timer on this live callback owner is harmless.
        unsafe { KillTimer(window, DEFERRED_MESSAGE_TIMER_ID) };
        let _ = drain_deferred_messages_if_available(window, show_message_now);
        return 0;
    }
    if message == WM_TIMER && wparam == DEFERRED_MESSAGE_TIMER_ID {
        if app_callback_is_busy(window) {
            return 0;
        }
        // SAFETY: kill the live owner's timer before modal display can destroy
        // or recycle the numeric HWND.
        unsafe { KillTimer(window, DEFERRED_MESSAGE_TIMER_ID) };
        let _ = drain_deferred_messages_if_available(window, show_message_now);
        return 0;
    }
    if message != WM_NCDESTROY && !app_callback_is_busy(window) && has_deferred_messages(window) {
        // Scheduling is non-modal and pointer-free, so this callback may safely
        // continue with its already-copied state slot. Repeated ordinary
        // callbacks retry if both queue wake mechanisms previously failed.
        let _ = schedule_deferred_message_wake(
            window,
            |target| {
                // SAFETY: the private message carries no pointer payload.
                unsafe { PostMessageW(target, WM_APP_SHOW_DEFERRED_MESSAGE, 0, 0) != 0 }
            },
            |target| {
                // SAFETY: this pointer-free timer belongs to the live owner.
                unsafe { SetTimer(target, DEFERRED_MESSAGE_TIMER_ID, 1, None) != 0 }
            },
        );
    }
    if message == WM_NCDESTROY {
        discard_deferred_messages(window);
        if !state_slot.is_null() {
            // SAFETY: this final callback owns the publication slot. Clearing it
            // prevents any nested or queued callback from reaching the state.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
            // SAFETY: all timer identifiers belong to this exact top-level window;
            // killing absent timers is harmless during defensive teardown.
            unsafe {
                KillTimer(window, APPLY_POLL_TIMER_ID);
                KillTimer(window, PREFERENCES_POLL_TIMER_ID);
                KillTimer(window, STATUS_RENDER_TIMER_ID);
                KillTimer(window, DEFERRED_MESSAGE_TIMER_ID);
            }
            // SAFETY: the slot is still live. Its sidecar is disjoint from a
            // possibly leased AppState value and is taken at most once.
            drop(unsafe { CallbackState::take_retirement(state_slot) });
            // SAFETY: publication was cleared above. An outer callback lease, if
            // present, defers the unique Box reclamation until its reference ends.
            unsafe { CallbackState::request_reclaim(state_slot) };
        }
        // SAFETY: arguments are unchanged values from the final callback.
        return unsafe { DefWindowProcW(window, message, wparam, lparam) };
    }
    if repaints_menu_bottom_edge(message) {
        // The scalar color sidecar is disjoint from AppState and remains
        // readable during a nested modal callback's value lease. Copy it
        // before default processing, which may synchronously destroy the HWND.
        // SAFETY: state_slot is either null or the live UI-thread publication;
        // this method touches only its scalar sidecar and never AppState.
        let color = unsafe { CallbackState::menu_edge_color(state_slot) };
        // SAFETY: arguments are unchanged copied values from this active
        // non-client callback. Its return value remains authoritative.
        let result = unsafe { DefWindowProcW(window, message, wparam, lparam) };
        if let Some(color) = color {
            // No state-slot access occurs after default processing; an HWND
            // destroyed during that call makes the best-effort GDI queries fail.
            paint_menu_bottom_edge(window, color);
        }
        return result;
    }
    // SAFETY: the slot is the current UI-thread publication and remains live
    // until this callback either releases or defers reclamation of its lease.
    let Some(mut state_lease) = (unsafe { CallbackState::try_lease(state_slot) }) else {
        if message == WM_DESTROY {
            // SAFETY: same-state reentry cannot access AppState, but the OLE
            // registration sidecar is disjoint and must be revoked now.
            drop(unsafe { CallbackState::take_retirement(state_slot) });
            // SAFETY: the window is being destroyed during another callback;
            // ending the UI loop requires no state reference.
            unsafe { PostQuitMessage(0) };
            return 0;
        }
        if suppresses_busy_callback_message(message) {
            return 0;
        }
        // SAFETY: a same-state nested entry must not construct another Rust
        // reference. Standard handling receives only copied callback arguments.
        return unsafe { DefWindowProcW(window, message, wparam, lparam) };
    };
    let state_ptr = state_lease.state_mut() as *mut AppState;
    match message {
        WM_CREATE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the non-null Box::into_raw AppState stored for
            // this HWND and remains exclusively owned by this callback thread.
            if create_children(window, unsafe { &mut *state_ptr }).is_err() {
                return -1;
            }
            // Copy child hit surfaces in a tiny borrow, then release it before
            // RegisterDragDrop can enter OLE.
            // SAFETY: state_ptr is live UI-thread state for this callback.
            let (list, overlay) = unsafe {
                let state = &*state_ptr;
                (state.list_window, state.drop_overlay)
            };
            if register_drop_targets(list, overlay, window, state_slot).is_err() {
                return -1;
            }
            // SAFETY: child creation succeeded and this callback retains the
            // allocation's sole AppState lease.
            start_preferences_writers(window, unsafe { &mut *state_ptr });
            // SetWindowPos can synchronously reenter the callback graph. The
            // copied ListView HWND is sufficient for the z-order repair, so end
            // the AppState lease before placing it behind every direct sibling.
            drop(state_lease);
            if place_list_view_below_siblings(list).is_err() {
                -1
            } else {
                0
            }
        }
        WM_SIZE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is non-null window-owned AppState storage and no
            // mutable reference exists while this shared layout borrow is live.
            arrange(window, unsafe { &mut *state_ptr });
            0
        }
        WM_SETFOCUS if !state_ptr.is_null() => {
            // SAFETY: this callback owns the sole state lease.
            let target = restored_focus_target(window, unsafe { &mut *state_ptr });
            drop(state_lease);
            if let Some(target) = target {
                apply_focus_target(target);
            }
            0
        }
        WM_APP_RESTORE_FOCUS if !state_ptr.is_null() => {
            let requested = wparam as HWND;
            let target = if requested.is_null() {
                // SAFETY: this callback owns the sole state lease.
                restored_focus_target(window, unsafe { &mut *state_ptr })
            } else {
                valid_focus_target(window, requested).then_some(requested)
            };
            drop(state_lease);
            if let Some(target) = target {
                apply_focus_target(target);
            }
            0
        }
        WM_APP_FINISH_CLOSE if !state_ptr.is_null() => {
            // SAFETY: the callback owns the sole AppState lease. The boolean
            // decision contains no borrowed state.
            let close = prepare_window_close(window, unsafe { &mut *state_ptr });
            drop(state_lease);
            if close {
                // SAFETY: the state lease and its AppState reference ended
                // before synchronous WM_DESTROY/WM_NCDESTROY reentry.
                unsafe { DestroyWindow(window) };
            }
            0
        }
        WM_APP_LAYOUT if !state_ptr.is_null() => {
            // SAFETY: this posted pointer-free callback begins after the
            // state mutation that requested it has returned.
            arrange(window, unsafe { &mut *state_ptr });
            0
        }
        WM_APP_MENU_REDRAW if !state_ptr.is_null() => {
            // DrawMenuBar synchronously sends owner-draw measurement and paint
            // callbacks. End the current state lease first so those nested
            // callbacks can acquire their own non-aliasing lease.
            // SAFETY: this callback owns the sole AppState lease. The unattached
            // menu, when present, transfers out exactly once; otherwise only the
            // window-owned raw handle is copied.
            let (pending, attached) = unsafe {
                let state = &mut *state_ptr;
                let pending = state.pending_menu.take();
                if pending.is_some() {
                    state.menu = null_mut();
                }
                (pending, state.menu)
            };
            drop(state_lease);
            let menu = if let Some(pending) = pending {
                match pending.attach(window) {
                    Ok(menu) => {
                        if let Some(mut lease) = try_app_state(window) {
                            lease.state_mut().menu = menu;
                        }
                        menu
                    }
                    Err(error) => {
                        super::message(
                            window,
                            &format!("메뉴를 화면에 표시하지 못했습니다: {error}"),
                            "DarkReNamer - 시작 실패",
                        );
                        // SAFETY: no state lease remains. Normal destruction owns
                        // child, menu, and AppState cleanup exactly once.
                        unsafe { DestroyWindow(window) };
                        return 0;
                    }
                }
            } else {
                attached
            };
            if !menu.is_null() {
                // SAFETY: window is the live top-level owner and menu is attached.
                unsafe { DrawMenuBar(window) };
            }
            0
        }
        WM_APP_EMPTY_SAFETY_COPY if !state_ptr.is_null() => {
            handle_empty_safety_copy(state_lease, wparam)
        }
        WM_TIMER if !state_ptr.is_null() && wparam == STATUS_RENDER_TIMER_ID => {
            handle_status_render_timer(window, state_lease)
        }
        WM_GETMINMAXINFO if !state_ptr.is_null() => {
            let info = lparam as *mut MINMAXINFO;
            if !info.is_null() {
                // SAFETY: state_ptr is the live AppState. Query failure leaves
                // the operating system's current tracking bounds unchanged.
                if let Ok(minimum) = effective_minimum_track_size(window, unsafe { &*state_ptr }) {
                    // SAFETY: WM_GETMINMAXINFO supplies writable MINMAXINFO
                    // storage for the duration of this callback.
                    unsafe {
                        (*info).ptMinTrackSize.x = minimum.width;
                        (*info).ptMinTrackSize.y = minimum.height;
                    }
                }
            }
            0
        }
        WM_DPICHANGED if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            let state = unsafe { &mut *state_ptr };
            let dpi = u32::try_from(wparam & 0xFFFF).unwrap_or(BASE_DPI);
            state.dpi = dpi.max(BASE_DPI);
            refresh_system_fonts(state);
            let suggested = lparam as *const RECT;
            if !suggested.is_null() {
                // SAFETY: WM_DPICHANGED supplies a readable suggested RECT for
                // this callback and SetWindowPos consumes copied coordinates.
                let suggested = unsafe { *suggested };
                // SAFETY: window is the live callback HWND and suggested is a
                // copied RECT supplied for this WM_DPICHANGED callback.
                unsafe {
                    SetWindowPos(
                        window,
                        null_mut(),
                        suggested.left,
                        suggested.top,
                        suggested.right - suggested.left,
                        suggested.bottom - suggested.top,
                        SWP_NOZORDER | SWP_NOACTIVATE,
                    )
                };
            }
            update_dpi_metrics(state);
            if let Err(error) = ensure_minimum_track_size(window, state) {
                super::message(
                    window,
                    &format!("새 DPI의 최소 창 크기를 적용하지 못했습니다: {error}"),
                    "DarkReNamer - 표시 설정",
                );
            }
            arrange(window, state);
            0
        }
        WM_SETTINGCHANGE | WM_THEMECHANGED | WM_SYSCOLORCHANGE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState.
            let state = unsafe { &mut *state_ptr };
            refresh_forced_colors(state);
            refresh_system_theme(state);
            notify_appearance_dialog_accessibility(state);
            apply_native_appearance_nonblocking(window, state);
            refresh_system_fonts(state);
            update_dpi_metrics(state);
            if let Err(error) = ensure_minimum_track_size(window, state) {
                super::message(
                    window,
                    &format!("새 표시 설정의 최소 창 크기를 적용하지 못했습니다: {error}"),
                    "DarkReNamer - 표시 설정",
                );
            }
            update_controls(state);
            arrange(window, state);
            0
        }
        WM_APP_APPEARANCE_PREVIEW if !state_ptr.is_null() => {
            // SAFETY: scalar payloads are validated before updating live state.
            let state = unsafe { &mut *state_ptr };
            if handle_appearance_preview(state, wparam, lparam) {
                apply_native_appearance_nonblocking(window, state);
                update_controls(state);
                arrange(window, state);
            }
            0
        }
        WM_APP_APPEARANCE_FINISH if !state_ptr.is_null() => {
            let released_session = {
                // SAFETY: scalar payload/session ID are validated by the finish seam.
                let state = unsafe { &mut *state_ptr };
                let released = finish_appearance_dialog(window, state, wparam, lparam);
                if released.is_some() {
                    if let Err(error) = ensure_minimum_track_size(window, state) {
                        state.set_transient_status(format!(
                            "모양 설정의 최소 창 크기를 적용하지 못했습니다: {error}"
                        ));
                    }
                    arrange(window, state);
                }
                released
            };
            // Dropping may synchronously restore owner focus, so it occurs only
            // after the AppState borrow above has ended.
            drop(released_session);
            0
        }
        WM_FONTCHANGE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState.
            let state = unsafe { &mut *state_ptr };
            refresh_system_fonts(state);
            update_dpi_metrics(state);
            if let Err(error) = ensure_minimum_track_size(window, state) {
                super::message(
                    window,
                    &format!("새 글꼴의 최소 창 크기를 적용하지 못했습니다: {error}"),
                    "DarkReNamer - 글꼴 설정",
                );
            }
            arrange(window, state);
            0
        }
        WM_APP_APPLY_PROGRESS if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            handle_apply_progress(unsafe { &mut *state_ptr });
            0
        }
        WM_APP_APPLY_COMPLETE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            handle_apply_completion(window, unsafe { &mut *state_ptr });
            0
        }
        WM_APP_PLAN_COMPLETE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            let prepared = handle_plan_completion(window, unsafe { &mut *state_ptr });
            run_prepared_worker_task_dialog_after_state_release(
                state_lease,
                window,
                prepared,
                select_prepared_task_dialog,
            );
            0
        }
        WM_APP_ADMISSION_COMPLETE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            let prepared = handle_admission_completion(window, unsafe { &mut *state_ptr });
            run_prepared_worker_task_dialog_after_state_release(
                state_lease,
                window,
                prepared,
                select_prepared_task_dialog,
            );
            0
        }
        WM_APP_ADMISSION_STARTED if !state_ptr.is_null() => {
            // SAFETY: the posted handoff re-resolves live UI-thread state after
            // the OLE Drop callback and its AppState borrow have ended.
            finalize_admission_start(unsafe { &mut *state_ptr });
            0
        }
        WM_APP_PREFERENCES_WAKE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            handle_preferences_wake(window, unsafe { &mut *state_ptr });
            0
        }
        WM_TIMER if !state_ptr.is_null() && wparam == PREFERENCES_POLL_TIMER_ID => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            handle_preferences_wake(window, unsafe { &mut *state_ptr });
            0
        }
        WM_TIMER if !state_ptr.is_null() && wparam == APPLY_POLL_TIMER_ID => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            let state = unsafe { &mut *state_ptr };
            if state
                .admission_worker
                .as_ref()
                .is_some_and(|worker| worker.handle.is_finished())
            {
                let prepared = handle_admission_completion(window, state);
                run_prepared_worker_task_dialog_after_state_release(
                    state_lease,
                    window,
                    prepared,
                    select_prepared_task_dialog,
                );
                return 0;
            }
            if state
                .plan_worker
                .as_ref()
                .is_some_and(|worker| worker.handle.is_finished())
            {
                let prepared = handle_plan_completion(window, state);
                run_prepared_worker_task_dialog_after_state_release(
                    state_lease,
                    window,
                    prepared,
                    select_prepared_task_dialog,
                );
                return 0;
            }
            handle_apply_progress(state);
            if state
                .apply_worker
                .as_ref()
                .is_some_and(|worker| worker.handle.is_finished())
            {
                handle_apply_completion(window, state);
            }
            0
        }
        WM_CLOSE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            let state = unsafe { &mut *state_ptr };
            cancel_appearance_dialog(window, state);
            request_window_close(window, state);
            0
        }
        WM_ERASEBKGND if !state_ptr.is_null() => {
            // SAFETY: state_ptr is live UI-thread state and wparam is the
            // callback-owned paint DC for this exact top-level window.
            let (resources, status_chrome, workspace_chrome) = unsafe {
                let state = &*state_ptr;
                (
                    state.appearance_resources.as_ref(),
                    state.status_chrome,
                    state.workspace_chrome,
                )
            };
            erase_themed_background(
                window,
                wparam as HDC,
                resources,
                status_chrome,
                workspace_chrome,
            );
            1
        }
        WM_DRAWITEM if !state_ptr.is_null() => {
            // SAFETY: state_ptr is live UI-thread state and the renderer reads
            // only the synchronous WM_DRAWITEM payload.
            let state = unsafe { &*state_ptr };
            let resources = state.appearance_resources.as_ref();
            let apply_readiness_button = state
                .left_rail
                .as_ref()
                .and_then(CommandRail::active_apply_readiness_button)
                .or_else(|| {
                    state
                        .right_rail
                        .as_ref()
                        .and_then(CommandRail::active_apply_readiness_button)
                });
            if draw_owner_rail_button(resources, apply_readiness_button, state.dpi, lparam)
                || state
                    .left_rail
                    .as_ref()
                    .is_some_and(|rail| rail.draw_separator(resources, lparam))
                || state
                    .right_rail
                    .as_ref()
                    .is_some_and(|rail| rail.draw_separator(resources, lparam))
                || draw_owner_menu(resources, state.font.as_raw(), state.dpi, lparam)
            {
                return 1;
            }
            // SAFETY: unrecognized owner-draw payloads retain system handling.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
        WM_MEASUREITEM if !state_ptr.is_null() => {
            // SAFETY: state_ptr is live UI-thread state and lparam is the
            // synchronous writable measurement payload.
            let state = unsafe { &*state_ptr };
            if measure_owner_menu(window, state.font.as_raw(), state.dpi, lparam) {
                1
            } else {
                // SAFETY: unrecognized measurement retains system handling.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_MENUCHAR if !state_ptr.is_null() => handle_owner_menu_char(wparam, lparam),
        WM_CTLCOLORSTATIC if !state_ptr.is_null() => {
            let child = lparam as HWND;
            // Copy all routing values in a tiny borrow that ends before any GDI
            // call.
            // SAFETY: state_ptr is live UI-thread state for this callback.
            let (custom_colors, instruction, safety, status_message, status_count) = unsafe {
                let state = &*state_ptr;
                (
                    static_control_colors(state, child),
                    state.empty_instruction,
                    state.empty_safety,
                    state.status_message,
                    state.status_count,
                )
            };
            if let Some(brush) = route_static_control_colors(
                custom_colors,
                instruction,
                safety,
                status_message,
                status_count,
                child,
                wparam as HDC,
            ) {
                return brush as LRESULT;
            }
            // SAFETY: unrecognized STATIC children retain the system default
            // color handling with the original message arguments.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
        WM_COMMAND if !state_ptr.is_null() => {
            let command = (wparam & 0xFFFF) as u16;
            let notification = u32::try_from((wparam >> 16) & 0xFFFF).unwrap_or_default();
            let source = lparam as HWND;
            if command == CANCEL_WORKER_ID {
                // Intercept the dedicated control before the generic mutation
                // lock. It requests only the already-active worker token and
                // never enters command dispatch or an Apply authorization path.
                // SAFETY: state_ptr is the live UI-thread AppState installed in
                // this callback window and is only read for HWND identity here.
                if source == unsafe { (*state_ptr).cancel_worker } && notification == BN_CLICKED {
                    // SAFETY: state_ptr is the live UI-thread AppState and the
                    // source was verified as its dedicated Cancel BUTTON.
                    request_active_worker_cancel(unsafe { &mut *state_ptr });
                }
                return 0;
            }
            if !source.is_null() && notification == BN_SETFOCUS {
                // SAFETY: source is the live command button identified by this
                // synchronous notification and state_ptr is UI-thread confined.
                record_child_focus(unsafe { &mut *state_ptr }, source);
                return 0;
            }
            if !source.is_null() && notification != BN_CLICKED {
                return 0;
            }
            // SAFETY: state_ptr is the non-null, window-thread-confined AppState
            // installed in GWLP_USERDATA and is uniquely borrowed for dispatch.
            let action = dispatch_command(window, unsafe { &mut *state_ptr }, command);
            run_prepared_command_action_after_state_release(
                state_lease,
                window,
                action,
                select_prepared_file_dialog,
                select_prepared_task_dialog,
            );
            0
        }
        WM_NOTIFY if !state_ptr.is_null() => {
            let header = lparam as *const NMHDR;
            if !header.is_null() && programmatic_list_update_active() {
                // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix. This
                // guard runs before constructing any AppState reference, so
                // synchronous Common Controls re-entry cannot alias the
                // mutable state held by the programmatic sender.
                let code = unsafe { (*header).code };
                if matches!(code, LVN_ITEMCHANGED | HDN_ITEMCHANGINGW | HDN_ITEMCHANGEDW) {
                    return 0;
                }
            }
            // SAFETY: this callback owns the sole state lease; only the copied
            // ListView HWND is passed to the source-validating native query.
            let list_window = unsafe { (*state_ptr).list_window };
            if let Some(result) = handle_list_marquee_begin(list_window, lparam) {
                return result;
            }
            // SAFETY: state_ptr is the live UI-thread AppState and the custom
            // draw helper validates the synchronous WM_NOTIFY payload/source.
            if let Some(result) = handle_list_custom_draw(unsafe { &*state_ptr }, lparam) {
                return result;
            }
            // Header controls are ListView children, so their resize
            // notifications identify the header HWND rather than list_window.
            // SAFETY: state_ptr is the live UI-thread AppState and lparam is
            // inspected only for this synchronous WM_NOTIFY callback.
            if handle_header_end_track(unsafe { &mut *state_ptr }, lparam) {
                return 0;
            }
            // SAFETY: same live callback-owned AppState and WM_NOTIFY payload.
            if handle_list_infotip(unsafe { &*state_ptr }, lparam) {
                return 0;
            }
            if !header.is_null()
                // SAFETY: For WM_NOTIFY, non-null lparam points to an NMHDR prefix that remains readable throughout this synchronous callback.
                && unsafe { (*header).hwndFrom } == unsafe { (*state_ptr).list_window }
            {
                // SAFETY: header is the live NMHDR prefix supplied by the
                // ListView for this synchronous notification.
                if unsafe { (*header).code } == NM_SETFOCUS {
                    // SAFETY: state_ptr is live UI-thread state and list_window
                    // is the notification source just validated above.
                    record_child_focus(unsafe { &mut *state_ptr }, unsafe {
                        (*state_ptr).list_window
                    });
                    return 0;
                }
                // SAFETY: For WM_NOTIFY, non-null lparam points to an NMHDR prefix that remains readable throughout this synchronous callback.
                if unsafe { (*header).code } == LVN_ITEMCHANGED {
                    let notification = lparam as *const NMLISTVIEW;
                    if !notification.is_null()
                        && selection_command_state_changed(
                            // SAFETY: For WM_NOTIFY, non-null lparam points to NMLISTVIEW storage owned by the sender for this synchronous callback.
                            unsafe { (*notification).uChanged },
                            // SAFETY: For WM_NOTIFY, non-null lparam points to NMLISTVIEW storage owned by the sender for this synchronous callback.
                            unsafe { (*notification).uOldState },
                            // SAFETY: For WM_NOTIFY, non-null lparam points to NMLISTVIEW storage owned by the sender for this synchronous callback.
                            unsafe { (*notification).uNewState },
                        )
                    {
                        // SAFETY: state_ptr is non-null AppState storage owned by
                        // this callback thread and is uniquely borrowed here.
                        update_controls(unsafe { &mut *state_ptr });
                    }
                // SAFETY: For WM_NOTIFY, non-null lparam points to an NMHDR prefix that remains readable throughout this synchronous callback.
                } else if unsafe { (*header).code } == NM_DBLCLK {
                    // SAFETY: state_ptr is the non-null AppState installed for
                    // this HWND and remains exclusively callback-thread owned.
                    let action =
                        dispatch_command(window, unsafe { &mut *state_ptr }, MANUAL_CHANGE);
                    run_prepared_command_action_after_state_release(
                        state_lease,
                        window,
                        action,
                        select_prepared_file_dialog,
                        select_prepared_task_dialog,
                    );
                    return 0;
                }
            }
            0
        }
        WM_DESTROY => {
            if !state_ptr.is_null() {
                // Stop the ListView from retaining AppState refdata before any
                // child teardown can reenter through common-controls messages.
                // SAFETY: state_ptr is live and UI-thread confined here.
                remove_list_view_notification_subclass(unsafe { (*state_ptr).list_window });
                // SAFETY: defensive owner teardown rolls back and destroys any
                // still-live appearance session before preference shutdown/drop.
                cancel_appearance_dialog(window, unsafe { &mut *state_ptr });
                // Copy overlay identity, then revoke the disjoint OLE sidecar
                // without extending the AppState reference into COM teardown.
                // SAFETY: this callback owns the sole AppState lease.
                let overlay = unsafe { (*state_ptr).drop_overlay };
                // SAFETY: the sidecar is UI-thread confined, disjoint from the
                // leased state value, and taken at most once.
                let registrations = unsafe { CallbackState::take_retirement(state_slot) };
                set_drop_overlay_control(overlay, DropPresentation::Inactive);
                drop(registrations);
                // Destroy tooltip windows before their CommandRail-owned text
                // buffers are released, then destroy the direct child buttons.
                // SAFETY: state_ptr is the live window-thread AppState and this
                // message is its single deterministic command-rail teardown.
                if let Some(rail) = unsafe { (&mut *state_ptr).left_rail.take() } {
                    rail.destroy();
                }
                // SAFETY: same exclusive AppState access as the left rail above.
                if let Some(rail) = unsafe { (&mut *state_ptr).right_rail.take() } {
                    rail.destroy();
                }
            }
            // SAFETY: PostQuitMessage targets the current thread queue and accepts no borrowed pointers.
            unsafe { PostQuitMessage(0) };
            0
        }
        _ => {
            // Default handling can synchronously enter native menu, focus, and
            // non-client callbacks. Release AppState before that reentry so the
            // nested callback can acquire its own lease without aliasing.
            drop(state_lease);
            // SAFETY: window, message, wparam, and lparam are unchanged copied
            // values from the active Windows callback.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
    }
}

pub(super) fn route_static_control_colors(
    custom_colors: Option<StaticControlColors>,
    empty_instruction: HWND,
    empty_safety: HWND,
    status_message: HWND,
    status_count: HWND,
    child: HWND,
    dc: HDC,
) -> Option<HBRUSH> {
    if let Some(colors) = custom_colors {
        // SAFETY: WM_CTLCOLORSTATIC supplies a live HDC. AppState owns the
        // selected brush through this synchronous paint callback.
        unsafe {
            SetTextColor(dc, colors.text);
            SetBkColor(dc, colors.background);
        }
        return Some(colors.brush);
    }
    if child != empty_instruction
        && child != empty_safety
        && child != status_message
        && child != status_count
    {
        return None;
    }
    // SAFETY: WM_CTLCOLORSTATIC supplies a live HDC. System colors and the
    // cached system brush automatically follow high-contrast/theme changes.
    unsafe {
        SetTextColor(dc, GetSysColor(COLOR_WINDOWTEXT));
        SetBkColor(dc, GetSysColor(COLOR_WINDOW));
        Some(GetSysColorBrush(COLOR_WINDOW))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FILE_DIALOG_DRAWITEM_SUBCLASS_ID: usize = 0xD4B4;
    static FILE_DIALOG_DRAWITEM_LEASED: AtomicBool = AtomicBool::new(false);

    fn send_synthetic_drawitem(owner: HWND) {
        // SAFETY: tests pass their live, test-owned top-level window and the
        // synchronous message contains no pointer payload.
        unsafe { SendMessageW(owner, WM_DRAWITEM, 0, 0) };
    }

    extern "system" fn file_dialog_drawitem_probe(
        window: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        subclass_id: usize,
        ref_data: usize,
    ) -> LRESULT {
        if subclass_id == FILE_DIALOG_DRAWITEM_SUBCLASS_ID && message == WM_DRAWITEM {
            let slot = ref_data as *mut AppStateSlot;
            // SAFETY: the subclass refdata is the live test-owned publication
            // slot and this synchronous callback does not outlive the owner.
            if let Some(lease) = unsafe { CallbackState::try_lease(slot) } {
                FILE_DIALOG_DRAWITEM_LEASED.store(true, Ordering::SeqCst);
                drop(lease);
                return 1;
            }
        }
        // SAFETY: unchanged callback arguments are forwarded exactly once to
        // the system-owned subclass chain.
        unsafe { DefSubclassProc(window, message, wparam, lparam) }
    }

    struct PublishedFileDialogTestApp {
        owner: HWND,
        slot: *mut AppStateSlot,
        _directory: tempfile::TempDir,
    }

    impl PublishedFileDialogTestApp {
        fn new() -> Result<Self, Box<dyn std::error::Error>> {
            let directory = tempfile::tempdir()?;
            let state = AppState::new(initialize_safe_runtime_at(directory.path())?);
            let controls = INITCOMMONCONTROLSEX {
                dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
                dwICC: ICC_LISTVIEW_CLASSES | ICC_WIN95_CLASSES,
            };
            // SAFETY: controls has the exact ABI size and remains live for the
            // synchronous process-wide common-controls initialization call.
            unsafe { InitCommonControlsEx(&controls) };
            let class = wide("STATIC");
            // SAFETY: the system STATIC class and current module remain live
            // for this hidden, test-owned top-level window.
            let owner = unsafe {
                CreateWindowExW(
                    0,
                    class.as_ptr(),
                    null(),
                    WS_OVERLAPPEDWINDOW,
                    0,
                    0,
                    640,
                    480,
                    null_mut(),
                    null_mut(),
                    GetModuleHandleW(null()),
                    null_mut(),
                )
            };
            if owner.is_null() {
                return Err(io::Error::last_os_error().into());
            }
            let slot: *mut AppStateSlot = CallbackState::into_raw(state);
            // SAFETY: owner and slot are test-owned and remain live until Drop.
            unsafe { SetWindowLongPtrW(owner, GWLP_USERDATA, slot as isize) };
            let app = Self {
                owner,
                slot,
                _directory: directory,
            };
            // SAFETY: owner and slot remain live through app Drop, which
            // removes this exact subclass before destroying the window.
            if unsafe {
                SetWindowSubclass(
                    owner,
                    Some(file_dialog_drawitem_probe),
                    FILE_DIALOG_DRAWITEM_SUBCLASS_ID,
                    slot as usize,
                )
            } == 0
            {
                return Err(io::Error::last_os_error().into());
            }
            app.with_state(|state| create_children(owner, state))??;
            Ok(app)
        }

        fn lease(&self) -> io::Result<CallbackStateLease<AppState, DropTargetRegistrations>> {
            // SAFETY: this test owns the published UI-thread slot and callers
            // never request another lease while the returned value is live.
            unsafe { CallbackState::try_lease(self.slot) }
                .ok_or_else(|| io::Error::other("test AppState lease is unavailable"))
        }

        fn with_state<R>(&self, action: impl FnOnce(&mut AppState) -> R) -> io::Result<R> {
            let mut lease = self.lease()?;
            let result = action(lease.state_mut());
            drop(lease);
            Ok(result)
        }

        fn prepare(&self, command: u16) -> io::Result<PreparedCommandAction> {
            self.with_state(|state| dispatch_command(self.owner, state, command))?
                .ok_or_else(|| io::Error::other("file command prepared no action"))
        }

        fn dispatch_with_selector(
            &self,
            command: u16,
            selector: impl FnOnce(HWND, PreparedFileDialogKind) -> PreparedFileDialogSelection,
        ) -> io::Result<()> {
            // SAFETY: this test owns the published UI-thread slot and ends this
            // dispatch lease through the production application seam.
            let mut lease = self.lease()?;
            let action = dispatch_command(self.owner, lease.state_mut(), command);
            run_prepared_command_action_after_state_release(
                lease,
                self.owner,
                action,
                selector,
                select_prepared_task_dialog,
            )
            .ok_or_else(|| io::Error::other("file command prepared no action"))?;
            Ok(())
        }

        fn dispatch_task_with_selector(
            &self,
            command: u16,
            selector: impl FnOnce(HWND, &PreparedTaskDialogSpec) -> io::Result<i32>,
        ) -> io::Result<()> {
            // SAFETY: this test owns the published UI-thread slot and ends this
            // dispatch lease through the production application seam.
            let mut lease = self.lease()?;
            let action = dispatch_command(self.owner, lease.state_mut(), command);
            run_prepared_command_action_after_state_release(
                lease,
                self.owner,
                action,
                select_prepared_file_dialog,
                selector,
            )
            .ok_or_else(|| io::Error::other("task-dialog command prepared no action"))?;
            Ok(())
        }

        fn install_staged_intent(&self) -> Result<(PathBuf, Vec<u8>), Box<dyn std::error::Error>> {
            self.with_state(
                |state| -> Result<(PathBuf, Vec<u8>), Box<dyn std::error::Error>> {
                    let journal = FileJournal::create_candidate(
                        &state.journal_root,
                        CANDIDATE_JOURNAL_LEAF,
                        ACTIVE_JOURNAL_LEAF,
                    )?;
                    let step = crate::rename::JournalStep::new(
                        crate::rename::EntryId::new(1),
                        LegacyText::from(r"C:\fixture\before.txt"),
                        LegacyText::from(r"C:\fixture\after.txt"),
                        crate::rename::EntryIdentity::new(7, 11),
                        crate::rename::EntryIdentity::new(7, 1),
                        crate::rename::EntryIdentity::new(7, 1),
                        crate::rename::TemporaryPhase::None,
                    );
                    let path = journal.path().to_path_buf();
                    drop(journal);
                    let bytes = crate::rename::encode_journal_records(&[
                        crate::rename::JournalRecord::Intent {
                            plan: crate::rename::PlanId::from_fingerprint(7),
                            steps: vec![step].into_boxed_slice(),
                        },
                    ])?;
                    fs::write(&path, &bytes)?;
                    let journal = FileJournal::open_candidate_existing_retained(
                        &state.journal_root,
                        CANDIDATE_JOURNAL_LEAF,
                        ACTIVE_JOURNAL_LEAF,
                    )?;
                    state.staged_journal = Some(journal);
                    state.recovery_locked = true;
                    update_controls(state);
                    Ok((path, bytes))
                },
            )?
        }

        fn drain_admission(&self) -> io::Result<()> {
            for _ in 0..200 {
                let finished = self.with_state(|state| {
                    state
                        .admission_worker
                        .as_ref()
                        .is_some_and(|worker| worker.handle.is_finished())
                })?;
                if finished {
                    self.with_state(|state| handle_admission_completion(self.owner, state))?;
                    return Ok(());
                }
                if self.with_state(|state| state.admission_worker.is_none())? {
                    return Ok(());
                }
                thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(io::Error::other("admission worker did not finish"))
        }

        fn finish_directory_admission_with_selector(
            &self,
            selector: impl FnOnce(HWND, &PreparedTaskDialogSpec) -> io::Result<i32>,
        ) -> io::Result<()> {
            for _ in 0..200 {
                // SAFETY: the test owns the published UI-thread slot. The
                // production wrapper releases this lease before selection.
                let mut lease = self.lease()?;
                let finished = lease
                    .state()
                    .admission_worker
                    .as_ref()
                    .is_some_and(|worker| worker.handle.is_finished());
                if finished {
                    let prepared = handle_admission_completion(self.owner, lease.state_mut());
                    run_prepared_worker_task_dialog_after_state_release(
                        lease, self.owner, prepared, selector,
                    );
                    return Ok(());
                }
                drop(lease);
                thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(io::Error::other(
                "directory admission worker did not finish",
            ))
        }

        fn finish_plan_with_selector(
            &self,
            selector: impl FnOnce(HWND, &PreparedTaskDialogSpec) -> io::Result<i32>,
        ) -> io::Result<()> {
            for _ in 0..400 {
                // SAFETY: the test owns the published UI-thread slot. The
                // production wrapper releases this lease before selection.
                let mut lease = self.lease()?;
                let finished = lease
                    .state()
                    .plan_worker
                    .as_ref()
                    .is_some_and(|worker| worker.handle.is_finished());
                if finished {
                    let prepared = handle_plan_completion(self.owner, lease.state_mut());
                    run_prepared_worker_task_dialog_after_state_release(
                        lease, self.owner, prepared, selector,
                    );
                    return Ok(());
                }
                drop(lease);
                thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(io::Error::other("plan worker did not finish"))
        }

        fn drain_apply(&self) -> io::Result<()> {
            for _ in 0..400 {
                let finished = self.with_state(|state| {
                    state
                        .apply_worker
                        .as_ref()
                        .is_some_and(|worker| worker.handle.is_finished())
                })?;
                if finished {
                    self.with_state(|state| handle_apply_completion(self.owner, state))?;
                    return Ok(());
                }
                thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(io::Error::other("apply worker did not finish"))
        }

        fn assert_session_cleared(&self) -> io::Result<()> {
            let active = self.with_state(|state| state.active_prompt)?;
            if active.is_some() {
                Err(io::Error::other("file-dialog session was not cleared"))
            } else {
                Ok(())
            }
        }
    }

    impl Drop for PublishedFileDialogTestApp {
        fn drop(&mut self) {
            // A failed assertion or timeout can leave a test admission worker
            // live. Join it while the owner HWND is still published so its
            // completion wake cannot target a later recycled test window.
            finish_apply_after_message_loop_failure(self.owner);
            // SAFETY: Drop owns the published slot and window. It mirrors the
            // production child cleanup order before unpublishing and reclaiming.
            unsafe {
                if let Some(mut lease) = CallbackState::try_lease(self.slot) {
                    let state = lease.state_mut();
                    remove_list_view_notification_subclass(state.list_window);
                    if let Some(rail) = state.left_rail.take() {
                        rail.destroy();
                    }
                    if let Some(rail) = state.right_rail.take() {
                        rail.destroy();
                    }
                    drop(lease);
                }
                RemoveWindowSubclass(
                    self.owner,
                    Some(file_dialog_drawitem_probe),
                    FILE_DIALOG_DRAWITEM_SUBCLASS_ID,
                );
                SetWindowLongPtrW(self.owner, GWLP_USERDATA, 0);
                DestroyWindow(self.owner);
                discard_deferred_messages(self.owner);
                let _disposition = CallbackState::request_reclaim(self.slot);
            }
        }
    }

    #[test]
    fn real_file_dialog_pipeline_routes_all_commands_and_cleans_sessions()
    -> Result<(), Box<dyn std::error::Error>> {
        let app = PublishedFileDialogTestApp::new()?;
        FILE_DIALOG_DRAWITEM_LEASED.store(false, Ordering::SeqCst);
        app.dispatch_with_selector(ADD_FILES, |owner, kind| {
            assert!(matches!(kind, PreparedFileDialogKind::AddFiles));
            // SAFETY: owner is the live test window. The synchronous subclass
            // callback attempts the same AppState lease as production drawing.
            send_synthetic_drawitem(owner);
            PreparedFileDialogSelection::Cancelled
        })?;
        assert!(FILE_DIALOG_DRAWITEM_LEASED.load(Ordering::SeqCst));
        app.assert_session_cleared()?;

        app.dispatch_with_selector(ADD_FILES, |_, kind| {
            assert!(matches!(kind, PreparedFileDialogKind::AddFiles));
            PreparedFileDialogSelection::AddFiles(Vec::new())
        })?;
        app.assert_session_cleared()?;
        app.drain_admission()?;

        for (command, names, leaf) in [
            (SAVE_NAMES, true, "saved-names.txt"),
            (SAVE_PATHS, false, "saved-paths.txt"),
        ] {
            let output = app._directory.path().join(leaf);
            app.dispatch_with_selector(command, |_, kind| match kind {
                PreparedFileDialogKind::SaveText {
                    text,
                    names: actual,
                } if actual == names => PreparedFileDialogSelection::SaveText {
                    path: output.clone(),
                    text,
                },
                _ => PreparedFileDialogSelection::Cancelled,
            })?;
            assert!(output.is_file());
            app.assert_session_cleared()?;
        }

        let imported_names = app._directory.path().join("import-names.txt");
        write_legacy_text(&imported_names, &LegacyText::from("name.txt"))?;
        app.dispatch_with_selector(IMPORT_NAMES, |_, kind| {
            assert!(matches!(kind, PreparedFileDialogKind::ImportNames));
            PreparedFileDialogSelection::ImportNames(imported_names)
        })?;
        app.assert_session_cleared()?;

        let imported_paths = app._directory.path().join("import-paths.txt");
        write_legacy_text(&imported_paths, &LegacyText::default())?;
        app.dispatch_with_selector(IMPORT_PATHS, |_, kind| {
            assert!(matches!(kind, PreparedFileDialogKind::ImportPaths));
            PreparedFileDialogSelection::ImportPaths(imported_paths)
        })?;
        app.assert_session_cleared()?;
        app.drain_admission()?;
        Ok(())
    }

    #[test]
    fn real_file_dialog_pipeline_rejects_stale_locked_and_mismatched_sessions()
    -> Result<(), Box<dyn std::error::Error>> {
        #[derive(Clone, Copy)]
        enum Blocker {
            StaleRevision,
            Close,
            ReadOnly,
            Mutation,
            Worker,
        }

        for blocker in [
            Blocker::StaleRevision,
            Blocker::Close,
            Blocker::ReadOnly,
            Blocker::Mutation,
            Blocker::Worker,
        ] {
            let app = PublishedFileDialogTestApp::new()?;
            let action = app.prepare(SAVE_PATHS)?;
            app.with_state(|state| match blocker {
                Blocker::StaleRevision => state.model_revision += 1,
                Blocker::Close => state.close_pending = true,
                Blocker::ReadOnly => state.recovery_locked = true,
                Blocker::Mutation => state.mutation_locked = true,
                Blocker::Worker => {
                    let started = admit_paths(app.owner, state, Vec::new());
                    assert!(started.is_ok());
                    finalize_admission_start(state);
                }
            })?;
            let selector_called = Cell::new(false);
            run_prepared_command_action(
                app.owner,
                action,
                |_, _| {
                    selector_called.set(true);
                    PreparedFileDialogSelection::Cancelled
                },
                select_prepared_task_dialog,
            );
            assert!(!selector_called.get());
            app.assert_session_cleared()?;
            if matches!(blocker, Blocker::Worker) {
                app.drain_admission()?;
            }
        }

        // Revalidate after the modal boundary as well as before it. Each
        // selector changes state only after the production runner has accepted
        // the prepared session, then returns an otherwise valid save result.
        for blocker in [
            Blocker::StaleRevision,
            Blocker::Close,
            Blocker::ReadOnly,
            Blocker::Mutation,
            Blocker::Worker,
        ] {
            let app = PublishedFileDialogTestApp::new()?;
            let output = app._directory.path().join("stale-modal-result.txt");
            let expected_kind = Cell::new(false);
            app.dispatch_with_selector(SAVE_PATHS, |_, kind| {
                let text = match kind {
                    PreparedFileDialogKind::SaveText { text, names: false } => {
                        expected_kind.set(true);
                        text
                    }
                    _ => LegacyText::default(),
                };
                assert!(
                    app.with_state(|state| match blocker {
                        Blocker::StaleRevision => state.model_revision += 1,
                        Blocker::Close => state.close_pending = true,
                        Blocker::ReadOnly => state.recovery_locked = true,
                        Blocker::Mutation => state.mutation_locked = true,
                        Blocker::Worker => {
                            let started = admit_paths(app.owner, state, Vec::new());
                            assert!(started.is_ok());
                            finalize_admission_start(state);
                        }
                    })
                    .is_ok()
                );
                PreparedFileDialogSelection::SaveText {
                    path: output.clone(),
                    text,
                }
            })?;
            assert!(expected_kind.get());
            assert!(!output.exists());
            app.assert_session_cleared()?;
            if matches!(blocker, Blocker::Close) {
                assert!(app.with_state(|state| state.close_pending)?);
            }
            if matches!(blocker, Blocker::Worker) {
                app.drain_admission()?;
            }
        }

        let app = PublishedFileDialogTestApp::new()?;
        let action = app.prepare(SAVE_PATHS)?;
        app.with_state(|state| state.active_prompt = Some(999))?;
        let selector_called = Cell::new(false);
        run_prepared_command_action(
            app.owner,
            action,
            |_, _| {
                selector_called.set(true);
                PreparedFileDialogSelection::Cancelled
            },
            select_prepared_task_dialog,
        );
        assert!(!selector_called.get());
        assert_eq!(app.with_state(|state| state.active_prompt)?, Some(999));

        let app = PublishedFileDialogTestApp::new()?;
        let action = app.prepare(SAVE_PATHS)?;
        let selector_called = Cell::new(false);
        run_prepared_command_action(
            null_mut(),
            action,
            |_, _| {
                selector_called.set(true);
                PreparedFileDialogSelection::Cancelled
            },
            select_prepared_task_dialog,
        );
        assert!(!selector_called.get());
        assert_eq!(app.with_state(|state| state.active_prompt)?, Some(1));
        Ok(())
    }

    #[test]
    fn real_discard_task_dialog_runs_after_release_and_revalidates_the_journal()
    -> Result<(), Box<dyn std::error::Error>> {
        let app = PublishedFileDialogTestApp::new()?;
        let (candidate, _) = app.install_staged_intent()?;
        FILE_DIALOG_DRAWITEM_LEASED.store(false, Ordering::SeqCst);
        app.dispatch_task_with_selector(DISCARD_STAGED_JOURNAL, |owner, spec| {
            assert_eq!(spec.buttons.len(), 1);
            // SAFETY: owner is the live test window. The synchronous callback
            // attempts the production AppState lease during the fake modal.
            send_synthetic_drawitem(owner);
            Ok(IDCANCEL)
        })?;
        assert!(FILE_DIALOG_DRAWITEM_LEASED.load(Ordering::SeqCst));
        app.assert_session_cleared()?;
        assert!(candidate.exists());

        app.dispatch_task_with_selector(DISCARD_STAGED_JOURNAL, |_, _| {
            Err(io::Error::other("injected TaskDialog failure"))
        })?;
        app.assert_session_cleared()?;
        assert!(candidate.exists());

        app.dispatch_task_with_selector(DISCARD_STAGED_JOURNAL, |_, _| {
            app.with_state(|state| state.model_revision += 1)
                .map_err(|error| io::Error::other(error.to_string()))?;
            Ok(DISCARD_CONFIRM_BUTTON_ID)
        })?;
        app.assert_session_cleared()?;
        assert!(candidate.exists());

        app.with_state(|state| state.model_revision -= 1)?;
        #[derive(Clone, Copy)]
        enum PostModalChange {
            Close,
            DialogLockLost,
            SessionChanged,
            WorkerStarted,
        }
        for change in [
            PostModalChange::Close,
            PostModalChange::DialogLockLost,
            PostModalChange::SessionChanged,
            PostModalChange::WorkerStarted,
        ] {
            app.dispatch_task_with_selector(DISCARD_STAGED_JOURNAL, |_, _| {
                app.with_state(|state| match change {
                    PostModalChange::Close => state.close_pending = true,
                    PostModalChange::DialogLockLost => state.mutation_locked = false,
                    PostModalChange::SessionChanged => state.active_prompt = Some(999),
                    PostModalChange::WorkerStarted => {
                        let started = admit_paths(app.owner, state, Vec::new());
                        assert!(started.is_ok());
                        finalize_admission_start(state);
                    }
                })
                .map_err(|error| io::Error::other(error.to_string()))?;
                Ok(DISCARD_CONFIRM_BUTTON_ID)
            })?;
            assert!(candidate.exists());
            if matches!(change, PostModalChange::SessionChanged) {
                assert_eq!(app.with_state(|state| state.active_prompt)?, Some(999));
            } else {
                app.assert_session_cleared()?;
            }
            app.with_state(|state| {
                state.close_pending = false;
                state.active_prompt = None;
                state.confirmation_pending = false;
                if state.admission_worker.is_none() {
                    state.mutation_locked = false;
                }
            })?;
            if matches!(change, PostModalChange::WorkerStarted) {
                app.drain_admission()?;
            }
        }

        app.dispatch_task_with_selector(DISCARD_STAGED_JOURNAL, |_, _| {
            Ok(DISCARD_CONFIRM_BUTTON_ID)
        })?;
        app.assert_session_cleared()?;
        assert!(!candidate.exists());
        Ok(())
    }

    #[test]
    fn real_recovery_export_pipeline_copies_retained_bytes_and_rejects_stale_state()
    -> Result<(), Box<dyn std::error::Error>> {
        let app = PublishedFileDialogTestApp::new()?;
        let (_candidate, expected_bytes) = app.install_staged_intent()?;
        let cancelled = app._directory.path().join("cancelled-export");
        fs::create_dir(&cancelled)?;
        app.dispatch_with_selector(EXPORT_RECOVERY_JOURNAL, |owner, kind| {
            assert!(matches!(
                kind,
                PreparedFileDialogKind::ExportRecoveryJournal
            ));
            send_synthetic_drawitem(owner);
            PreparedFileDialogSelection::Cancelled
        })?;
        app.assert_session_cleared()?;
        assert!(fs::read_dir(&cancelled)?.next().is_none());

        let exported = app._directory.path().join("successful-export");
        fs::create_dir(&exported)?;
        FILE_DIALOG_DRAWITEM_LEASED.store(false, Ordering::SeqCst);
        app.dispatch_with_selector(EXPORT_RECOVERY_JOURNAL, |owner, kind| {
            assert!(matches!(
                kind,
                PreparedFileDialogKind::ExportRecoveryJournal
            ));
            send_synthetic_drawitem(owner);
            PreparedFileDialogSelection::RecoveryExportDirectory(exported.clone())
        })?;
        assert!(FILE_DIALOG_DRAWITEM_LEASED.load(Ordering::SeqCst));
        app.assert_session_cleared()?;
        assert_eq!(
            fs::read(exported.join("candidate.drj.retained"))?,
            expected_bytes
        );
        let presentation = take_deferred_message(app.owner)
            .ok_or_else(|| io::Error::other("recovery export queued no presentation"))?;
        assert_eq!(presentation.caption, "DarkReNamer - 진단 내보내기 완료");

        let partial = app._directory.path().join("partial-export");
        fs::create_dir(&partial)?;
        fs::write(partial.join("candidate.drj.retained"), b"sentinel")?;
        app.dispatch_with_selector(EXPORT_RECOVERY_JOURNAL, |_, _| {
            PreparedFileDialogSelection::RecoveryExportDirectory(partial.clone())
        })?;
        assert_eq!(
            fs::read(partial.join("candidate.drj.retained"))?,
            b"sentinel"
        );
        let presentation = take_deferred_message(app.owner)
            .ok_or_else(|| io::Error::other("partial export queued no presentation"))?;
        assert_eq!(
            presentation.caption,
            "DarkReNamer - 진단 내보내기 일부 실패"
        );

        #[derive(Clone, Copy)]
        enum PostModalChange {
            Revision,
            Close,
            DialogLockLost,
            SessionChanged,
            WorkerStarted,
        }
        for (index, change) in [
            PostModalChange::Revision,
            PostModalChange::Close,
            PostModalChange::DialogLockLost,
            PostModalChange::SessionChanged,
            PostModalChange::WorkerStarted,
        ]
        .into_iter()
        .enumerate()
        {
            let destination = app._directory.path().join(format!("stale-export-{index}"));
            fs::create_dir(&destination)?;
            app.dispatch_with_selector(EXPORT_RECOVERY_JOURNAL, |_, _| {
                assert!(
                    app.with_state(|state| match change {
                        PostModalChange::Revision => state.model_revision += 1,
                        PostModalChange::Close => state.close_pending = true,
                        PostModalChange::DialogLockLost => state.mutation_locked = false,
                        PostModalChange::SessionChanged => state.active_prompt = Some(999),
                        PostModalChange::WorkerStarted => {
                            let started = admit_paths(app.owner, state, Vec::new());
                            assert!(started.is_ok());
                            finalize_admission_start(state);
                        }
                    })
                    .is_ok()
                );
                PreparedFileDialogSelection::RecoveryExportDirectory(destination.clone())
            })?;
            assert!(!destination.join("candidate.drj.retained").exists());
            app.with_state(|state| {
                if matches!(change, PostModalChange::Revision) {
                    state.model_revision -= 1;
                }
                state.close_pending = false;
                state.active_prompt = None;
                state.confirmation_pending = false;
                if state.admission_worker.is_none() {
                    state.mutation_locked = false;
                }
            })?;
            if matches!(change, PostModalChange::WorkerStarted) {
                app.drain_admission()?;
            }
        }

        let identity_app = PublishedFileDialogTestApp::new()?;
        let (_candidate, _) = identity_app.install_staged_intent()?;
        let destination = identity_app._directory.path().join("identity-changed");
        fs::create_dir(&destination)?;
        identity_app.dispatch_with_selector(EXPORT_RECOVERY_JOURNAL, |_, _| {
            assert!(
                identity_app
                    .with_state(|state| state.staged_journal = None)
                    .is_ok()
            );
            PreparedFileDialogSelection::RecoveryExportDirectory(destination.clone())
        })?;
        identity_app.assert_session_cleared()?;
        assert!(!destination.join("candidate.drj.retained").exists());
        Ok(())
    }

    #[test]
    fn real_directory_task_dialog_releases_state_and_restarts_current_admission()
    -> Result<(), Box<dyn std::error::Error>> {
        let app = PublishedFileDialogTestApp::new()?;
        let directory = app._directory.path().join("selected-directory");
        fs::create_dir(&directory)?;
        app.with_state(|state| {
            let started = admit_paths(app.owner, state, vec![directory]);
            assert!(started.is_ok());
            finalize_admission_start(state);
        })?;
        FILE_DIALOG_DRAWITEM_LEASED.store(false, Ordering::SeqCst);
        app.finish_directory_admission_with_selector(|owner, spec| {
            assert_eq!(spec.buttons.len(), 2);
            // SAFETY: owner is live and the synchronous test subclass probes
            // whether the modal runner released AppState.
            send_synthetic_drawitem(owner);
            Ok(DIRECTORY_DIRECT_BUTTON_ID)
        })?;
        assert!(FILE_DIALOG_DRAWITEM_LEASED.load(Ordering::SeqCst));
        app.assert_session_cleared()?;
        assert!(app.with_state(|state| state.admission_worker.is_some())?);
        app.drain_admission()?;

        let directory = app._directory.path().join("stale-directory");
        fs::create_dir(&directory)?;
        app.with_state(|state| {
            let started = admit_paths(app.owner, state, vec![directory]);
            assert!(started.is_ok());
            finalize_admission_start(state);
        })?;
        app.finish_directory_admission_with_selector(|_, _| {
            app.with_state(|state| state.recovery_locked = true)
                .map_err(|error| io::Error::other(error.to_string()))?;
            Ok(DIRECTORY_DIRECT_BUTTON_ID)
        })?;
        app.assert_session_cleared()?;
        assert!(app.with_state(|state| state.admission_worker.is_none())?);
        Ok(())
    }

    #[test]
    fn real_apply_task_dialog_releases_state_and_confirms_the_same_plan()
    -> Result<(), Box<dyn std::error::Error>> {
        let app = PublishedFileDialogTestApp::new()?;
        let source = app._directory.path().join("before.txt");
        let destination = app._directory.path().join("after.txt");
        fs::write(&source, b"fixture")?;
        app.with_state(|state| -> Result<(), ProposalMutationError> {
            let appended =
                state
                    .model
                    .append(LegacyListItem::new(legacy_path(&source), false, 7, 0, 0))?;
            state.commit_known_model_change(appended);
            let changed = state
                .model
                .manual_change_changed(0, LegacyText::from("after.txt"))?;
            state.commit_known_model_change(changed);
            refresh(state);
            update_controls(state);
            Ok(())
        })??;
        app.with_state(|state| apply_changes(app.owner, state))?;
        FILE_DIALOG_DRAWITEM_LEASED.store(false, Ordering::SeqCst);
        app.finish_plan_with_selector(|owner, spec| {
            assert_eq!(spec.buttons.len(), 1);
            // SAFETY: owner is live and the synchronous test subclass probes
            // whether the modal runner released AppState.
            send_synthetic_drawitem(owner);
            Ok(APPLY_CONFIRM_BUTTON_ID)
        })?;
        assert!(FILE_DIALOG_DRAWITEM_LEASED.load(Ordering::SeqCst));
        app.assert_session_cleared()?;
        assert!(app.with_state(|state| state.apply_worker.is_some())?);
        app.drain_apply()?;
        assert!(!source.exists());
        assert!(destination.exists());
        Ok(())
    }

    #[test]
    fn callback_busy_messages_are_owned_until_a_lease_free_callback()
    -> Result<(), Box<dyn std::error::Error>> {
        let app = PublishedFileDialogTestApp::new()?;
        // SAFETY: this test owns the published slot and releases its sole lease
        // before fixture teardown.
        let lease = unsafe { CallbackState::try_lease(app.slot) }
            .ok_or_else(|| io::Error::other("message test lease is unavailable"))?;
        let posted = Cell::new(false);
        assert!(defer_message_if_callback_busy(
            app.owner,
            "deferred text",
            "deferred caption",
            |_| {
                posted.set(true);
                true
            },
        ));
        assert!(posted.get());
        let deferred = take_deferred_message(app.owner)
            .ok_or_else(|| io::Error::other("deferred message was not retained"))?;
        assert_eq!(deferred.text, "deferred text");
        assert_eq!(deferred.caption, "deferred caption");

        assert!(defer_message_if_callback_busy(
            app.owner,
            "discarded text",
            "discarded caption",
            |_| false,
        ));
        assert!(!drain_deferred_messages_if_available(
            app.owner,
            |_, _, _| {}
        ));
        assert!(has_deferred_messages(app.owner));
        drop(lease);
        let recovered = RefCell::new(Vec::new());
        assert!(drain_deferred_messages_if_available(
            app.owner,
            |_, text, caption| recovered
                .borrow_mut()
                .push((text.to_owned(), caption.to_owned()))
        ));
        assert_eq!(
            recovered.into_inner(),
            vec![("discarded text".to_owned(), "discarded caption".to_owned())]
        );
        assert!(!defer_message_if_callback_busy(
            app.owner,
            "immediate text",
            "immediate caption",
            |_| true,
        ));
        Ok(())
    }

    #[test]
    fn deferred_messages_drain_fifo_without_nested_consumption() {
        let owner = null_mut();
        DEFERRED_MESSAGES.with(|messages| {
            let mut messages = messages.borrow_mut();
            messages.push_back(DeferredMessage {
                owner: owner as usize,
                text: "first".to_owned(),
                caption: "one".to_owned(),
            });
            messages.push_back(DeferredMessage {
                owner: owner as usize,
                text: "second".to_owned(),
                caption: "two".to_owned(),
            });
        });
        let shown = RefCell::new(Vec::new());
        assert!(drain_deferred_messages_with(
            owner,
            |nested_owner, text, caption| {
                shown
                    .borrow_mut()
                    .push((text.to_owned(), caption.to_owned()));
                assert!(!drain_deferred_messages_with(nested_owner, |_, _, _| {}));
            }
        ));
        assert_eq!(
            shown.into_inner(),
            vec![
                ("first".to_owned(), "one".to_owned()),
                ("second".to_owned(), "two".to_owned()),
            ]
        );
        assert!(take_deferred_message(owner).is_none());

        DEFERRED_MESSAGES.with(|messages| {
            messages.borrow_mut().push_back(DeferredMessage {
                owner: owner as usize,
                text: "destroyed".to_owned(),
                caption: "owner".to_owned(),
            });
        });
        discard_deferred_messages(owner);
        assert!(take_deferred_message(owner).is_none());
    }

    #[test]
    fn deferred_message_wake_retries_after_both_schedulers_fail() {
        let owner = null_mut();
        let attempts = Cell::new(0_u8);
        assert!(!schedule_deferred_message_wake(
            owner,
            |_| {
                attempts.set(attempts.get().saturating_add(1));
                false
            },
            |_| {
                attempts.set(attempts.get().saturating_add(1));
                false
            },
        ));
        assert_eq!(attempts.get(), 2);
        assert!(schedule_deferred_message_wake(
            owner,
            |_| {
                attempts.set(attempts.get().saturating_add(1));
                true
            },
            |_| false,
        ));
        assert_eq!(attempts.get(), 3);
    }

    #[test]
    fn menu_bottom_edge_repaints_for_paint_and_activation_messages() {
        assert!(repaints_menu_bottom_edge(WM_NCPAINT));
        assert!(repaints_menu_bottom_edge(WM_NCACTIVATE));
        assert!(!repaints_menu_bottom_edge(WM_ERASEBKGND));
    }
}
