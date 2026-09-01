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

pub(super) unsafe extern "system" fn window_proc(
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
    if message == WM_NCDESTROY {
        if !state_slot.is_null() {
            // SAFETY: this final callback owns the publication slot. Clearing it
            // prevents any nested or queued callback from reaching the state.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
            // SAFETY: both identifiers belong to this exact top-level window;
            // killing absent timers is harmless during defensive teardown.
            unsafe {
                KillTimer(window, APPLY_POLL_TIMER_ID);
                KillTimer(window, PREFERENCES_POLL_TIMER_ID);
                KillTimer(window, STATUS_RENDER_TIMER_ID);
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
        if message == WM_COMMAND
            || message == WM_NOTIFY
            || message == WM_CLOSE
            || message == WM_TIMER
            || message >= WM_APP
        {
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
            // Copy only owned/scalar routing values, then release the callback
            // lease before SetWindowTextW can synchronously request colors.
            // SAFETY: state_ptr is the live AppState under this callback's sole
            // lease; only the copyable HWND crosses the release boundary.
            let safety = unsafe { (*state_ptr).empty_safety };
            let mode = if wparam == 0 {
                RailMode::MenuOnly
            } else {
                RailMode::Compact
            };
            let text = empty_state_safety_copy(mode);
            run_after_callback_state_release(state_lease, || set_status(safety, text));
            0
        }
        WM_TIMER if !state_ptr.is_null() && wparam == STATUS_RENDER_TIMER_ID => {
            // Stop the coalescing timer only after this callback acquires the
            // state lease. A busy nested WM_TIMER exits above without killing
            // it, so the low-priority timer can retry after the nested loop.
            // SAFETY: window owns this exact timer identifier; killing an
            // absent timer is harmless and carries no callback payload.
            unsafe { KillTimer(window, STATUS_RENDER_TIMER_ID) };
            // Snapshot both channels as owned text plus copied HWNDs, then end
            // the sole AppState lease before SetWindowTextW can synchronously
            // enter accessibility or WM_CTLCOLORSTATIC callbacks.
            // SAFETY: state_ptr is the live AppState under this callback's sole
            // lease; no AppState reference crosses the release boundary.
            let (status_message, status_count, message_text, count_text) = unsafe {
                let state = &*state_ptr;
                (
                    state.status_message,
                    state.status_count,
                    state.ui_status.message_text().to_owned(),
                    state.ui_status.count_text(),
                )
            };
            run_after_callback_state_release(state_lease, || {
                set_status(status_message, &message_text);
                set_status(status_count, &count_text);
            });
            0
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
            handle_plan_completion(window, unsafe { &mut *state_ptr });
            0
        }
        WM_APP_ADMISSION_COMPLETE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            handle_admission_completion(window, unsafe { &mut *state_ptr });
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
                handle_admission_completion(window, state);
                return 0;
            }
            if state
                .plan_worker
                .as_ref()
                .is_some_and(|worker| worker.handle.is_finished())
            {
                handle_plan_completion(window, state);
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
        _ if repaints_menu_bottom_edge(message) && !state_ptr.is_null() => {
            // Only custom Light/Dark resources repair the app-owned menu edge.
            // Copy the COLORREF and end the lease before default non-client
            // painting can synchronously reenter this callback graph.
            let color = state_lease
                .state()
                .appearance_resources
                .as_ref()
                .map(|resources| resources.palette().surface_window);
            drop(state_lease);
            // SAFETY: arguments are unchanged copied values from this active
            // non-client callback. Its return value remains authoritative.
            let result = unsafe { DefWindowProcW(window, message, wparam, lparam) };
            if let Some(color) = color {
                paint_menu_bottom_edge(window, color);
            }
            result
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
            let prompt = dispatch_command(window, unsafe { &mut *state_ptr }, command);
            run_after_callback_state_release(state_lease, || {
                if let Some(prompt) = prompt {
                    run_prepared_prompt(window, prompt);
                }
            });
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
                    let prompt =
                        dispatch_command(window, unsafe { &mut *state_ptr }, MANUAL_CHANGE);
                    run_after_callback_state_release(state_lease, || {
                        if let Some(prompt) = prompt {
                            run_prepared_prompt(window, prompt);
                        }
                    });
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

    #[test]
    fn menu_bottom_edge_repaints_for_paint_and_activation_messages() {
        assert!(repaints_menu_bottom_edge(WM_NCPAINT));
        assert!(repaints_menu_bottom_edge(WM_NCACTIVATE));
        assert!(!repaints_menu_bottom_edge(WM_ERASEBKGND));
    }
}
