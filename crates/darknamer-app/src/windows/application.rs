use super::*;

struct WindowInit {
    state: *mut AppState,
    adopted: *mut bool,
}

struct ComGuard;

impl Drop for ComGuard {
    fn drop(&mut self) {
        // SAFETY: ComGuard exists only after successful CoInitializeEx and drops on the same apartment thread.
        unsafe { CoUninitialize() };
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
    let measured_content_width = scale_dip(minimum_content_width_dip(), state.dpi).saturating_add(
        rail_width
            .saturating_sub(baseline_rail_width)
            .saturating_mul(2),
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

fn resize_to_initial_dpi(window: HWND, state: &AppState) -> io::Result<()> {
    let width = minimum_track_width(window, state);
    let height = scale_dip(INITIAL_HEIGHT, state.dpi).max(recommended_track_height(window, state));
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
    // SAFETY: CoInitializeEx requires a null reserved pointer; ComGuard balances success on this same apartment thread.
    let com_status = unsafe { CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) };
    if com_status < 0 {
        return Err(io::Error::from_raw_os_error(com_status));
    }
    let _com = ComGuard;
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
            WS_EX_ACCEPTFILES | WS_EX_APPWINDOW,
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
    // SAFETY: successful WM_NCCREATE adopted `state`; it remains live in the
    // window user data until WM_NCDESTROY and is read only for this resize.
    if let Err(error) = resize_to_initial_dpi(window, unsafe { &*state }) {
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
        if accelerators.translate(window, &message) {
            continue;
        }
        // SAFETY: window is the live top-level owner and message was populated
        // by GetMessageW. Existing accelerators are handled first; dialog-style
        // navigation then provides Tab and Shift+Tab across direct children.
        if unsafe { IsDialogMessageW(window, &message) } != 0 {
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
            0
        }
        WM_SIZE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is non-null window-owned AppState storage and no
            // mutable reference exists while this shared layout borrow is live.
            arrange(window, unsafe { &*state_ptr });
            0
        }
        WM_SETFOCUS if !state_ptr.is_null() => {
            // SAFETY: list_window is the live focusable ListView child owned by
            // this top-level window on the current UI thread.
            unsafe { SetFocus((*state_ptr).list_window) };
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
        WM_COMMAND if !state_ptr.is_null() => {
            let command = (wparam & 0xFFFF) as u16;
            // SAFETY: state_ptr is the non-null, window-thread-confined AppState
            // installed in GWLP_USERDATA and is uniquely borrowed for dispatch.
            dispatch_command(window, unsafe { &mut *state_ptr }, command);
            0
        }
        WM_DROPFILES if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live window-thread AppState pointer.
            if unsafe { (*state_ptr).read_only_locked() || (*state_ptr).mutation_locked } {
                // SAFETY: wparam is the owned HDROP delivered with this message
                // and is released exactly once on the rejected path.
                unsafe { DragFinish(wparam as HDROP) };
                self::message(
                    window,
                    "파일 변경 또는 복구 잠금 중에는 목록을 변경할 수 없습니다.",
                    "DarkReNamer - 변경 중",
                );
                return 0;
            }
            // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
            unsafe {
                admit_drop(window, &mut *state_ptr, wparam as HDROP);
            }
            0
        }
        WM_NOTIFY if !state_ptr.is_null() => {
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
            let header = lparam as *const NMHDR;
            if !header.is_null()
                // SAFETY: For WM_NOTIFY, non-null lparam points to an NMHDR prefix that remains readable throughout this synchronous callback.
                && unsafe { (*header).hwndFrom } == unsafe { (*state_ptr).list_window }
            {
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
                // SAFETY: this timer identifier is process-owned; killing an
                // absent timer is harmless during defensive teardown.
                unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
                // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
                if !unsafe { (*state_ptr).font }.is_null() {
                    // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
                    unsafe { DeleteObject((*state_ptr).font) };
                }
                // SAFETY: status_font is a distinct AppState-owned HFONT and is
                // deleted exactly once at window teardown.
                if !unsafe { (*state_ptr).status_font }.is_null() {
                    // SAFETY: the non-null AppState-owned font is deleted once
                    // at the window's single WM_NCDESTROY teardown point.
                    unsafe { DeleteObject((*state_ptr).status_font) };
                }
                // SAFETY: state_ptr is the non-null Box::into_raw AppState stored at WM_NCCREATE; WM_NCDESTROY is its single reclamation point.
                unsafe { drop(Box::from_raw(state_ptr)) };
                // SAFETY: window is the active callback HWND; GWLP_USERDATA stores or clears the process-owned pointer without transferring ownership.
                unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
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
