#![allow(
    clippy::undocumented_unsafe_blocks,
    reason = "all unsafe operations are confined to this Win32 boundary; entry-point invariants are documented"
)]

use std::ffi::c_void;
use std::fs;
use std::io;
use std::mem::{size_of, zeroed};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::slice;

use darknamer_core::{
    LegacyInputError, LegacyList, LegacyListItem, LegacySequenceMode, LegacySortMode, LegacyText,
};
use windows_sys::Win32::Foundation::{
    FILETIME, GlobalFree, HANDLE, HWND, LPARAM, LRESULT, RECT, SYSTEMTIME, WPARAM,
};
use windows_sys::Win32::Globalization::{
    CP_ACP, CSTR_GREATER_THAN, CSTR_LESS_THAN, CompareStringW, LOCALE_USER_DEFAULT,
    MultiByteToWideChar, NORM_IGNORECASE,
};
use windows_sys::Win32::Graphics::Gdi::{
    CLIP_DEFAULT_PRECIS, COLOR_WINDOW, CreateFontW, DEFAULT_CHARSET, DEFAULT_PITCH,
    DEFAULT_QUALITY, DeleteObject, FF_DONTCARE, FW_NORMAL, HFONT, OUT_DEFAULT_PRECIS, UpdateWindow,
};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL, MoveFileW,
};
use windows_sys::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize};
use windows_sys::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};
use windows_sys::Win32::System::Ole::CF_UNICODETEXT;
use windows_sys::Win32::System::SystemServices::{SS_CENTERIMAGE, SS_ETCHEDHORZ, SS_SUNKEN};
use windows_sys::Win32::System::Time::FileTimeToSystemTime;
use windows_sys::Win32::UI::Controls::{
    CCS_NOPARENTALIGN, CCS_NORESIZE, CCS_VERT, ICC_BAR_CLASSES, ICC_LISTVIEW_CLASSES,
    INITCOMMONCONTROLSEX, InitCommonControlsEx, LVCF_FMT, LVCF_TEXT, LVCF_WIDTH, LVCFMT_LEFT,
    LVCFMT_RIGHT, LVCOLUMNW, LVIF_IMAGE, LVIF_TEXT, LVIS_FOCUSED, LVIS_SELECTED, LVITEMW,
    LVM_DELETEALLITEMS, LVM_ENSUREVISIBLE, LVM_GETNEXTITEM, LVM_INSERTCOLUMNW, LVM_INSERTITEMW,
    LVM_SETCOLUMNWIDTH, LVM_SETEXTENDEDLISTVIEWSTYLE, LVM_SETIMAGELIST, LVM_SETITEMSTATE,
    LVM_SETITEMTEXTW, LVN_ITEMCHANGED, LVNI_FOCUSED, LVNI_SELECTED, LVS_EX_FULLROWSELECT,
    LVS_NOSORTHEADER, LVS_REPORT, LVS_SHAREIMAGELISTS, LVS_SHOWSELALWAYS, LVSIL_SMALL, NM_DBLCLK,
    NMHDR, NMLISTVIEW, TB_ADDBITMAP, TB_ADDBUTTONS, TB_BUTTONSTRUCTSIZE, TB_ENABLEBUTTON,
    TB_SETBITMAPSIZE, TB_SETBUTTONSIZE, TBADDBITMAP, TBBUTTON, TBSTATE_ENABLED, TBSTYLE_BUTTON,
    TBSTYLE_FLAT, TBSTYLE_SEP, TBSTYLE_TOOLTIPS, TBSTYLE_WRAPABLE, TOOLBARCLASSNAMEW,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetKeyState, SetFocus, VK_CONTROL, VK_DELETE, VK_ESCAPE, VK_SHIFT,
};
use windows_sys::Win32::UI::Shell::{
    DragAcceptFiles, DragFinish, DragQueryFileW, HDROP, SHFILEINFOW, SHGFI_SMALLICON,
    SHGFI_SYSICONINDEX, SHGFI_USEFILEATTRIBUTES, SHGetFileInfoW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, BN_CLICKED, BS_DEFPUSHBUTTON, CB_ADDSTRING, CB_GETCURSEL, CB_SETCURSEL,
    CBS_DROPDOWNLIST, CREATESTRUCTW, CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, CheckMenuItem,
    CreateMenu, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW,
    DrawMenuBar, ES_AUTOHSCROLL, EnableMenuItem, GWLP_USERDATA, GetClientRect, GetMessageW,
    GetParent, GetWindowLongPtrW, GetWindowTextLengthW, GetWindowTextW, HMENU, IDC_ARROW, IDCANCEL,
    IDOK, IsDialogMessageW, LoadCursorW, LoadIconW, MB_OKCANCEL, MB_YESNO, MF_BYCOMMAND,
    MF_CHECKED, MF_ENABLED, MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, MF_UNCHECKED, MSG,
    MessageBoxW, MoveWindow, PostQuitMessage, RegisterClassExW, SW_SHOW, SendMessageW,
    SetForegroundWindow, SetMenu, SetWindowLongPtrW, ShowWindow, TranslateMessage, WM_CLOSE,
    WM_COMMAND, WM_CREATE, WM_DESTROY, WM_DROPFILES, WM_KEYDOWN, WM_KEYUP, WM_NCCREATE,
    WM_NCDESTROY, WM_NOTIFY, WM_SETFONT, WM_SIZE, WNDCLASSEXW, WS_BORDER, WS_CAPTION, WS_CHILD,
    WS_CLIPCHILDREN, WS_EX_ACCEPTFILES, WS_EX_APPWINDOW, WS_EX_TOOLWINDOW, WS_MAXIMIZEBOX,
    WS_MINIMIZEBOX, WS_OVERLAPPEDWINDOW, WS_POPUP, WS_SYSMENU, WS_TABSTOP, WS_VISIBLE,
};

use crate::*;

const LIST_ID: usize = 1000;
const LEFT_TOOLBAR_ID: usize = 1001;
const RIGHT_TOOLBAR_ID: usize = 1002;
const STATUS_ID: usize = 1007;

struct AppState {
    list_window: HWND,
    status: HWND,
    menu: HMENU,
    font: HFONT,
    left_toolbar: HWND,
    right_toolbar: HWND,
    model: LegacyList,
    shown_columns: [bool; 4],
    directory_mode: Option<DirectoryMode>,
    command_states: [bool; 34],
}

struct WindowInit {
    state: *mut AppState,
    adopted: *mut bool,
}

impl AppState {
    fn new() -> Self {
        Self {
            list_window: null_mut(),
            status: null_mut(),
            menu: null_mut(),
            font: null_mut(),
            left_toolbar: null_mut(),
            right_toolbar: null_mut(),
            model: LegacyList::new(),
            shown_columns: [false; 4],
            directory_mode: None,
            command_states: [false; 34],
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DirectoryMode {
    Recurse,
    Direct,
}

struct ComGuard;

impl Drop for ComGuard {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

pub(crate) fn run() -> io::Result<()> {
    // SAFETY: All Win32 handles are created and consumed on this UI thread;
    // pointers passed to Win32 remain valid for each synchronous call.
    unsafe { run_unsafe() }
}

unsafe fn run_unsafe() -> io::Result<()> {
    let com_status = unsafe { CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) };
    if com_status < 0 {
        return Err(io::Error::from_raw_os_error(com_status));
    }
    let _com = ComGuard;
    let controls = INITCOMMONCONTROLSEX {
        dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
        dwICC: ICC_LISTVIEW_CLASSES | ICC_BAR_CLASSES,
    };
    // SAFETY: controls points to a fully initialized structure.
    unsafe { InitCommonControlsEx(&controls) };
    // SAFETY: null requests the current module handle.
    let instance = unsafe { GetModuleHandleW(null()) };
    if instance.is_null() {
        return Err(io::Error::last_os_error());
    }
    let class_name = wide("DarkNamerLegacyWindow");
    let icon = unsafe { LoadIconW(instance, int_resource(1)) };
    let window_class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(window_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        hIcon: icon,
        // SAFETY: IDC_ARROW is a predefined resource identifier.
        hCursor: unsafe { LoadCursorW(null_mut(), IDC_ARROW) },
        hbrBackground: (COLOR_WINDOW + 1) as *mut c_void,
        lpszMenuName: null(),
        lpszClassName: class_name.as_ptr(),
        hIconSm: icon,
    };
    // SAFETY: class strings and callback remain valid for the process lifetime.
    if unsafe { RegisterClassExW(&window_class) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let title = wide("DarkNamer");
    let state = Box::into_raw(Box::new(AppState::new()));
    let mut adopted = false;
    let mut init = WindowInit {
        state,
        adopted: &mut adopted,
    };
    // SAFETY: init remains live for the synchronous CreateWindowExW call. The
    // state ownership transfers only when WM_NCCREATE marks it adopted.
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
            unsafe { drop(Box::from_raw(state)) };
        }
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
        if unsafe { handle_accelerator(window, &message) } {
            continue;
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
            let init = unsafe { (*create).lpCreateParams as *mut WindowInit };
            if !init.is_null() {
                unsafe {
                    *(*init).adopted = true;
                    SetWindowLongPtrW(window, GWLP_USERDATA, (*init).state as isize);
                }
            }
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
            unsafe { admit_drop(window, &mut *state_ptr, wparam as HDROP) };
            0
        }
        WM_NOTIFY if !state_ptr.is_null() => {
            let header = lparam as *const NMHDR;
            if !header.is_null()
                && unsafe { (*header).hwndFrom } == unsafe { (*state_ptr).list_window }
            {
                if unsafe { (*header).code } == LVN_ITEMCHANGED {
                    let notification = lparam as *const NMLISTVIEW;
                    if !notification.is_null()
                        && selection_command_state_changed(
                            unsafe { (*notification).uChanged },
                            unsafe { (*notification).uOldState },
                            unsafe { (*notification).uNewState },
                        )
                    {
                        unsafe { update_controls(&mut *state_ptr) };
                    }
                } else if unsafe { (*header).code } == NM_DBLCLK {
                    let previous_states = unsafe { (*state_ptr).command_states };
                    unsafe { dispatch_command(window, &mut *state_ptr, MANUAL_CHANGE) };
                    unsafe {
                        (*state_ptr).command_states = previous_states;
                        apply_command_states(&*state_ptr);
                    }
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
                if !unsafe { (*state_ptr).font }.is_null() {
                    unsafe { DeleteObject((*state_ptr).font) };
                }
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
                | LVS_SHAREIMAGELISTS
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
    state.status = unsafe {
        child(
            window,
            "STATIC",
            "",
            STATUS_ID as u16,
            SS_CENTERIMAGE | SS_SUNKEN,
        )
    };
    state.left_toolbar =
        unsafe { create_toolbar(window, instance, LEFT_TOOLBAR_ID, 130, &LEFT_TOOLBAR_ITEMS)? };
    state.right_toolbar = unsafe {
        create_toolbar(
            window,
            instance,
            RIGHT_TOOLBAR_ID,
            132,
            &RIGHT_TOOLBAR_ITEMS,
        )?
    };
    let face = wide("MS Sans Serif");
    state.font = unsafe {
        CreateFontW(
            -13,
            0,
            0,
            0,
            FW_NORMAL as i32,
            0,
            0,
            0,
            u32::from(DEFAULT_CHARSET),
            u32::from(OUT_DEFAULT_PRECIS),
            u32::from(CLIP_DEFAULT_PRECIS),
            u32::from(DEFAULT_QUALITY),
            u32::from(DEFAULT_PITCH | FF_DONTCARE),
            face.as_ptr(),
        )
    };
    if !state.font.is_null() {
        for control in [&state.list_window, &state.status] {
            unsafe { SendMessageW(*control, WM_SETFONT, state.font as usize, 1) };
        }
    }
    // SAFETY: window is a live top-level HWND configured for shell drops.
    unsafe { DragAcceptFiles(window, 1) };
    let menu = unsafe { create_menu() };
    state.menu = menu;
    // SAFETY: menu ownership transfers to the top-level window.
    unsafe { SetMenu(window, menu) };
    let mut shell_info: SHFILEINFOW = unsafe { zeroed() };
    let empty = wide("");
    let image_list = unsafe {
        SHGetFileInfoW(
            empty.as_ptr(),
            0,
            &mut shell_info,
            size_of::<SHFILEINFOW>() as u32,
            SHGFI_SYSICONINDEX | SHGFI_SMALLICON,
        )
    };
    if image_list != 0 {
        unsafe {
            SendMessageW(
                state.list_window,
                LVM_SETIMAGELIST,
                LVSIL_SMALL as usize,
                image_list as isize,
            )
        };
    }
    unsafe { arrange(window, state) };
    unsafe { refresh(state) };
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

unsafe fn create_toolbar(
    parent: HWND,
    instance: windows_sys::Win32::Foundation::HINSTANCE,
    control_id: usize,
    resource_id: u16,
    items: &[ToolbarItem],
) -> io::Result<HWND> {
    let styles = WS_CHILD
        | WS_VISIBLE
        | TBSTYLE_FLAT
        | TBSTYLE_TOOLTIPS
        | TBSTYLE_WRAPABLE
        | CCS_VERT as u32
        | CCS_NORESIZE as u32
        | CCS_NOPARENTALIGN as u32;
    let toolbar = unsafe {
        CreateWindowExW(
            0,
            TOOLBARCLASSNAMEW,
            null(),
            styles,
            0,
            0,
            0,
            0,
            parent,
            control_id as *mut c_void,
            instance,
            null_mut(),
        )
    };
    if toolbar.is_null() {
        return Err(io::Error::last_os_error());
    }
    unsafe {
        SendMessageW(toolbar, TB_BUTTONSTRUCTSIZE, size_of::<TBBUTTON>(), 0);
        SendMessageW(
            toolbar,
            TB_SETBITMAPSIZE,
            0,
            packed_dimensions(TOOLBAR_BITMAP_WIDTH, TOOLBAR_BITMAP_HEIGHT),
        );
        SendMessageW(
            toolbar,
            TB_SETBUTTONSIZE,
            0,
            packed_dimensions(TOOLBAR_WIDTH, TOOLBAR_BUTTON_HEIGHT),
        );
    }
    let bitmap_count = items
        .iter()
        .filter(|item| matches!(item, ToolbarItem::Command(_)))
        .count();
    let bitmap = TBADDBITMAP {
        hInst: instance,
        nID: usize::from(resource_id),
    };
    let first_bitmap = unsafe {
        SendMessageW(
            toolbar,
            TB_ADDBITMAP,
            bitmap_count,
            (&raw const bitmap) as isize,
        )
    };
    let first_bitmap = i32::try_from(first_bitmap)
        .ok()
        .filter(|index| *index >= 0)
        .ok_or_else(|| io::Error::other("could not load native toolbar bitmap resource"))?;
    let mut image_index = 0_i32;
    let buttons = items
        .iter()
        .map(|item| match *item {
            ToolbarItem::Command(command) => {
                let button = TBBUTTON {
                    iBitmap: first_bitmap + image_index,
                    idCommand: i32::from(command),
                    fsState: TBSTATE_ENABLED as u8,
                    fsStyle: TBSTYLE_BUTTON as u8,
                    ..TBBUTTON::default()
                };
                image_index += 1;
                button
            }
            ToolbarItem::Separator => TBBUTTON {
                iBitmap: TOOLBAR_SEPARATOR_SIZE,
                fsStyle: TBSTYLE_SEP as u8,
                ..TBBUTTON::default()
            },
        })
        .collect::<Vec<_>>();
    let added = unsafe {
        SendMessageW(
            toolbar,
            TB_ADDBUTTONS,
            buttons.len(),
            buttons.as_ptr() as isize,
        )
    };
    if added == 0 {
        return Err(io::Error::other("could not add native toolbar buttons"));
    }
    Ok(toolbar)
}

const fn packed_dimensions(width: i32, height: i32) -> isize {
    ((width as u32 & 0xFFFF) | ((height as u32 & 0xFFFF) << 16)) as isize
}

unsafe fn arrange(window: HWND, state: &AppState) {
    // SAFETY: rect is writable and window is live.
    let mut rect: RECT = unsafe { zeroed() };
    unsafe { GetClientRect(window, &mut rect) };
    let width = rect.right.max(TOOLBAR_WIDTH * 2 + 1);
    let height = rect.bottom.max(STATUS_HEIGHT + 1);
    unsafe {
        MoveWindow(
            state.left_toolbar,
            0,
            0,
            TOOLBAR_WIDTH,
            height - STATUS_HEIGHT,
            1,
        );
        MoveWindow(
            state.right_toolbar,
            width - TOOLBAR_WIDTH,
            0,
            TOOLBAR_WIDTH,
            height - STATUS_HEIGHT,
            1,
        );
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

#[derive(Clone, Debug)]
struct PromptSpec {
    title: String,
    label_one: String,
    label_two: String,
    value_one: LegacyText,
    value_two: LegacyText,
    choices: Vec<String>,
}

#[derive(Clone, Debug)]
struct PromptResult {
    value_one: LegacyText,
    value_two: LegacyText,
    choice: usize,
}

struct PromptState {
    spec: PromptSpec,
    result: Option<PromptResult>,
    done: bool,
    edit_one: HWND,
    edit_two: HWND,
    combo: HWND,
    font: HFONT,
}

unsafe fn prompt_input(owner: HWND, spec: PromptSpec) -> Option<PromptResult> {
    let instance = unsafe { GetModuleHandleW(null()) };
    let class_name = wide("DarkNamerInputWindow");
    let caption = wide("입력창");
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(prompt_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        hIcon: null_mut(),
        hCursor: unsafe { LoadCursorW(null_mut(), IDC_ARROW) },
        hbrBackground: (COLOR_WINDOW + 1) as *mut c_void,
        lpszMenuName: null(),
        lpszClassName: class_name.as_ptr(),
        hIconSm: null_mut(),
    };
    unsafe { RegisterClassExW(&class) };
    let mut state = Box::new(PromptState {
        spec,
        result: None,
        done: false,
        edit_one: null_mut(),
        edit_two: null_mut(),
        combo: null_mut(),
        font: null_mut(),
    });
    let state_ptr: *mut PromptState = &mut *state;
    let dialog = unsafe {
        CreateWindowExW(
            WS_EX_TOOLWINDOW,
            class_name.as_ptr(),
            caption.as_ptr(),
            WS_POPUP | WS_CAPTION | WS_SYSMENU,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            380,
            210,
            owner,
            null_mut(),
            instance,
            state_ptr.cast(),
        )
    };
    if dialog.is_null() {
        return None;
    }
    unsafe {
        EnableWindow(owner, 0);
        ShowWindow(dialog, SW_SHOW);
        UpdateWindow(dialog);
    }
    let mut message: MSG = unsafe { zeroed() };
    while !state.done {
        let status = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if status <= 0 {
            state.done = true;
            break;
        }
        if unsafe { IsDialogMessageW(dialog, &message) } == 0 {
            unsafe {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }
    unsafe {
        EnableWindow(owner, 1);
        SetForegroundWindow(owner);
    }
    state.result.take()
}

unsafe extern "system" fn prompt_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        let create = lparam as *const CREATESTRUCTW;
        if !create.is_null() {
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, (*create).lpCreateParams as isize) };
        }
    }
    let state_ptr = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut PromptState;
    match message {
        WM_CREATE if !state_ptr.is_null() => {
            let state = unsafe { &mut *state_ptr };
            let title = unsafe { child(window, "STATIC", &state.spec.title, 1001, 0) };
            unsafe { MoveWindow(title, 12, 12, 340, 22, 1) };
            let mut controls = vec![title];
            if !state.spec.label_one.is_empty() {
                let edit = unsafe {
                    child(
                        window,
                        "EDIT",
                        &state.spec.value_one.to_string_lossy(),
                        1004,
                        WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                    )
                };
                let label = unsafe { child(window, "STATIC", &state.spec.label_one, 1002, 0) };
                unsafe {
                    MoveWindow(edit, 12, 48, 275, 25, 1);
                    MoveWindow(label, 294, 48, 70, 25, 1);
                }
                state.edit_one = edit;
                controls.extend([edit, label]);
            }
            if !state.spec.label_two.is_empty() {
                let edit = unsafe {
                    child(
                        window,
                        "EDIT",
                        &state.spec.value_two.to_string_lossy(),
                        1005,
                        WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                    )
                };
                let label = unsafe { child(window, "STATIC", &state.spec.label_two, 1003, 0) };
                unsafe {
                    MoveWindow(edit, 12, 80, 275, 25, 1);
                    MoveWindow(label, 294, 80, 70, 25, 1);
                }
                state.edit_two = edit;
                controls.extend([edit, label]);
            }
            if !state.spec.choices.is_empty() {
                let combo = unsafe {
                    child(
                        window,
                        "COMBOBOX",
                        "",
                        1006,
                        WS_TABSTOP | CBS_DROPDOWNLIST as u32,
                    )
                };
                for choice in &state.spec.choices {
                    let choice = wide(choice);
                    unsafe {
                        SendMessageW(combo, CB_ADDSTRING, 0, choice.as_ptr() as isize);
                    }
                }
                unsafe {
                    SendMessageW(combo, CB_SETCURSEL, 0, 0);
                    MoveWindow(
                        combo,
                        12,
                        if state.spec.label_one.is_empty() && state.spec.label_two.is_empty() {
                            60
                        } else {
                            126
                        },
                        185,
                        160,
                        1,
                    );
                }
                state.combo = combo;
                controls.push(combo);
            }
            let ok = unsafe {
                child(
                    window,
                    "BUTTON",
                    "확인",
                    IDOK as u16,
                    WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
                )
            };
            let cancel = unsafe { child(window, "BUTTON", "취소", IDCANCEL as u16, WS_TABSTOP) };
            let separator = unsafe { child(window, "STATIC", "", 1010, SS_ETCHEDHORZ) };
            unsafe {
                MoveWindow(ok, 205, 126, 75, 32, 1);
                MoveWindow(cancel, 285, 126, 75, 32, 1);
                MoveWindow(separator, 0, 116, 380, 2, 1);
            }
            controls.extend([ok, cancel, separator]);
            let face = wide("MS Sans Serif");
            state.font = unsafe {
                CreateFontW(
                    -13,
                    0,
                    0,
                    0,
                    FW_NORMAL as i32,
                    0,
                    0,
                    0,
                    u32::from(DEFAULT_CHARSET),
                    u32::from(OUT_DEFAULT_PRECIS),
                    u32::from(CLIP_DEFAULT_PRECIS),
                    u32::from(DEFAULT_QUALITY),
                    u32::from(DEFAULT_PITCH | FF_DONTCARE),
                    face.as_ptr(),
                )
            };
            if !state.font.is_null() {
                for control in controls {
                    unsafe { SendMessageW(control, WM_SETFONT, state.font as usize, 1) };
                }
            }
            let first = if !state.edit_one.is_null() {
                state.edit_one
            } else {
                state.combo
            };
            if !first.is_null() {
                unsafe { SetFocus(first) };
            }
            0
        }
        WM_COMMAND if !state_ptr.is_null() => {
            let id = (wparam & 0xFFFF) as i32;
            let notification = ((wparam >> 16) & 0xFFFF) as u32;
            if notification == BN_CLICKED && id == IDOK {
                let state = unsafe { &mut *state_ptr };
                state.result = Some(PromptResult {
                    value_one: unsafe { window_text(state.edit_one) },
                    value_two: unsafe { window_text(state.edit_two) },
                    choice: if state.combo.is_null() {
                        0
                    } else {
                        usize::try_from(unsafe { SendMessageW(state.combo, CB_GETCURSEL, 0, 0) })
                            .unwrap_or(0)
                    },
                });
                state.done = true;
                unsafe { DestroyWindow(window) };
            } else if notification == BN_CLICKED && id == IDCANCEL {
                unsafe { (*state_ptr).done = true };
                unsafe { DestroyWindow(window) };
            }
            0
        }
        WM_CLOSE if !state_ptr.is_null() => {
            unsafe { (*state_ptr).done = true };
            unsafe { DestroyWindow(window) };
            0
        }
        WM_NCDESTROY if !state_ptr.is_null() => {
            if !unsafe { (*state_ptr).font }.is_null() {
                unsafe { DeleteObject((*state_ptr).font) };
                unsafe { (*state_ptr).font = null_mut() };
            }
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
}

unsafe fn window_text(window: HWND) -> LegacyText {
    if window.is_null() {
        return LegacyText::default();
    }
    let length = unsafe { GetWindowTextLengthW(window) };
    if length <= 0 {
        return LegacyText::default();
    }
    let mut value = vec![0_u16; length as usize + 1];
    let copied = unsafe { GetWindowTextW(window, value.as_mut_ptr(), value.len() as i32) };
    value.truncate(copied.max(0) as usize);
    LegacyText::from_units(value)
}

unsafe fn handle_accelerator(window: HWND, message: &MSG) -> bool {
    let ctrl = unsafe { GetKeyState(VK_CONTROL as i32) } < 0;
    let shift = unsafe { GetKeyState(VK_SHIFT as i32) } < 0;
    let command = if message.message == WM_KEYDOWN {
        match message.wParam as u32 {
            value if value == u32::from(VK_DELETE) => Some(0xFFFF),
            0xBC => Some(MOVE_UP),
            0xBE => Some(MOVE_DOWN),
            value if value == u32::from(VK_ESCAPE) => Some(2),
            _ => None,
        }
    } else if message.message == WM_KEYUP && ctrl {
        match message.wParam as u32 {
            0x4F => Some(ADD_FILES),
            0x53 => Some(APPLY),
            0x5A => Some(RESET),
            0x4C => Some(CLEAR_LIST),
            0x41 => Some(SORT),
            0x43 => Some(if shift { COPY_PATHS } else { COPY_NAMES }),
            0x58 => Some(if shift { SAVE_PATHS } else { SAVE_NAMES }),
            0x56 => Some(if shift { IMPORT_PATHS } else { IMPORT_NAMES }),
            _ => None,
        }
    } else {
        None
    };
    if let Some(command) = command {
        let state = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut AppState;
        if command != 0xFFFF && command != 2 && !state.is_null() {
            let selected = unsafe { selected_indices((*state).list_window) }.len();
            if !command_enabled(command, unsafe { (*state).model.len() }, selected) {
                return true;
            }
        }
        let previous_states = (!state.is_null()).then(|| unsafe { (*state).command_states });
        unsafe { SendMessageW(window, WM_COMMAND, usize::from(command), 0) };
        let list_was_cleared = !state.is_null()
            && (command == CLEAR_LIST
                || (command == 0xFFFF && unsafe { (*state).model.is_empty() }));
        if command != 2
            && !list_was_cleared
            && !state.is_null()
            && let Some(previous_states) = previous_states
        {
            unsafe {
                (*state).command_states = previous_states;
                apply_command_states(&*state);
            }
        }
        true
    } else {
        false
    }
}

unsafe fn selected_indices(list: HWND) -> Vec<usize> {
    let mut indices = Vec::new();
    let mut index = -1_i32;
    loop {
        index = unsafe {
            SendMessageW(
                list,
                LVM_GETNEXTITEM,
                index as usize,
                LVNI_SELECTED as isize,
            ) as i32
        };
        if index < 0 {
            break;
        }
        indices.push(index as usize);
    }
    indices
}

unsafe fn select_rows(list: HWND, rows: &[usize]) {
    unsafe { select_rows_with_focus(list, rows, rows.first().copied()) };
}

unsafe fn focused_index(list: HWND) -> Option<usize> {
    let index = unsafe { SendMessageW(list, LVM_GETNEXTITEM, usize::MAX, LVNI_FOCUSED as isize) };
    (index >= 0).then_some(index as usize)
}

unsafe fn select_rows_with_focus(list: HWND, rows: &[usize], focused: Option<usize>) {
    for row in rows {
        let mut item = LVITEMW {
            stateMask: LVIS_SELECTED | LVIS_FOCUSED,
            state: LVIS_SELECTED
                | if Some(*row) == focused {
                    LVIS_FOCUSED
                } else {
                    0
                },
            ..unsafe { zeroed() }
        };
        unsafe {
            SendMessageW(
                list,
                LVM_SETITEMSTATE,
                *row,
                (&mut item as *mut LVITEMW) as isize,
            );
        }
    }
    if let Some(row) = rows.first() {
        unsafe { SendMessageW(list, LVM_ENSUREVISIBLE, *row, 0) };
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SelectionToken {
    path: LegacyText,
    occurrence: usize,
}

fn selection_tokens(model: &LegacyList, selected: &[usize]) -> Vec<SelectionToken> {
    selected
        .iter()
        .filter_map(|index| model.items().get(*index).map(|item| (*index, item)))
        .map(|(index, item)| SelectionToken {
            path: item.source_path().clone(),
            occurrence: model.items()[..index]
                .iter()
                .filter(|previous| previous.source_path() == item.source_path())
                .count(),
        })
        .collect()
}

fn selection_token(model: &LegacyList, index: usize) -> Option<SelectionToken> {
    model.items().get(index).map(|item| SelectionToken {
        path: item.source_path().clone(),
        occurrence: model.items()[..index]
            .iter()
            .filter(|previous| previous.source_path() == item.source_path())
            .count(),
    })
}

fn rows_for_tokens(model: &LegacyList, tokens: &[SelectionToken]) -> Vec<usize> {
    tokens
        .iter()
        .filter_map(|token| {
            model
                .items()
                .iter()
                .enumerate()
                .filter(|(_index, item)| item.source_path() == &token.path)
                .nth(token.occurrence)
                .map(|(index, _item)| index)
        })
        .collect()
}

unsafe fn dispatch_command(window: HWND, state: &mut AppState, command: u16) {
    let selected = unsafe { selected_indices(state.list_window) };
    match command {
        APPLY => unsafe { apply_changes(window, state) },
        RESET => state.model.reset_proposals(),
        CLEAR_LIST => state.model = LegacyList::new(),
        0xFFFF => {
            unsafe { clear_selection(state.list_window) };
            state.model.remove_rows(&selected);
        }
        MOVE_UP => {
            let focused_position = unsafe { focused_index(state.list_window) }
                .and_then(|focused| selected.iter().position(|index| *index == focused));
            unsafe { clear_selection(state.list_window) };
            let moved = state.model.move_rows_earlier(&selected);
            unsafe { refresh(state) };
            let focused = focused_position.and_then(|position| moved.get(position).copied());
            unsafe {
                select_rows_with_focus(state.list_window, &moved, focused);
                update_controls(state);
            }
            return;
        }
        MOVE_DOWN => {
            let focused_position = unsafe { focused_index(state.list_window) }
                .and_then(|focused| selected.iter().position(|index| *index == focused));
            unsafe { clear_selection(state.list_window) };
            let moved = state.model.move_rows_later(&selected);
            unsafe { refresh(state) };
            let focused = focused_position.and_then(|position| moved.get(position).copied());
            unsafe {
                select_rows_with_focus(state.list_window, &moved, focused);
                update_controls(state);
            }
            return;
        }
        MANUAL_CHANGE => {
            if let Some(index) = selected.first().copied() {
                let current = state.model.items()[index].proposed_name().clone();
                if let Some(result) = unsafe {
                    prompt_input(
                        window,
                        prompt_spec(
                            format!("{} 를", current.to_string_lossy()),
                            "으로",
                            "",
                            current,
                            LegacyText::default(),
                            &[],
                        ),
                    )
                } {
                    state.model.manual_change(index, result.value_one);
                }
            }
        }
        REPLACE => {
            if let Some(result) = unsafe {
                prompt_input(
                    window,
                    prompt_spec(
                        "이름에 들어있는 문자열을 바꿉니다.",
                        "를",
                        "으로",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state
                    .model
                    .replace_complete(&result.value_one, &result.value_two);
            }
        }
        PREFIX => {
            if let Some(result) = unsafe {
                prompt_input(
                    window,
                    prompt_spec(
                        "이름의 앞에 지정한 문자열을 붙여줍니다.",
                        "붙일 문자열",
                        "",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state.model.prefix_complete(&result.value_one);
            }
        }
        SUFFIX => {
            if let Some(result) = unsafe {
                prompt_input(
                    window,
                    prompt_spec(
                        "이름의 뒤에 지정한 문자열을 붙여줍니다.",
                        "붙일 문자열",
                        "",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state.model.suffix_before_extension(&result.value_one);
            }
        }
        CLEAR_NAME => state.model.clear_name(),
        DELETE_POSITION => unsafe { delete_position_command(window, state) },
        DELETE_DELIMITED => unsafe { delete_delimited_command(window, state) },
        KEEP_DIGITS => state.model.keep_ascii_digits(),
        PAD_DIGITS => unsafe { pad_digits_command(window, state) },
        SEQUENCE => unsafe { sequence_command(window, state) },
        SORT => {
            if unsafe { sort_command(window, state) } {
                return;
            }
        }
        EXT_DELETE => state.model.delete_extension(),
        EXT_ADD => {
            if let Some(result) = unsafe {
                prompt_input(
                    window,
                    prompt_spec(
                        "확장자를 뒤에 붙입니다.",
                        "붙일 확장자",
                        "",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state.model.add_extension(&result.value_one);
            }
        }
        EXT_REPLACE => {
            if let Some(result) = unsafe {
                prompt_input(
                    window,
                    prompt_spec(
                        "확장자를 바꿔 줍니다.",
                        "바꿀 확장자",
                        "",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state.model.replace_extension(&result.value_one);
            }
        }
        PARENT_PREFIX => state.model.prefix_parent_folder(),
        PARENT_SUFFIX => state.model.suffix_parent_folder(),
        UNIFY_PATH => {
            if let Some(path) = modal_native_dialog(window, || {
                rfd::FileDialog::new().set_title("경로 선택").pick_folder()
            }) {
                state.model.unify_root_path(&legacy_path(&path));
            }
        }
        ADD_FILES => unsafe { add_files_dialog(window, state) },
        COPY_NAMES => unsafe { copy_clipboard(window, &state.model.export_names()) },
        COPY_PATHS => unsafe { copy_clipboard(window, &state.model.export_paths()) },
        SAVE_NAMES => unsafe { save_text_dialog(window, state.model.export_names(), true) },
        SAVE_PATHS => unsafe { save_text_dialog(window, state.model.export_paths(), false) },
        IMPORT_NAMES => unsafe { import_names_dialog(window, state) },
        IMPORT_PATHS => unsafe { import_paths_dialog(window, state) },
        SHOW_FULL_PATH | SHOW_SIZE | SHOW_MODIFIED | SHOW_CREATED => {
            let index = usize::from(command - SHOW_FULL_PATH);
            state.shown_columns[index] = !state.shown_columns[index];
            unsafe { update_column_visibility(state, index) };
        }
        VERSION => unsafe { message(window, "DarkNamer 08.02.10 버전", "DarkNamer") },
        2 => unsafe {
            DestroyWindow(window);
            return;
        },
        _ => {}
    }
    unsafe { refresh(state) };
}

fn prompt_spec(
    title: impl Into<String>,
    label_one: &str,
    label_two: &str,
    value_one: LegacyText,
    value_two: LegacyText,
    choices: &[&str],
) -> PromptSpec {
    PromptSpec {
        title: title.into(),
        label_one: label_one.to_owned(),
        label_two: label_two.to_owned(),
        value_one,
        value_two,
        choices: choices.iter().map(|choice| (*choice).to_owned()).collect(),
    }
}

fn legacy_atoi(text: &LegacyText) -> i32 {
    let value = text.to_string_lossy();
    let mut characters = value.trim_start().chars().peekable();
    let sign = match characters.peek().copied() {
        Some('-') => {
            characters.next();
            -1_i64
        }
        Some('+') => {
            characters.next();
            1_i64
        }
        _ => 1_i64,
    };
    let mut found = false;
    let mut number = 0_i64;
    while let Some(character) = characters.peek().copied() {
        if !character.is_ascii_digit() {
            break;
        }
        let digit = u32::from(character as u8 - b'0');
        found = true;
        characters.next();
        number = number.saturating_mul(10).saturating_add(i64::from(digit));
    }
    if !found {
        0
    } else {
        i32::try_from(number.saturating_mul(sign)).unwrap_or(if sign < 0 {
            i32::MIN
        } else {
            i32::MAX
        })
    }
}

unsafe fn pad_digits_command(window: HWND, state: &mut AppState) {
    let Some(result) = (unsafe {
        prompt_input(
            window,
            prompt_spec(
                "숫자부분의 자리수를 맞춰 0을 붙입니다.",
                "자리수",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &["제일 뒷번호 맞춤", "제일 앞번호 맞춤"],
            ),
        )
    }) else {
        return;
    };
    let width = legacy_atoi(&result.value_one);
    if width <= 0 {
        unsafe { message(window, "자리수 입력이 잘못되었습니다.", "DarkNamer") };
        return;
    }
    let outcome = if result.choice == 0 {
        state.model.pad_last_digit_run(width as usize)
    } else {
        state.model.pad_first_digit_run(width as usize)
    };
    if outcome.is_err() {
        unsafe { message(window, "자리수 입력이 잘못되었습니다.", "DarkNamer") };
    }
}

unsafe fn sequence_command(window: HWND, state: &mut AppState) {
    let Some(result) = (unsafe {
        prompt_input(
            window,
            prompt_spec(
                "붙일 숫자의 자리수와 시작값을 지정합니다.",
                "자리수",
                "시작값",
                LegacyText::default(),
                LegacyText::default(),
                &[
                    "이름뒤에 번호붙임",
                    "이름앞에 번호붙임",
                    "폴더별로 뒤 번호붙임",
                    "폴더별로 앞 번호붙임",
                ],
            ),
        )
    }) else {
        return;
    };
    let width = legacy_atoi(&result.value_one);
    if width <= 0 {
        unsafe { message(window, "자리수 입력이 잘못되었습니다.", "DarkNamer") };
        return;
    }
    let mode = match result.choice {
        0 => LegacySequenceMode::Append,
        1 => LegacySequenceMode::Prepend,
        2 => LegacySequenceMode::AppendRestartPerFolder,
        _ => LegacySequenceMode::PrependRestartPerFolder,
    };
    let _ = state.model.add_sequence_by(
        width as usize,
        legacy_atoi(&result.value_two),
        mode,
        compare_windows,
    );
}

unsafe fn delete_position_command(window: HWND, state: &mut AppState) {
    let Some(result) = (unsafe {
        prompt_input(
            window,
            prompt_spec(
                "지정위치를 삭제합니다.(첫글자는 1번째)",
                "번째부터",
                "번째까지",
                LegacyText::default(),
                LegacyText::default(),
                &["앞에서부터 삭제", "제일 뒤부터 삭제"],
            ),
        )
    }) else {
        return;
    };
    let start = legacy_atoi(&result.value_one);
    let end = legacy_atoi(&result.value_two);
    if start < 0 || end < 0 {
        unsafe {
            message(
                window,
                "음수값이나 잘못된 값이 입력되었습니다.",
                "DarkNamer",
            )
        };
        return;
    }
    if result.choice == 0 && end > 0 && start > end {
        unsafe { message(window, "시작점이 끝점보다 뒤에 있습니다.", "DarkNamer") };
        return;
    }
    if result.choice == 1 && start != 0 {
        unsafe {
            message(
                window,
                "맨 뒤에서부터 삭제할때는 '~까지'만 필요합니다.",
                "DarkNamer",
            )
        };
        return;
    }
    if result.choice == 0 {
        let _ = state.model.delete_front_range(start as usize, end as usize);
    } else {
        state.model.delete_last(end as usize);
    }
}

unsafe fn delete_delimited_command(window: HWND, state: &mut AppState) {
    let Some(result) = (unsafe {
        prompt_input(
            window,
            prompt_spec(
                "지정된 문자로 묶인 부분을 삭제합니다.",
                ":시작문자",
                ":끝문자",
                LegacyText::default(),
                LegacyText::default(),
                &[],
            ),
        )
    }) else {
        return;
    };
    if state
        .model
        .delete_first_delimited(&result.value_one, &result.value_two)
        == Err(LegacyInputError::EmptyDelimiter)
    {
        unsafe {
            message(
                window,
                "시작/끝 문자가 정확하게 지정되지 않았습니다.",
                "DarkNamer",
            )
        };
    }
}

unsafe fn sort_command(window: HWND, state: &mut AppState) -> bool {
    let choices = [
        "파일 이름에 따라 오름차순",
        "파일 이름에 따라 내림차순",
        "전체경로에 따라 오름차순",
        "전체경로에 따라 내림차순",
        "파일 크기에 따라 오름차순",
        "파일 크기에 따라 내림차순",
        "수정한 시각에 따라 오름차순",
        "수정한 시각에 따라 내림차순",
        "만든 시각에 따라 오름차순",
        "만든 시각에 따라 내림차순",
    ];
    let Some(result) = (unsafe {
        prompt_input(
            window,
            prompt_spec(
                "정렬 기준 설정",
                "",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &choices,
            ),
        )
    }) else {
        return false;
    };
    let modes = [
        LegacySortMode::NameAscending,
        LegacySortMode::NameDescending,
        LegacySortMode::FullPathAscending,
        LegacySortMode::FullPathDescending,
        LegacySortMode::SizeAscending,
        LegacySortMode::SizeDescending,
        LegacySortMode::ModifiedAscending,
        LegacySortMode::ModifiedDescending,
        LegacySortMode::CreatedAscending,
        LegacySortMode::CreatedDescending,
    ];
    if let Some(mode) = modes.get(result.choice) {
        let selected = unsafe { selected_indices(state.list_window) };
        let tokens = selection_tokens(&state.model, &selected);
        let focused = unsafe { focused_index(state.list_window) }
            .and_then(|index| selection_token(&state.model, index));
        unsafe { clear_selection(state.list_window) };
        state.model.sort_by(*mode, compare_windows);
        unsafe { refresh(state) };
        let moved = rows_for_tokens(&state.model, &tokens);
        let focused = focused.as_ref().and_then(|token| {
            rows_for_tokens(&state.model, slice::from_ref(token))
                .first()
                .copied()
        });
        unsafe {
            select_rows_with_focus(state.list_window, &moved, focused);
            update_controls(state);
        }
        return true;
    }
    false
}

unsafe fn apply_changes(window: HWND, state: &mut AppState) {
    let prompt = wide("실제 파일 이름을 변경하시겠습니까?");
    let caption = wide("DarkNamer");
    if unsafe { MessageBoxW(window, prompt.as_ptr(), caption.as_ptr(), MB_OKCANCEL) } != IDOK {
        return;
    }
    unsafe { clear_selection(state.list_window) };
    if state
        .model
        .items()
        .iter()
        .any(|item| item.proposed_name().is_empty())
    {
        unsafe {
            message(window, "이름이 지정되지 않은 경우가 있습니다.", "DarkNamer")
        };
        if let Some(index) = state
            .model
            .items()
            .iter()
            .position(|item| item.proposed_name().is_empty())
        {
            unsafe { select_rows(state.list_window, &[index]) };
        }
        return;
    }
    for left in 0..state.model.len() {
        for right in left + 1..state.model.len() {
            if compare_windows(
                &state.model.items()[left].planned_path(),
                &state.model.items()[right].planned_path(),
            ) == std::cmp::Ordering::Equal
            {
                let duplicate = state.model.items()[right].planned_path();
                unsafe {
                    message(
                        window,
                        &format!("중복되는 이름이 있습니다.\n{duplicate}"),
                        "DarkNamer",
                    )
                };
                unsafe { select_rows(state.list_window, &[left, right]) };
                return;
            }
        }
    }
    let mut failed = Vec::new();
    for index in 0..state.model.len() {
        let source = state.model.items()[index].source_path().clone();
        let destination = state.model.items()[index].planned_path();
        if compare_windows(&source, &destination) == std::cmp::Ordering::Equal {
            continue;
        }
        let mut source_wide = source.units().to_vec();
        source_wide.push(0);
        let mut destination_wide = destination.units().to_vec();
        destination_wide.push(0);
        if unsafe { MoveFileW(source_wide.as_ptr(), destination_wide.as_ptr()) } != 0 {
            state.model.record_move_success(index);
        } else {
            failed.push(format!("{source} -> {destination} 변경 실패.\n"));
        }
    }
    if failed.is_empty() {
        unsafe { message(window, "파일 이름을 변경하였습니다.", "DarkNamer") };
    } else {
        unsafe { message(window, &failed.concat(), "DarkNamer") };
    }
}

unsafe fn clear_selection(list: HWND) {
    let mut item = LVITEMW {
        stateMask: LVIS_SELECTED | LVIS_FOCUSED,
        state: 0,
        ..unsafe { zeroed() }
    };
    unsafe {
        SendMessageW(
            list,
            LVM_SETITEMSTATE,
            usize::MAX,
            (&mut item as *mut LVITEMW) as isize,
        );
    }
}

unsafe fn admit_drop(owner: HWND, state: &mut AppState, drop: HDROP) {
    // SAFETY: drop is a valid HDROP for the duration of WM_DROPFILES handling.
    let count = unsafe { DragQueryFileW(drop, u32::MAX, null_mut(), 0) };
    let mut paths = Vec::new();
    for index in 0..count {
        let length = unsafe { DragQueryFileW(drop, index, null_mut(), 0) };
        let mut buffer = vec![0; length as usize + 1];
        unsafe { DragQueryFileW(drop, index, buffer.as_mut_ptr(), buffer.len() as u32) };
        buffer.truncate(length as usize);
        paths.push(PathBuf::from(std::ffi::OsString::from_wide(&buffer)));
    }
    unsafe { DragFinish(drop) };
    unsafe { set_status(state.status, "처리중...") };
    state.directory_mode = None;
    unsafe { admit_paths(owner, state, paths) };
    unsafe { refresh(state) };
}

unsafe fn add_files_dialog(owner: HWND, state: &mut AppState) {
    let Some(paths) = modal_native_dialog(owner, || {
        rfd::FileDialog::new()
            .set_title("이름 붙일 파일 불러오기")
            .add_filter("All Files", &["*"])
            .pick_files()
    }) else {
        return;
    };
    unsafe { set_status(state.status, "처리중...") };
    state.directory_mode = None;
    unsafe { admit_paths(owner, state, paths) };
}

unsafe fn admit_paths(owner: HWND, state: &mut AppState, paths: Vec<PathBuf>) {
    let mut items = Vec::new();
    for path in paths {
        unsafe { collect_path(owner, state, &path, &mut items) };
    }
    state.model.append_batch_by(items, compare_windows);
}

unsafe fn collect_path(
    owner: HWND,
    state: &mut AppState,
    path: &Path,
    items: &mut Vec<LegacyListItem>,
) {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return;
    };
    let attributes = metadata.file_attributes();
    let is_directory = attributes & FILE_ATTRIBUTE_DIRECTORY != 0;
    if is_directory {
        let mode = match state.directory_mode {
            Some(mode) => mode,
            None => {
                let text = wide("경로를 직접 추가려면 YES, 경로내 파일을 추가하려면 NO 선택.");
                let caption = path_wide(path);
                let answer =
                    unsafe { MessageBoxW(owner, text.as_ptr(), caption.as_ptr(), MB_YESNO) };
                let mode = if answer == windows_sys::Win32::UI::WindowsAndMessaging::IDYES {
                    DirectoryMode::Direct
                } else {
                    DirectoryMode::Recurse
                };
                state.directory_mode = Some(mode);
                mode
            }
        };
        if mode == DirectoryMode::Recurse {
            let Ok(read_dir) = fs::read_dir(path) else {
                return;
            };
            let mut children = read_dir
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .collect::<Vec<_>>();
            children
                .sort_by(|left, right| compare_windows(&legacy_path(left), &legacy_path(right)));
            for child in children {
                unsafe { collect_path(owner, state, &child, items) };
            }
            return;
        }
    }
    items.push(legacy_item(path, &metadata, is_directory));
}

fn legacy_item(path: &Path, metadata: &fs::Metadata, is_directory: bool) -> LegacyListItem {
    LegacyListItem::new(
        legacy_path(path),
        is_directory,
        metadata.file_size() as u32,
        metadata.creation_time(),
        metadata.last_write_time(),
    )
}

fn legacy_path(path: &Path) -> LegacyText {
    LegacyText::from_units(path.as_os_str().encode_wide().collect::<Vec<_>>())
}

fn compare_windows(left: &LegacyText, right: &LegacyText) -> std::cmp::Ordering {
    let left_len = i32::try_from(left.len()).unwrap_or(i32::MAX);
    let right_len = i32::try_from(right.len()).unwrap_or(i32::MAX);
    let result = unsafe {
        CompareStringW(
            LOCALE_USER_DEFAULT,
            NORM_IGNORECASE,
            left.units().as_ptr(),
            left_len,
            right.units().as_ptr(),
            right_len,
        )
    };
    if result == CSTR_LESS_THAN {
        std::cmp::Ordering::Less
    } else if result == CSTR_GREATER_THAN {
        std::cmp::Ordering::Greater
    } else {
        std::cmp::Ordering::Equal
    }
}

fn path_wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain([0]).collect()
}

unsafe fn copy_clipboard(owner: HWND, text: &LegacyText) {
    let mut units = text.units().to_vec();
    units.push(0);
    if unsafe { OpenClipboard(owner) } == 0 {
        return;
    }
    unsafe { EmptyClipboard() };
    let bytes = units.len().saturating_mul(size_of::<u16>());
    let allocation = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes) };
    if !allocation.is_null() {
        let locked = unsafe { GlobalLock(allocation) } as *mut u16;
        if !locked.is_null() {
            unsafe {
                std::ptr::copy_nonoverlapping(units.as_ptr(), locked, units.len());
                GlobalUnlock(allocation);
            }
            let transferred =
                unsafe { SetClipboardData(u32::from(CF_UNICODETEXT), allocation as HANDLE) };
            if transferred.is_null() {
                unsafe { GlobalFree(allocation) };
            }
        } else {
            unsafe { GlobalFree(allocation) };
        }
    }
    unsafe { CloseClipboard() };
}

unsafe fn save_text_dialog(owner: HWND, text: LegacyText, names: bool) {
    let title = if names {
        "파일명 저장"
    } else {
        "경로명 저장"
    };
    let Some(path) = modal_native_dialog(owner, || {
        rfd::FileDialog::new()
            .set_title(title)
            .add_filter("Text Files", &["txt"])
            .add_filter("All Files", &["*"])
            .set_file_name("*.txt")
            .save_file()
    }) else {
        return;
    };
    let _ = write_legacy_text(&path, &text);
}

unsafe fn import_names_dialog(owner: HWND, state: &mut AppState) {
    let Some(path) = modal_native_dialog(owner, || {
        rfd::FileDialog::new()
            .set_title("바꿀 파일 이름 불러오기")
            .add_filter("Text Files", &["txt"])
            .add_filter("All Files", &["*"])
            .pick_file()
    }) else {
        return;
    };
    if let Ok(text) = read_legacy_text(&path) {
        state.model.import_names(&text);
    }
}

unsafe fn import_paths_dialog(owner: HWND, state: &mut AppState) {
    let Some(path) = modal_native_dialog(owner, || {
        rfd::FileDialog::new()
            .set_title("파일에서 경로목록 읽어 추가하기")
            .add_filter("Text Files", &["txt"])
            .add_filter("All Files", &["*"])
            .pick_file()
    }) else {
        return;
    };
    let Ok(text) = read_legacy_text(&path) else {
        return;
    };
    unsafe { set_status(state.status, "처리중...") };
    let paths = darknamer_core::parse_import_lines(&text)
        .into_iter()
        .map(|line| PathBuf::from(std::ffi::OsString::from_wide(line.units())))
        .collect();
    unsafe { admit_paths(owner, state, paths) };
}

unsafe fn set_status(status: HWND, text: &str) {
    let text = wide(text);
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(status, text.as_ptr());
        UpdateWindow(status);
    }
}

fn modal_native_dialog<T>(owner: HWND, dialog: impl FnOnce() -> T) -> T {
    unsafe { EnableWindow(owner, 0) };
    let result = dialog();
    unsafe {
        EnableWindow(owner, 1);
        SetForegroundWindow(owner);
    }
    result
}

fn write_legacy_text(path: &Path, text: &LegacyText) -> io::Result<()> {
    let mut bytes = Vec::with_capacity(2 + text.len() * 2);
    bytes.extend_from_slice(&[0xFF, 0xFE]);
    for unit in text.units() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    fs::write(path, bytes)
}

fn read_legacy_text(path: &Path) -> io::Result<LegacyText> {
    let bytes = fs::read(path)?;
    if bytes.starts_with(&[0xFF, 0xFE]) {
        let units = bytes[2..]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect::<Vec<_>>();
        return Ok(LegacyText::from_units(units));
    }
    if bytes.is_empty() {
        return Ok(LegacyText::default());
    }
    let input_len =
        i32::try_from(bytes.len()).map_err(|_| io::Error::other("text file too large"))?;
    let needed =
        unsafe { MultiByteToWideChar(CP_ACP, 0, bytes.as_ptr(), input_len, null_mut(), 0) };
    if needed <= 0 {
        return Err(io::Error::last_os_error());
    }
    let mut units = vec![0_u16; needed as usize];
    let written = unsafe {
        MultiByteToWideChar(
            CP_ACP,
            0,
            bytes.as_ptr(),
            input_len,
            units.as_mut_ptr(),
            needed,
        )
    };
    if written <= 0 {
        return Err(io::Error::last_os_error());
    }
    units.truncate(written as usize);
    Ok(LegacyText::from_units(units))
}

unsafe fn update_column_visibility(state: &AppState, index: usize) {
    let column = index + 3;
    let width = if state.shown_columns[index] {
        if column == 4 { 80 } else { 120 }
    } else {
        0
    };
    unsafe {
        SendMessageW(state.list_window, LVM_SETCOLUMNWIDTH, column, width);
    }
}

unsafe fn refresh(state: &mut AppState) {
    let selected = unsafe { selected_indices(state.list_window) };
    unsafe { SendMessageW(state.list_window, LVM_DELETEALLITEMS, 0, 0) };
    for (row, item) in state.model.items().iter().enumerate() {
        let size = LegacyText::from(item.size().to_string());
        let modified = format_filetime(item.modified());
        let created = format_filetime(item.created());
        let values = [
            item.current_name().clone(),
            item.proposed_name().clone(),
            item.root_path().clone(),
            item.source_path().clone(),
            size,
            modified,
            created,
        ];
        for (column, value) in values.iter().enumerate() {
            let mut text = value.units().to_vec();
            text.push(0);
            if column == 0 {
                let mut native = LVITEMW {
                    mask: LVIF_TEXT | LVIF_IMAGE,
                    iItem: row as i32,
                    iSubItem: 0,
                    pszText: text.as_mut_ptr(),
                    iImage: unsafe { file_icon_index(item) },
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
    unsafe { select_rows(state.list_window, &selected) };
    unsafe { update_controls(state) };
    let status = if state.model.is_empty() {
        LegacyText::default()
    } else {
        LegacyText::from(format!("{} 개", state.model.len()))
    };
    let mut status = status.units().to_vec();
    status.push(0);
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(state.status, status.as_ptr());
    }
}

unsafe fn update_controls(state: &mut AppState) {
    let selected_count = unsafe { selected_indices(state.list_window) }.len();
    for id in APPLY..=VERSION {
        state.command_states[usize::from(id - APPLY)] =
            command_enabled(id, state.model.len(), selected_count);
    }
    unsafe { apply_command_states(state) };
}

unsafe fn apply_command_states(state: &AppState) {
    for tool in LEFT_TOOLS {
        unsafe {
            set_toolbar_button_enabled(
                state.left_toolbar,
                tool.id,
                state.command_states[usize::from(tool.id - APPLY)],
            )
        };
    }
    for tool in RIGHT_TOOLS {
        unsafe {
            set_toolbar_button_enabled(
                state.right_toolbar,
                tool.id,
                state.command_states[usize::from(tool.id - APPLY)],
            )
        };
    }
    for id in APPLY..=VERSION {
        let enabled = state.command_states[usize::from(id - APPLY)];
        unsafe {
            EnableMenuItem(
                state.menu,
                u32::from(id),
                MF_BYCOMMAND | if enabled { MF_ENABLED } else { MF_GRAYED },
            );
        }
    }
    for (index, id) in [SHOW_FULL_PATH, SHOW_SIZE, SHOW_MODIFIED, SHOW_CREATED]
        .into_iter()
        .enumerate()
    {
        unsafe {
            CheckMenuItem(
                state.menu,
                u32::from(id),
                MF_BYCOMMAND
                    | if state.shown_columns[index] {
                        MF_CHECKED
                    } else {
                        MF_UNCHECKED
                    },
            );
        }
    }
    if !state.menu.is_null() {
        unsafe { DrawMenuBar(GetParent(state.list_window)) };
    }
}

unsafe fn set_toolbar_button_enabled(toolbar: HWND, command: CommandId, enabled: bool) {
    if !toolbar.is_null() {
        unsafe {
            SendMessageW(
                toolbar,
                TB_ENABLEBUTTON,
                usize::from(command),
                enabled as isize,
            )
        };
    }
}

unsafe fn file_icon_index(item: &LegacyListItem) -> i32 {
    let mut info: SHFILEINFOW = unsafe { zeroed() };
    let path = if item.is_directory() {
        LegacyText::from("folder")
    } else {
        item.current_name().clone()
    };
    let mut path = path.units().to_vec();
    path.push(0);
    let attributes = if item.is_directory() {
        FILE_ATTRIBUTE_DIRECTORY
    } else {
        FILE_ATTRIBUTE_NORMAL
    };
    unsafe {
        SHGetFileInfoW(
            path.as_ptr(),
            attributes,
            &mut info,
            size_of::<SHFILEINFOW>() as u32,
            SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON,
        );
    }
    info.iIcon
}

fn format_filetime(value: u64) -> LegacyText {
    if value == 0 {
        return LegacyText::default();
    }
    let filetime = FILETIME {
        dwLowDateTime: value as u32,
        dwHighDateTime: (value >> 32) as u32,
    };
    let mut system: SYSTEMTIME = unsafe { zeroed() };
    if unsafe { FileTimeToSystemTime(&filetime, &mut system) } == 0 {
        return LegacyText::default();
    }
    LegacyText::from(format!(
        "{}-{:02}-{:02} {:02}:{:02}:{:02}",
        system.wYear, system.wMonth, system.wDay, system.wHour, system.wMinute, system.wSecond
    ))
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
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, COPY_PATHS, "클립보드로 경로목록 복사\tCtrl+Shift+C");
        menu_item(file, SAVE_PATHS, "문서파일로 경로목록 저장\tCtrl+Shift+X");
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, IMPORT_NAMES, "바꿀이름 불러오기\tCtrl+V");
        menu_item(file, IMPORT_PATHS, "경로목록 불러오기\tCtrl+Shift+V");
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, 2, "종료(&X)\tEsc");
        append_popup(menu, file, "파일(&F)");
        let edit = CreatePopupMenu();
        menu_item(edit, MOVE_UP, "위로 올림\t<");
        menu_item(edit, MOVE_DOWN, "아래로 내림\t>");
        AppendMenuW(edit, MF_SEPARATOR, 0, null());
        menu_item(edit, MANUAL_CHANGE, "직접 바꾸기");
        append_popup(menu, edit, "편집(&E)");
        let view = CreatePopupMenu();
        menu_item(view, SHOW_FULL_PATH, "전체 경로 표시");
        menu_item(view, SHOW_SIZE, "파일 크기 표시");
        menu_item(view, SHOW_MODIFIED, "변경 시각 표시");
        menu_item(view, SHOW_CREATED, "생성 시각 표시");
        append_popup(menu, view, "보기(&V)");
        let tools = CreatePopupMenu();
        menu_item(tools, REPLACE, "문자열 바꾸기");
        menu_item(tools, PREFIX, "앞이름 붙이기");
        menu_item(tools, SUFFIX, "뒷이름 붙이기");
        AppendMenuW(tools, MF_SEPARATOR, 0, null());
        menu_item(tools, CLEAR_NAME, "이름 지우기");
        menu_item(tools, DELETE_POSITION, "위치 지우기");
        menu_item(tools, DELETE_DELIMITED, "묶인곳 지우기");
        AppendMenuW(tools, MF_SEPARATOR, 0, null());
        menu_item(tools, KEEP_DIGITS, "숫자만 남기기");
        menu_item(tools, PAD_DIGITS, "자리수 맞추기");
        menu_item(tools, SEQUENCE, "번호 붙이기");
        AppendMenuW(tools, MF_SEPARATOR, 0, null());
        menu_item(tools, EXT_DELETE, "확장자 삭제");
        menu_item(tools, EXT_ADD, "확장자 추가");
        menu_item(tools, EXT_REPLACE, "확장자 변경");
        AppendMenuW(tools, MF_SEPARATOR, 0, null());
        menu_item(tools, PARENT_PREFIX, "경로명 앞에");
        menu_item(tools, PARENT_SUFFIX, "경로명 뒤에");
        menu_item(tools, UNIFY_PATH, "경로 통일하기");
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

#[allow(
    clippy::manual_dangling_ptr,
    reason = "Win32 MAKEINTRESOURCEW encodes a numeric resource ID in a pointer value"
)]
const fn int_resource(id: u16) -> *const u16 {
    id as usize as *const u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_text_files_round_trip_utf16le_bom() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("names.txt");
        let expected = LegacyText::from("첫째.txt\r\n둘째.txt\r\n");
        write_legacy_text(&path, &expected)?;
        let bytes = fs::read(&path)?;
        assert!(bytes.starts_with(&[0xFF, 0xFE]));
        assert_eq!(read_legacy_text(&path)?, expected);
        Ok(())
    }

    #[test]
    fn ttoi_compatibility_accepts_numeric_prefixes() {
        assert_eq!(legacy_atoi(&LegacyText::from("  -12suffix")), -12);
        assert_eq!(legacy_atoi(&LegacyText::from("3abc")), 3);
        assert_eq!(legacy_atoi(&LegacyText::from("abc3")), 0);
    }

    #[test]
    fn move_file_supports_cross_parent_file_and_directory_moves()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let source_root = directory.path().join("source");
        let target_root = directory.path().join("target");
        fs::create_dir_all(&source_root)?;
        fs::create_dir_all(&target_root)?;
        let source_file = source_root.join("old.txt");
        let target_file = target_root.join("new.txt");
        fs::write(&source_file, b"legacy")?;
        assert_ne!(
            unsafe {
                MoveFileW(
                    path_wide(&source_file).as_ptr(),
                    path_wide(&target_file).as_ptr(),
                )
            },
            0
        );
        assert_eq!(fs::read(&target_file)?, b"legacy");

        let source_directory = source_root.join("old-folder");
        let target_directory = target_root.join("new-folder");
        fs::create_dir(&source_directory)?;
        assert_ne!(
            unsafe {
                MoveFileW(
                    path_wide(&source_directory).as_ptr(),
                    path_wide(&target_directory).as_ptr(),
                )
            },
            0
        );
        assert!(target_directory.is_dir());
        Ok(())
    }
}
