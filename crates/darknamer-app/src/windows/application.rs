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
        dwICC: ICC_LISTVIEW_CLASSES | ICC_BAR_CLASSES,
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
        if handle_accelerator(window, &message) {
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
        WM_GETMINMAXINFO if !state_ptr.is_null() => {
            let info = lparam as *mut MINMAXINFO;
            if !info.is_null() {
                // SAFETY: WM_GETMINMAXINFO supplies writable MINMAXINFO storage
                // for this callback and state_ptr is the live AppState.
                unsafe {
                    (*info).ptMinTrackSize.x = scale_dip(INITIAL_WIDTH, (*state_ptr).dpi);
                    (*info).ptMinTrackSize.y = scale_dip(INITIAL_HEIGHT, (*state_ptr).dpi);
                }
            }
            0
        }
        WM_DPICHANGED if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            let state = unsafe { &mut *state_ptr };
            let dpi = u32::try_from(wparam & 0xFFFF).unwrap_or(BASE_DPI);
            state.dpi = dpi.max(BASE_DPI);
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
            refresh_system_fonts(state);
            arrange(window, state);
            0
        }
        WM_SETTINGCHANGE | WM_FONTCHANGE | WM_THEMECHANGED | WM_SYSCOLORCHANGE
            if !state_ptr.is_null() =>
        {
            // SAFETY: state_ptr is the live UI-thread AppState.
            let state = unsafe { &mut *state_ptr };
            refresh_system_fonts(state);
            refresh_high_contrast_toolbars(window, state);
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
                    // SAFETY: dispatch returned, so a fresh unique borrow of the
                    // same non-null window-owned AppState is valid for refresh.
                    update_controls(unsafe { &mut *state_ptr });
                }
            }
            0
        }
        WM_KEYDOWN if !state_ptr.is_null() => {
            let command = match wparam as u32 {
                0x2E => Some(0xFFFF),
                0xBC => Some(MOVE_UP),
                0xBE => Some(MOVE_DOWN),
                0x1B => Some(2),
                _ => None,
            };
            if let Some(command) = command {
                // SAFETY: state_ptr is the checked non-null AppState owned by the
                // current window callback and is uniquely borrowed for dispatch.
                dispatch_command(window, unsafe { &mut *state_ptr }, command);
            }
            0
        }
        WM_DESTROY => {
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
