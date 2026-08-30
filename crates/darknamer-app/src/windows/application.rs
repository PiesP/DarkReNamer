use super::*;

struct WindowInit {
    state: *mut AppState,
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
    // SAFETY: both structures are C-compatible integer rectangles with valid
    // all-zero initial states for the two synchronous geometry queries.
    let mut outer: RECT = unsafe { zeroed() };
    // SAFETY: see above.
    let mut client: RECT = unsafe { zeroed() };
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
    let rail_width = state
        .font_metrics
        .rail_metrics(RailDensity::Compact, state.dpi)
        .rail_width;
    let baseline_rail_width = RailDensity::Compact.metrics(state.dpi).rail_width;
    let measured_content_width = scale_dip(minimum_content_width_dip(), state.dpi)
        .saturating_add(
            rail_width
                .saturating_sub(baseline_rail_width)
                .saturating_mul(2),
        )
        .max(
            rail_width
                .saturating_mul(2)
                .saturating_add(state.font_metrics.empty_state_minimum_width(state.dpi)),
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
    minimum_main_client_height(state.dpi, state.font_metrics)
        .saturating_add(nonclient_height(window))
}

fn recommended_track_height(window: HWND, state: &AppState) -> i32 {
    recommended_main_client_height(state.dpi, state.font_metrics)
        .saturating_add(nonclient_height(window))
}

fn initial_dpi_size(window: HWND, state: &AppState) -> (i32, i32) {
    (
        minimum_track_width(window, state),
        scale_dip(INITIAL_HEIGHT, state.dpi).max(recommended_track_height(window, state)),
    )
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

fn window_state_ptr(window: HWND) -> *mut AppState {
    // SAFETY: this value query reads only the pointer installed in this exact
    // window's user-data slot and does not create a Rust reference.
    unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) as *mut AppState }
}

fn has_window_state(window: HWND) -> bool {
    !window_state_ptr(window).is_null()
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
    let state_ptr = window_state_ptr(window);
    if state_ptr.is_null() {
        return None;
    }
    // SAFETY: the pointer was resolved from the live window immediately above;
    // this borrow ends before any target validation or SetFocus call.
    let target = unsafe { handle_focus_navigation(&mut *state_ptr, message) }?;
    valid_focus_target(window, target).then_some(target)
}

fn restored_focus_target(window: HWND, state_ptr: *mut AppState) -> Option<HWND> {
    if state_ptr.is_null() {
        return None;
    }
    // SAFETY: state_ptr is the current value from this callback window's user
    // data. The mutable borrow ends before the reentrant SetFocus boundary.
    let target = unsafe { restore_child_focus(&mut *state_ptr) }?;
    valid_focus_target(window, target).then_some(target)
}

fn apply_focus_target(target: HWND) {
    // SAFETY: callers validate target after releasing every AppState reference;
    // SetFocus may synchronously emit BN_SETFOCUS and reenter window_proc.
    unsafe { SetFocus(target) };
}

fn ensure_minimum_track_size(window: HWND, state: &AppState) -> io::Result<()> {
    // SAFETY: RECT has a valid all-zero representation and remains writable for
    // the synchronous top-level window geometry query.
    let mut rect: RECT = unsafe { zeroed() };
    // SAFETY: window is the live top-level HWND owned by this UI thread.
    if unsafe { GetWindowRect(window, &mut rect) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let minimum_width = minimum_track_width(window, state);
    let minimum_height = minimum_track_height(window, state);
    let current_width = rect.right - rect.left;
    let current_height = rect.bottom - rect.top;
    if current_width >= minimum_width && current_height >= minimum_height {
        return Ok(());
    }
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
    let placement = fit_widened_window_to_work_area(
        rect.left,
        monitor_info.rcWork.left,
        monitor_info.rcWork.right,
        minimum_width.max(current_width),
    )
    .ok_or_else(|| io::Error::other("invalid monitor work area"))?;
    let work_height = monitor_info.rcWork.bottom - monitor_info.rcWork.top;
    if work_height <= 0 {
        return Err(io::Error::other("invalid monitor work area height"));
    }
    let height = minimum_height.max(current_height).min(work_height);
    let latest_y = monitor_info.rcWork.bottom - height;
    let y = rect.top.clamp(monitor_info.rcWork.top, latest_y);
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
    let startup_notice = runtime.status.clone();
    let state = Box::into_raw(Box::new(AppState::new(runtime)));
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
    let state_ptr = window_state_ptr(window);
    if state_ptr.is_null() {
        // SAFETY: the created window did not retain its required AppState and
        // is destroyed before returning the initialization failure.
        unsafe { DestroyWindow(window) };
        return Err(io::Error::other("window state was not adopted"));
    }
    // SAFETY: state_ptr was resolved from the live window. Only copied geometry
    // leaves this block, so SetWindowPos cannot reenter while the borrow exists.
    let (initial_width, initial_height) = unsafe { initial_dpi_size(window, &*state_ptr) };
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
    if let Some(notice) = startup_notice {
        message(window, &notice, "DarkReNamer - 복구 상태");
    }
    // SAFETY: MSG is a C-compatible structure for which all-zero is a valid pre-GetMessageW state.
    let mut message: MSG = unsafe { zeroed() };
    loop {
        // SAFETY: message is writable MSG storage outliving GetMessageW; null HWND requests this thread queue.
        let result = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if result == -1 {
            let error = io::Error::last_os_error();
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
    // SAFETY: window is the active callback HWND; GWLP_USERDATA is read only to recover the pointer installed during creation.
    let state_ptr = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut AppState;
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
            let registrations = match register_drop_targets(list, overlay, window) {
                Ok(registrations) => registrations,
                Err(_) => return -1,
            };
            let current_state = window_state_ptr(window);
            if current_state.is_null() {
                drop(registrations);
                return -1;
            }
            // SAFETY: state was freshly re-resolved after both OLE calls and no
            // further reentrant call occurs during this field assignment.
            unsafe { (*current_state).drop_registrations = Some(registrations) };
            // SAFETY: child creation succeeded and state_ptr remains the live,
            // UI-thread-confined AppState for this top-level window.
            start_preferences_writer(window, unsafe { &mut *current_state });
            0
        }
        WM_SIZE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is non-null window-owned AppState storage and no
            // mutable reference exists while this shared layout borrow is live.
            arrange(window, unsafe { &mut *state_ptr });
            0
        }
        WM_SETFOCUS if !state_ptr.is_null() => {
            if let Some(target) = restored_focus_target(window, state_ptr) {
                apply_focus_target(target);
            }
            0
        }
        WM_APP_RESTORE_FOCUS if !state_ptr.is_null() => {
            let requested = wparam as HWND;
            let target = if requested.is_null() {
                restored_focus_target(window, state_ptr)
            } else {
                valid_focus_target(window, requested).then_some(requested)
            };
            if let Some(target) = target {
                apply_focus_target(target);
            }
            0
        }
        WM_GETMINMAXINFO if !state_ptr.is_null() => {
            let info = lparam as *mut MINMAXINFO;
            if !info.is_null() {
                // SAFETY: WM_GETMINMAXINFO supplies writable MINMAXINFO storage
                // for this callback and state_ptr is the live AppState.
                unsafe {
                    (*info).ptMinTrackSize.x = minimum_track_width(window, &*state_ptr);
                    (*info).ptMinTrackSize.y = minimum_track_height(window, &*state_ptr);
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
            let apply = state
                .presentation(selected_indices(state.list_window).len())
                .apply;
            refresh_apply_keyline(state, apply);
            refresh_system_fonts(state);
            if let Err(error) = ensure_minimum_track_size(window, state) {
                super::message(
                    window,
                    &format!("새 표시 설정의 최소 창 크기를 적용하지 못했습니다: {error}"),
                    "DarkReNamer - 표시 설정",
                );
            }
            arrange(window, state);
            0
        }
        WM_FONTCHANGE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState.
            let state = unsafe { &mut *state_ptr };
            refresh_system_fonts(state);
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
            request_window_close(window, unsafe { &mut *state_ptr });
            0
        }
        WM_CTLCOLORSTATIC if !state_ptr.is_null() => {
            let child = lparam as HWND;
            // SAFETY: state_ptr is the live UI-thread AppState. Each rail
            // returns its brush only for its exact owned keyline HWND.
            let state = unsafe { &*state_ptr };
            let brush = state
                .left_rail
                .as_ref()
                .and_then(|rail| rail.apply_keyline_brush_for(child))
                .or_else(|| {
                    state
                        .right_rail
                        .as_ref()
                        .and_then(|rail| rail.apply_keyline_brush_for(child))
                });
            if let Some(brush) = brush {
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
            dispatch_command(window, unsafe { &mut *state_ptr }, command);
            0
        }
        WM_NOTIFY if !state_ptr.is_null() => {
            let header = lparam as *const NMHDR;
            if !header.is_null()
                // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix for this
                // synchronous callback; no AppState access occurs on the
                // deferred programmatic-selection path.
                && unsafe { (*header).code } == LVN_ITEMCHANGED
                && programmatic_list_update_active()
            {
                return 0;
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
                    dispatch_command(window, unsafe { &mut *state_ptr }, MANUAL_CHANGE);
                }
            }
            0
        }
        WM_DESTROY => {
            if !state_ptr.is_null() {
                // Take the registration without retaining an AppState borrow;
                // RevokeDragDrop may synchronously release the COM target.
                // SAFETY: state_ptr is live UI-thread state for this callback.
                let (overlay, registrations) = unsafe {
                    let state = &mut *state_ptr;
                    (state.drop_overlay, state.drop_registrations.take())
                };
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
        WM_NCDESTROY => {
            if !state_ptr.is_null() {
                // Defensive idempotent fallback if creation teardown reached
                // WM_NCDESTROY without the ordinary WM_DESTROY path.
                // SAFETY: state_ptr is still published and UI-thread confined.
                let (overlay, registrations) = unsafe {
                    let state = &mut *state_ptr;
                    (state.drop_overlay, state.drop_registrations.take())
                };
                set_drop_overlay_control(overlay, DropPresentation::Inactive);
                drop(registrations);
                // Clear the published pointer before reclaiming it so queued
                // worker/input messages cannot recover freed AppState storage.
                // SAFETY: this callback owns the exact GWLP_USERDATA slot.
                unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
                // SAFETY: this timer identifier is process-owned; killing an
                // absent timer is harmless during defensive teardown.
                unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
                // SAFETY: same defensive teardown for the preference poll timer.
                unsafe { KillTimer(window, PREFERENCES_POLL_TIMER_ID) };
                // SAFETY: state_ptr is the non-null Box::into_raw AppState stored at WM_NCCREATE; WM_NCDESTROY is its single reclamation point.
                unsafe { drop(Box::from_raw(state_ptr)) };
            }
            // SAFETY: window, message, wparam, and lparam are unchanged values from the active Windows callback.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
        _ => {
            // SAFETY: window, message, wparam, and lparam are unchanged values from the active Windows callback.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
    }
}
