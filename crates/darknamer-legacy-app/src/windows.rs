#![allow(
    clippy::undocumented_unsafe_blocks,
    reason = "all unsafe operations are confined to this Win32 boundary; entry-point invariants are documented"
)]

use std::ffi::c_void;
use std::io;
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};

use dark_renamer_legacy::{LegacyList, LegacyListItem};
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{COLOR_WINDOW, UpdateWindow};
use windows_sys::Win32::Storage::FileSystem::MoveFileW;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Controls::{
    ICC_LISTVIEW_CLASSES, INITCOMMONCONTROLSEX, InitCommonControlsEx, LVCF_FMT, LVCF_TEXT,
    LVCF_WIDTH, LVCFMT_LEFT, LVCFMT_RIGHT, LVCOLUMNW, LVIF_TEXT, LVITEMW, LVM_DELETEALLITEMS,
    LVM_INSERTCOLUMNW, LVM_INSERTITEMW, LVM_SETEXTENDEDLISTVIEWSTYLE, LVM_SETITEMTEXTW,
    LVS_EX_FULLROWSELECT, LVS_NOSORTHEADER, LVS_REPORT, LVS_SHOWSELALWAYS,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::EnableWindow;
use windows_sys::Win32::UI::Shell::{DragAcceptFiles, DragFinish, DragQueryFileW, HDROP};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CREATESTRUCTW, CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, CreateMenu, CreatePopupMenu,
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GWLP_USERDATA, GetClientRect,
    GetMessageW, GetWindowLongPtrW, HMENU, IDC_ARROW, IDOK, LoadCursorW, MB_OKCANCEL, MF_POPUP,
    MF_SEPARATOR, MF_STRING, MSG, MessageBoxW, MoveWindow, PostQuitMessage, RegisterClassExW,
    SW_SHOW, SendMessageW, SetMenu, SetWindowLongPtrW, ShowWindow, TranslateMessage, WM_COMMAND,
    WM_CREATE, WM_DESTROY, WM_DROPFILES, WM_KEYDOWN, WM_NCCREATE, WM_NCDESTROY, WM_SIZE,
    WNDCLASSEXW, WS_BORDER, WS_CHILD, WS_CLIPCHILDREN, WS_EX_ACCEPTFILES, WS_EX_APPWINDOW,
    WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_OVERLAPPEDWINDOW, WS_TABSTOP, WS_VISIBLE,
};

use crate::*;

const LIST_ID: usize = 1000;
const STATUS_ID: usize = 1007;

struct AppState {
    list_window: HWND,
    status: HWND,
    left_buttons: Vec<HWND>,
    right_buttons: Vec<HWND>,
    model: LegacyList,
}

impl AppState {
    fn new() -> Self {
        Self {
            list_window: null_mut(),
            status: null_mut(),
            left_buttons: Vec::new(),
            right_buttons: Vec::new(),
            model: LegacyList::new(),
        }
    }
}

pub(crate) fn run() -> io::Result<()> {
    // SAFETY: All Win32 handles are created and consumed on this UI thread;
    // pointers passed to Win32 remain valid for each synchronous call.
    unsafe { run_unsafe() }
}

unsafe fn run_unsafe() -> io::Result<()> {
    let controls = INITCOMMONCONTROLSEX {
        dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
        dwICC: ICC_LISTVIEW_CLASSES,
    };
    // SAFETY: controls points to a fully initialized structure.
    unsafe { InitCommonControlsEx(&controls) };
    // SAFETY: null requests the current module handle.
    let instance = unsafe { GetModuleHandleW(null()) };
    if instance.is_null() {
        return Err(io::Error::last_os_error());
    }
    let class_name = wide("DarkNamerLegacyWindow");
    let window_class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(window_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        hIcon: null_mut(),
        // SAFETY: IDC_ARROW is a predefined resource identifier.
        hCursor: unsafe { LoadCursorW(null_mut(), IDC_ARROW) },
        hbrBackground: (COLOR_WINDOW + 1) as *mut c_void,
        lpszMenuName: null(),
        lpszClassName: class_name.as_ptr(),
        hIconSm: null_mut(),
    };
    // SAFETY: class strings and callback remain valid for the process lifetime.
    if unsafe { RegisterClassExW(&window_class) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let title = wide("DarkNamer");
    let state = Box::new(AppState::new());
    // SAFETY: state ownership transfers to WM_NCCREATE and is reclaimed at WM_NCDESTROY.
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
            Box::into_raw(state).cast(),
        )
    };
    if window.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: window is a live top-level window.
    unsafe {
        ShowWindow(window, SW_SHOW);
        UpdateWindow(window);
    }
    // SAFETY: MSG is initialized before use by GetMessageW.
    let mut message: MSG = unsafe { zeroed() };
    loop {
        // SAFETY: message is writable and window filtering is disabled.
        let result = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if result == -1 {
            return Err(io::Error::last_os_error());
        }
        if result == 0 {
            break;
        }
        // SAFETY: GetMessageW supplied a valid message.
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
            // SAFETY: WM_NCCREATE lParam is CREATESTRUCTW and lpCreateParams is our Box pointer.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, (*create).lpCreateParams as isize) };
        }
    }
    // SAFETY: GWLP_USERDATA contains AppState from WM_NCCREATE until WM_NCDESTROY.
    let state_ptr = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut AppState;
    match message {
        WM_CREATE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is uniquely owned by this UI thread.
            if unsafe { create_children(window, &mut *state_ptr) }.is_err() {
                return -1;
            }
            0
        }
        WM_SIZE if !state_ptr.is_null() => {
            // SAFETY: child handles are live while parent is live.
            unsafe { arrange(window, &*state_ptr) };
            0
        }
        WM_COMMAND if !state_ptr.is_null() => {
            let command = (wparam & 0xFFFF) as u16;
            // SAFETY: state_ptr is confined to the window thread.
            unsafe { dispatch_command(window, &mut *state_ptr, command) };
            0
        }
        WM_DROPFILES if !state_ptr.is_null() => {
            // SAFETY: wParam is HDROP for WM_DROPFILES.
            unsafe { admit_drop(&mut *state_ptr, wparam as HDROP) };
            0
        }
        WM_KEYDOWN if !state_ptr.is_null() => {
            let command = match wparam as u32 {
                0x2E => Some(CLEAR_LIST),
                0xBC => Some(MOVE_UP),
                0xBE => Some(MOVE_DOWN),
                _ => None,
            };
            if let Some(command) = command {
                // SAFETY: state_ptr is confined to the window thread.
                unsafe { dispatch_command(window, &mut *state_ptr, command) };
            }
            0
        }
        WM_DESTROY => {
            // SAFETY: ends the current UI message loop.
            unsafe { PostQuitMessage(0) };
            0
        }
        WM_NCDESTROY => {
            if !state_ptr.is_null() {
                // SAFETY: this is the single reclamation of Box::into_raw from run_unsafe.
                unsafe { drop(Box::from_raw(state_ptr)) };
                // SAFETY: prevent later accidental reuse.
                unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
            }
            // SAFETY: default processing completes non-client destruction.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
        _ => {
            // SAFETY: unhandled messages are delegated to the system.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
    }
}

unsafe fn create_children(window: HWND, state: &mut AppState) -> io::Result<()> {
    let instance = unsafe { GetModuleHandleW(null()) };
    let list_class = wide("SysListView32");
    // SAFETY: all strings remain valid during this synchronous creation call.
    state.list_window = unsafe {
        CreateWindowExW(
            0,
            list_class.as_ptr(),
            null(),
            WS_CHILD
                | WS_VISIBLE
                | WS_BORDER
                | WS_TABSTOP
                | LVS_REPORT
                | LVS_SHOWSELALWAYS
                | LVS_NOSORTHEADER,
            0,
            0,
            0,
            0,
            window,
            LIST_ID as *mut c_void,
            instance,
            null_mut(),
        )
    };
    if state.list_window.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: ListView messages use initialized structures and synchronous string pointers.
    unsafe {
        SendMessageW(
            state.list_window,
            LVM_SETEXTENDEDLISTVIEWSTYLE,
            0,
            LVS_EX_FULLROWSELECT as isize,
        );
        for (index, column) in COLUMNS.iter().enumerate() {
            let mut text = wide(column.label);
            let mut native = LVCOLUMNW {
                mask: LVCF_TEXT | LVCF_WIDTH | LVCF_FMT,
                fmt: if index == 4 {
                    LVCFMT_RIGHT
                } else {
                    LVCFMT_LEFT
                },
                cx: column.default_width,
                pszText: text.as_mut_ptr(),
                ..zeroed()
            };
            SendMessageW(
                state.list_window,
                LVM_INSERTCOLUMNW,
                index,
                (&mut native as *mut LVCOLUMNW) as isize,
            );
        }
    }
    state.status = unsafe { child(window, "STATIC", "0개의 항목", STATUS_ID as u16, 0) };
    for tool in LEFT_TOOLS {
        state
            .left_buttons
            .push(unsafe { child(window, "BUTTON", tool.label, tool.id, 0) });
    }
    for tool in RIGHT_TOOLS {
        state
            .right_buttons
            .push(unsafe { child(window, "BUTTON", tool.label, tool.id, 0) });
    }
    // SAFETY: window is a live top-level HWND configured for shell drops.
    unsafe { DragAcceptFiles(window, 1) };
    let menu = unsafe { create_menu() };
    // SAFETY: menu ownership transfers to the top-level window.
    unsafe { SetMenu(window, menu) };
    unsafe { arrange(window, state) };
    Ok(())
}

unsafe fn child(parent: HWND, class: &str, text: &str, id: u16, extra_style: u32) -> HWND {
    let class = wide(class);
    let text = wide(text);
    // SAFETY: class/text pointers are valid for this synchronous call.
    unsafe {
        CreateWindowExW(
            0,
            class.as_ptr(),
            text.as_ptr(),
            WS_CHILD | WS_VISIBLE | extra_style,
            0,
            0,
            0,
            0,
            parent,
            id as usize as *mut c_void,
            GetModuleHandleW(null()),
            null_mut(),
        )
    }
}

unsafe fn arrange(window: HWND, state: &AppState) {
    // SAFETY: rect is writable and window is live.
    let mut rect: RECT = unsafe { zeroed() };
    unsafe { GetClientRect(window, &mut rect) };
    let width = rect.right.max(TOOLBAR_WIDTH * 2 + 1);
    let height = rect.bottom.max(STATUS_HEIGHT + 1);
    let button_height = ((height - STATUS_HEIGHT) / 10).max(24);
    for (index, button) in state.left_buttons.iter().enumerate() {
        unsafe {
            MoveWindow(
                *button,
                0,
                index as i32 * button_height,
                TOOLBAR_WIDTH,
                button_height,
                1,
            )
        };
    }
    for (index, button) in state.right_buttons.iter().enumerate() {
        unsafe {
            MoveWindow(
                *button,
                width - TOOLBAR_WIDTH,
                index as i32 * button_height,
                TOOLBAR_WIDTH,
                button_height,
                1,
            )
        };
    }
    unsafe {
        MoveWindow(
            state.list_window,
            TOOLBAR_WIDTH,
            0,
            width - TOOLBAR_WIDTH * 2,
            height - STATUS_HEIGHT,
            1,
        );
        MoveWindow(
            state.status,
            0,
            height - STATUS_HEIGHT,
            width,
            STATUS_HEIGHT,
            1,
        );
    }
}

unsafe fn dispatch_command(window: HWND, state: &mut AppState, command: u16) {
    match command {
        APPLY => unsafe { apply_changes(window, state) },
        RESET => state.model.reset_proposals(),
        CLEAR_LIST => state.model = LegacyList::new(),
        CLEAR_NAME => state.model.clear_name(),
        KEEP_DIGITS => state.model.keep_ascii_digits(),
        EXT_DELETE => state.model.delete_extension(),
        PARENT_PREFIX => state.model.prefix_parent_folder(),
        PARENT_SUFFIX => state.model.suffix_parent_folder(),
        VERSION => unsafe { message(window, "DarkNamer 08.02.10 버전", "DarkNamer") },
        2 => unsafe {
            DestroyWindow(window);
        },
        _ => {}
    }
    unsafe { refresh(state) };
}

unsafe fn apply_changes(window: HWND, state: &mut AppState) {
    if state
        .model
        .items()
        .iter()
        .any(|item| item.proposed_name().is_empty())
    {
        unsafe {
            message(window, "이름이 지정되지 않은 경우가 있습니다.", "DarkNamer")
        };
        return;
    }
    for left in 0..state.model.len() {
        for right in left + 1..state.model.len() {
            if state.model.items()[left]
                .planned_path()
                .case_insensitive_cmp(&state.model.items()[right].planned_path())
                == std::cmp::Ordering::Equal
            {
                unsafe { message(window, "중복되는 이름이 있습니다.", "DarkNamer") };
                return;
            }
        }
    }
    let prompt = wide("실제 파일 이름을 변경하시겠습니까?");
    let caption = wide("DarkNamer");
    if unsafe { MessageBoxW(window, prompt.as_ptr(), caption.as_ptr(), MB_OKCANCEL) } != IDOK {
        return;
    }
    let mut failed = Vec::new();
    for index in 0..state.model.len() {
        let source = state.model.items()[index].source_path().clone();
        let destination = state.model.items()[index].planned_path();
        if source.case_insensitive_cmp(&destination) == std::cmp::Ordering::Equal {
            continue;
        }
        let mut source_wide = source.units().to_vec();
        source_wide.push(0);
        let mut destination_wide = destination.units().to_vec();
        destination_wide.push(0);
        if unsafe { MoveFileW(source_wide.as_ptr(), destination_wide.as_ptr()) } != 0 {
            state.model.record_move_success(index);
        } else {
            failed.push(format!("{source} -> {destination} 변경 실패."));
        }
    }
    if failed.is_empty() {
        unsafe { message(window, "파일 이름을 변경하였습니다.", "DarkNamer") };
    } else {
        unsafe { message(window, &failed.join("\n"), "DarkNamer") };
    }
}

unsafe fn admit_drop(state: &mut AppState, drop: HDROP) {
    // SAFETY: drop is a valid HDROP for the duration of WM_DROPFILES handling.
    let count = unsafe { DragQueryFileW(drop, u32::MAX, null_mut(), 0) };
    let mut items = Vec::new();
    for index in 0..count {
        let length = unsafe { DragQueryFileW(drop, index, null_mut(), 0) };
        let mut buffer = vec![0; length as usize + 1];
        unsafe { DragQueryFileW(drop, index, buffer.as_mut_ptr(), buffer.len() as u32) };
        buffer.truncate(length as usize);
        let path = String::from_utf16_lossy(&buffer);
        if let Ok(metadata) = std::fs::metadata(&path) {
            let size = u32::try_from(metadata.len()).unwrap_or(u32::MAX);
            items.push(LegacyListItem::new(path, metadata.is_dir(), size, 0, 0));
        }
    }
    unsafe { DragFinish(drop) };
    state.model.append_batch(items);
    unsafe { refresh(state) };
}

unsafe fn refresh(state: &AppState) {
    unsafe { SendMessageW(state.list_window, LVM_DELETEALLITEMS, 0, 0) };
    for (row, item) in state.model.items().iter().enumerate() {
        let values = [
            item.current_name(),
            item.proposed_name(),
            item.root_path(),
            item.source_path(),
        ];
        for (column, value) in values.iter().enumerate() {
            let mut text = value.units().to_vec();
            text.push(0);
            if column == 0 {
                let mut native = LVITEMW {
                    mask: LVIF_TEXT,
                    iItem: row as i32,
                    iSubItem: 0,
                    pszText: text.as_mut_ptr(),
                    ..unsafe { zeroed() }
                };
                unsafe {
                    SendMessageW(
                        state.list_window,
                        LVM_INSERTITEMW,
                        0,
                        (&mut native as *mut LVITEMW) as isize,
                    )
                };
            } else {
                let mut native = LVITEMW {
                    iSubItem: column as i32,
                    pszText: text.as_mut_ptr(),
                    ..unsafe { zeroed() }
                };
                unsafe {
                    SendMessageW(
                        state.list_window,
                        LVM_SETITEMTEXTW,
                        row,
                        (&mut native as *mut LVITEMW) as isize,
                    )
                };
            }
        }
    }
    for button in state.left_buttons.iter().chain(&state.right_buttons) {
        unsafe { EnableWindow(*button, i32::from(!state.model.is_empty())) };
    }
}

unsafe fn create_menu() -> HMENU {
    let menu = unsafe { CreateMenu() };
    let file = unsafe { CreatePopupMenu() };
    unsafe {
        menu_item(file, ADD_FILES, "경로목록에 파일 추가하기\tCtrl+O");
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, APPLY, "실제 파일 변경\tCtrl+S");
        menu_item(file, RESET, "원래 이름으로\tCtrl+Z");
        menu_item(file, CLEAR_LIST, "경로목록 지우기\tCtrl+L");
        menu_item(file, SORT, "경로목록 정렬\tCtrl+A");
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, COPY_NAMES, "클립보드로 바꿀이름 복사\tCtrl+C");
        menu_item(file, SAVE_NAMES, "문서파일로 바꿀이름 저장\tCtrl+X");
        menu_item(file, COPY_PATHS, "클립보드로 경로목록 복사\tCtrl+Shift+C");
        menu_item(file, SAVE_PATHS, "문서파일로 경로목록 저장\tCtrl+Shift+X");
        menu_item(file, IMPORT_NAMES, "바꿀이름 불러오기\tCtrl+V");
        menu_item(file, IMPORT_PATHS, "경로목록 불러오기\tCtrl+Shift+V");
        append_popup(menu, file, "파일(&F)");
        let edit = CreatePopupMenu();
        menu_item(edit, MOVE_UP, "위로 올림\t<");
        menu_item(edit, MOVE_DOWN, "아래로 내림\t>");
        menu_item(edit, MANUAL_CHANGE, "직접 바꾸기");
        append_popup(menu, edit, "편집(&E)");
        let view = CreatePopupMenu();
        menu_item(view, SHOW_FULL_PATH, "전체 경로 표시");
        menu_item(view, SHOW_SIZE, "파일 크기 표시");
        menu_item(view, SHOW_MODIFIED, "변경 시각 표시");
        menu_item(view, SHOW_CREATED, "생성 시각 표시");
        append_popup(menu, view, "보기(&V)");
        let tools = CreatePopupMenu();
        for tool in [
            REPLACE,
            PREFIX,
            SUFFIX,
            CLEAR_NAME,
            DELETE_POSITION,
            DELETE_DELIMITED,
            KEEP_DIGITS,
            PAD_DIGITS,
            SEQUENCE,
            EXT_DELETE,
            EXT_ADD,
            EXT_REPLACE,
            PARENT_PREFIX,
            PARENT_SUFFIX,
            UNIFY_PATH,
        ] {
            let label = LEFT_TOOLS
                .iter()
                .chain(&RIGHT_TOOLS)
                .find(|entry| entry.id == tool)
                .map_or("명령", |entry| entry.label.replace('\n', " ").leak());
            menu_item(tools, tool, label);
        }
        append_popup(menu, tools, "기능(&T)");
        menu_item(menu, VERSION, "버전(H)");
    }
    menu
}

unsafe fn menu_item(menu: HMENU, id: u16, label: &str) {
    let label = wide(label);
    unsafe { AppendMenuW(menu, MF_STRING, usize::from(id), label.as_ptr()) };
}

unsafe fn append_popup(menu: HMENU, popup: HMENU, label: &str) {
    let label = wide(label);
    unsafe { AppendMenuW(menu, MF_POPUP, popup as usize, label.as_ptr()) };
}

unsafe fn message(owner: HWND, text: &str, caption: &str) {
    let text = wide(text);
    let caption = wide(caption);
    unsafe { MessageBoxW(owner, text.as_ptr(), caption.as_ptr(), 0) };
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain([0]).collect()
}
