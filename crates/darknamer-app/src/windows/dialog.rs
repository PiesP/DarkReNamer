use super::*;
use ::windows::Win32::Foundation::PROPERTYKEY;
use ::windows::Win32::System::Com::StructuredStorage::{PropVariantToGUID, PropVariantToUInt64};
use ::windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance, CoTaskMemFree};
use ::windows::Win32::System::Ole::IOleWindow;
use ::windows::Win32::System::Variant::{VARENUM, VT_CLSID, VT_UI8};
use ::windows::Win32::UI::Shell::PropertiesSystem::{GPS_DEFAULT, IPropertyStore};
use ::windows::Win32::UI::Shell::{
    Common::COMDLG_FILTERSPEC, FDEOR_DEFAULT, FDEOR_REFUSE, FDESVR_DEFAULT, FOS_ALLOWMULTISELECT,
    FOS_FILEMUSTEXIST, FOS_FORCEFILESYSTEM, FOS_NOCHANGEDIR, FOS_OVERWRITEPROMPT,
    FOS_PATHMUSTEXIST, FOS_PICKFOLDERS, FileOpenDialog, FileSaveDialog, IFileDialog,
    IFileDialogEvents, IFileDialogEvents_Impl, IFileOpenDialog, IFileSaveDialog, IShellItem,
    IShellItem2, IShellItemArray, SIGDN_FILESYSPATH,
};
use ::windows::core::{Error as WindowsError, GUID, Interface, PCWSTR, implement};
use std::cell::RefCell;
use std::rc::Rc;
use windows_sys::Win32::Foundation::{FreeLibrary, HMODULE};
use windows_sys::Win32::Globalization::lstrlenW;
use windows_sys::Win32::System::LibraryLoader::{
    GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW,
};
use windows_sys::Win32::UI::Controls::SetWindowTheme;

struct DynamicLibrary {
    handle: HMODULE,
}

impl DynamicLibrary {
    fn load_system(name: &str) -> io::Result<Self> {
        let wide_name = wide(name);
        // SAFETY: the fixed system-DLL leaf is NUL-terminated and the search
        // flag prevents current-directory or PATH preloading. LoadLibraryExW
        // also applies the process activation context, selecting the manifest's
        // Common Controls assembly when one is active, and acquires one owned
        // reference even if another same-basename module is already mapped.
        let loaded =
            unsafe { LoadLibraryExW(wide_name.as_ptr(), null_mut(), LOAD_LIBRARY_SEARCH_SYSTEM32) };
        if loaded.is_null() {
            Err(io::Error::other(format!(
                "Windows system library {name} could not be loaded: {}",
                io::Error::last_os_error()
            )))
        } else {
            Ok(Self { handle: loaded })
        }
    }

    fn resolve(&self, symbol: &[u8]) -> io::Result<NonNull<std::ffi::c_void>> {
        if symbol.last() != Some(&0) || symbol[..symbol.len().saturating_sub(1)].contains(&0) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Windows symbol name must contain one trailing NUL",
            ));
        }
        // SAFETY: self retains the loaded module and symbol is a validated
        // NUL-terminated byte string for this synchronous lookup.
        let address = unsafe { GetProcAddress(self.handle, symbol.as_ptr()) }
            .map(|function| function as *const () as *mut std::ffi::c_void)
            .and_then(NonNull::new);
        address.ok_or_else(|| {
            let name = String::from_utf8_lossy(&symbol[..symbol.len().saturating_sub(1)]);
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("Windows symbol {name} is unavailable"),
            )
        })
    }
}

impl Drop for DynamicLibrary {
    fn drop(&mut self) {
        // SAFETY: this handle came from one successful LoadLibraryExW call and
        // this owner releases that reference exactly once.
        unsafe { FreeLibrary(self.handle) };
    }
}

type TaskDialogIndirectFn = unsafe extern "system" fn(
    *const TASKDIALOGCONFIG,
    *mut i32,
    *mut i32,
    *mut windows_sys::core::BOOL,
) -> HRESULT;

union TaskDialogAddress {
    raw: *mut std::ffi::c_void,
    typed: TaskDialogIndirectFn,
}

struct TaskDialogApi {
    call: TaskDialogIndirectFn,
    _module: DynamicLibrary,
}

impl TaskDialogApi {
    fn load() -> io::Result<Self> {
        const {
            assert!(size_of::<*mut std::ffi::c_void>() == size_of::<TaskDialogIndirectFn>());
        }
        let module = DynamicLibrary::load_system("comctl32.dll")?;
        let address = module.resolve(b"TaskDialogIndirect\0").map_err(|error| {
            io::Error::new(
                error.kind(),
                format!(
                    "TaskDialogIndirect is unavailable; Common Controls v6 activation is required: {error}"
                ),
            )
        })?;
        // SAFETY: GetProcAddress returned a non-null address for the exact
        // TaskDialogIndirect export and TaskDialogIndirectFn matches the Win32
        // SDK ABI exactly. `_module` retains the code through every call.
        let call = unsafe {
            TaskDialogAddress {
                raw: address.as_ptr(),
            }
            .typed
        };
        Ok(Self {
            call,
            _module: module,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct TaskDialogButtonSpec<'a> {
    pub(super) id: i32,
    pub(super) text: &'a str,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct TaskDialogSpec<'a> {
    pub(super) title: &'a str,
    pub(super) main_instruction: &'a str,
    pub(super) content: &'a str,
    pub(super) expanded_information: Option<&'a str>,
    pub(super) buttons: &'a [TaskDialogButtonSpec<'a>],
    pub(super) warning: bool,
}

pub(super) struct PreparedTaskDialogButton {
    pub(super) id: i32,
    pub(super) text: String,
}

pub(super) const TEXT_DETAILS_BUTTON_ID: i32 = 1_102;

pub(super) struct PreparedTextDetails {
    pub(super) caption: String,
    pub(super) text: String,
    pub(super) appearance: PromptAppearance,
}

pub(super) struct PreparedTaskDialogSpec {
    pub(super) title: String,
    pub(super) main_instruction: String,
    pub(super) content: String,
    pub(super) expanded_information: Option<String>,
    pub(super) text_details: Option<PreparedTextDetails>,
    pub(super) buttons: Vec<PreparedTaskDialogButton>,
    pub(super) warning: bool,
}

pub(super) fn select_prepared_task_dialog(
    owner: HWND,
    prepared: &PreparedTaskDialogSpec,
) -> io::Result<i32> {
    let buttons = prepared
        .buttons
        .iter()
        .map(|button| TaskDialogButtonSpec {
            id: button.id,
            text: &button.text,
        })
        .collect::<Vec<_>>();
    loop {
        let selected = task_dialog(
            owner,
            TaskDialogSpec {
                title: &prepared.title,
                main_instruction: &prepared.main_instruction,
                content: &prepared.content,
                expanded_information: prepared.expanded_information.as_deref(),
                buttons: &buttons,
                warning: prepared.warning,
            },
        )?;
        if selected != TEXT_DETAILS_BUTTON_ID {
            return Ok(selected);
        }
        let Some(details) = prepared.text_details.as_ref() else {
            return Ok(IDCANCEL);
        };
        text_details(owner, details.appearance, &details.caption, &details.text)?;
        // SAFETY: this value query checks whether the exact owner HWND survived
        // the nested details modal before the confirmation is shown again.
        if unsafe { IsWindow(owner) } == 0 {
            return Ok(IDCANCEL);
        }
        let Some(state_lease) = try_app_state(owner) else {
            return Ok(IDCANCEL);
        };
        let closing = state_lease.state().close_pending;
        drop(state_lease);
        if closing {
            return Ok(IDCANCEL);
        }
    }
}

struct OwnedTaskDialog {
    _title: Vec<u16>,
    _main_instruction: Vec<u16>,
    _content: Vec<u16>,
    _expanded_information: Option<Vec<u16>>,
    _expanded_control_text: Option<Vec<u16>>,
    _collapsed_control_text: Option<Vec<u16>>,
    _button_texts: Vec<Vec<u16>>,
    _buttons: Vec<TASKDIALOG_BUTTON>,
    config: TASKDIALOGCONFIG,
}

impl OwnedTaskDialog {
    fn new(owner: HWND, spec: TaskDialogSpec<'_>) -> io::Result<Self> {
        if owner.is_null() {
            return Err(io::Error::other("task dialog requires a live owner window"));
        }
        if spec.buttons.is_empty() {
            return Err(io::Error::other(
                "task dialog requires at least one explicit action",
            ));
        }
        for (index, button) in spec.buttons.iter().enumerate() {
            if button.id <= 0 || button.id == IDCANCEL || button.text.is_empty() {
                return Err(io::Error::other(
                    "task dialog button specification is invalid",
                ));
            }
            if spec.buttons[..index]
                .iter()
                .any(|existing| existing.id == button.id)
            {
                return Err(io::Error::other(
                    "task dialog button identifiers must be unique",
                ));
            }
        }
        let button_count = u32::try_from(spec.buttons.len())
            .map_err(|_| io::Error::other("too many task dialog buttons"))?;
        let title = wide(spec.title);
        let main_instruction = wide(spec.main_instruction);
        let content = wide(spec.content);
        let expanded_information = spec.expanded_information.map(wide);
        let expanded_control_text = expanded_information
            .as_ref()
            .map(|_| wide("상세 정보 숨기기"));
        let collapsed_control_text = expanded_information
            .as_ref()
            .map(|_| wide("상세 정보 표시"));
        let button_texts = spec
            .buttons
            .iter()
            .map(|button| wide(button.text))
            .collect::<Vec<_>>();
        let buttons = spec
            .buttons
            .iter()
            .zip(&button_texts)
            .map(|(button, text)| TASKDIALOG_BUTTON {
                nButtonID: button.id,
                pszButtonText: text.as_ptr(),
            })
            .collect::<Vec<_>>();
        let config = TASKDIALOGCONFIG {
            cbSize: size_of::<TASKDIALOGCONFIG>() as u32,
            hwndParent: owner,
            hInstance: null_mut(),
            dwFlags: TDF_ALLOW_DIALOG_CANCELLATION
                | TDF_POSITION_RELATIVE_TO_WINDOW
                | TDF_SIZE_TO_CONTENT
                | TDF_USE_COMMAND_LINKS,
            dwCommonButtons: TDCBF_CANCEL_BUTTON,
            pszWindowTitle: title.as_ptr(),
            Anonymous1: TASKDIALOGCONFIG_0 {
                pszMainIcon: if spec.warning {
                    TD_WARNING_ICON
                } else {
                    null()
                },
            },
            pszMainInstruction: main_instruction.as_ptr(),
            pszContent: content.as_ptr(),
            cButtons: button_count,
            pButtons: buttons.as_ptr(),
            nDefaultButton: IDCANCEL,
            cRadioButtons: 0,
            pRadioButtons: null(),
            nDefaultRadioButton: 0,
            pszVerificationText: null(),
            pszExpandedInformation: expanded_information
                .as_ref()
                .map_or(null(), |text| text.as_ptr()),
            pszExpandedControlText: expanded_control_text
                .as_ref()
                .map_or(null(), |text| text.as_ptr()),
            pszCollapsedControlText: collapsed_control_text
                .as_ref()
                .map_or(null(), |text| text.as_ptr()),
            Anonymous2: TASKDIALOGCONFIG_1 {
                pszFooterIcon: null(),
            },
            pszFooter: null(),
            pfCallback: None,
            lpCallbackData: 0,
            cxWidth: 0,
        };
        Ok(Self {
            _title: title,
            _main_instruction: main_instruction,
            _content: content,
            _expanded_information: expanded_information,
            _expanded_control_text: expanded_control_text,
            _collapsed_control_text: collapsed_control_text,
            _button_texts: button_texts,
            _buttons: buttons,
            config,
        })
    }
}

pub(super) fn task_dialog(owner: HWND, spec: TaskDialogSpec<'_>) -> io::Result<i32> {
    let dialog = OwnedTaskDialog::new(owner, spec)?;
    let api = TaskDialogApi::load()?;
    let mut selected_button = 0_i32;
    // SAFETY: config owns pointers into heap allocations retained by `dialog`
    // for this entire synchronous call. The owner is non-null, the custom-button
    // array is immutable, and the selected-button output points to live storage.
    let hresult =
        unsafe { (api.call)(&dialog.config, &mut selected_button, null_mut(), null_mut()) };
    if hresult != 0 {
        return Err(io::Error::other(format!(
            "TaskDialogIndirect failed with HRESULT 0x{:08X}",
            hresult as u32
        )));
    }
    if selected_button == 0 {
        return Err(io::Error::other(
            "TaskDialogIndirect returned no selected button",
        ));
    }
    Ok(selected_button)
}

#[derive(Clone, Debug)]
pub(super) struct PromptSpec {
    pub(super) caption: String,
    pub(super) title: String,
    pub(super) label_one: String,
    pub(super) label_two: String,
    pub(super) value_one: LegacyText,
    pub(super) value_two: LegacyText,
    pub(super) choices: Vec<String>,
}

#[derive(Clone, Debug)]
pub(super) struct PromptResult {
    pub(super) value_one: LegacyText,
    pub(super) value_two: LegacyText,
    pub(super) choice: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct PromptAppearance {
    pub(super) preference: UiAppearance,
    pub(super) forced_colors: ForcedColorsState,
    pub(super) system_theme: Option<ResolvedTheme>,
}

pub(super) struct PromptState {
    pub(super) spec: PromptSpec,
    pub(super) read_only: bool,
    pub(super) result: Option<PromptResult>,
    pub(super) done: bool,
    pub(super) owner: HWND,
    pub(super) title: HWND,
    pub(super) label_one: HWND,
    pub(super) label_two: HWND,
    pub(super) edit_one: HWND,
    pub(super) edit_two: HWND,
    pub(super) combo: HWND,
    pub(super) separator: HWND,
    pub(super) ok: HWND,
    pub(super) cancel: HWND,
    pub(super) font: OwnedFont,
    pub(super) appearance: PromptAppearance,
    pub(super) appearance_resources: Option<AppearanceResources>,
    pub(super) creation_error: Option<io::Error>,
    pub(super) dpi: u32,
}

type PromptStateSlot = CallbackState<PromptState>;

/// The modal caller owns the slot; callbacks only borrow its published pointer.
/// Drop destroys the window before releasing its state and GDI resources.
struct PromptWindow {
    window: HWND,
    slot: *mut PromptStateSlot,
}

impl PromptWindow {
    fn lease(&self) -> io::Result<CallbackStateLease<PromptState>> {
        // SAFETY: this modal owner retains the UI-thread allocation until Drop;
        // every state reference is bounded by the exclusive returned lease.
        unsafe { CallbackState::try_lease(self.slot) }
            .ok_or_else(|| io::Error::other("prompt callback state is busy"))
    }

    fn close(&self) {
        close_prompt(self.window, self.slot);
    }

    fn finished(&self) -> io::Result<bool> {
        let done = self.lease()?.state().done;
        Ok(done || prompt_state_slot(self.window) != self.slot)
    }
}

impl Drop for PromptWindow {
    fn drop(&mut self) {
        self.close();
        // SAFETY: publication is cleared by window destruction. This is the
        // unique owner, and any remaining lease defers allocation reclamation.
        unsafe { CallbackState::request_reclaim(self.slot) };
    }
}

fn prompt_state_slot(window: HWND) -> *mut PromptStateSlot {
    // SAFETY: this value query reads the current publication without borrowing
    // the slot or its possibly leased PromptState.
    unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) as *mut PromptStateSlot }
}

fn close_prompt(window: HWND, slot: *mut PromptStateSlot) {
    if prompt_state_slot(window) == slot {
        // SAFETY: this exact publication identifies our live prompt. No state
        // reference is held, and the modal owner retains the slot until return.
        unsafe { DestroyWindow(window) };
    }
}

fn redraw_prompt(window: HWND, slot: *mut PromptStateSlot) {
    if prompt_state_slot(window) == slot {
        // SAFETY: the exact prompt is still published and its callback lease
        // has ended. Synchronous color/erase callbacks can use the new palette.
        unsafe {
            RedrawWindow(
                window,
                null(),
                null_mut(),
                RDW_INVALIDATE
                    | RDW_ERASE
                    | RDW_ALLCHILDREN
                    | windows_sys::Win32::Graphics::Gdi::RDW_ERASENOW
                    | windows_sys::Win32::Graphics::Gdi::RDW_UPDATENOW,
            )
        };
    }
}

const fn prompt_extended_style(read_only: bool) -> u32 {
    if read_only { 0 } else { WS_EX_TOOLWINDOW }
}

pub(super) struct OwnerEnableGuard {
    pub(super) owner: HWND,
    pub(super) was_enabled: bool,
}

impl OwnerEnableGuard {
    pub(super) fn new(owner: HWND) -> Self {
        // SAFETY: owner is the live top-level window supplied by the synchronous caller.
        let was_enabled = unsafe { IsWindowEnabled(owner) } != 0;
        if was_enabled {
            // SAFETY: owner is live and this guard restores its prior enabled state on every path.
            unsafe { EnableWindow(owner, 0) };
        }
        Self { owner, was_enabled }
    }

    pub(super) const fn disarm(&mut self) {
        self.was_enabled = false;
    }
}

impl Drop for OwnerEnableGuard {
    fn drop(&mut self) {
        if self.was_enabled {
            // SAFETY: owner is the live modal-owner HWND and was enabled before this guard disabled it.
            unsafe {
                EnableWindow(self.owner, 1);
                SetForegroundWindow(self.owner);
            }
        }
    }
}

struct NativeDialogParent {
    hwnd: HWND,
}

impl HasWindowHandle for NativeDialogParent {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        let hwnd = NonZeroIsize::new(self.hwnd as isize).ok_or(HandleError::Unavailable)?;
        let raw = RawWindowHandle::Win32(Win32WindowHandle::new(hwnd));
        // SAFETY: this wrapper is borrowed only while the live owner HWND is synchronously used.
        Ok(unsafe { WindowHandle::borrow_raw(raw) })
    }
}

impl HasDisplayHandle for NativeDialogParent {
    fn display_handle(&self) -> Result<DisplayHandle<'_>, HandleError> {
        Ok(DisplayHandle::windows())
    }
}

pub(super) fn native_file_dialog(owner: HWND) -> rfd::FileDialog {
    let parent = NativeDialogParent { hwnd: owner };
    rfd::FileDialog::new().set_parent(&parent)
}

pub(super) fn prompt_input(
    owner: HWND,
    appearance: PromptAppearance,
    spec: PromptSpec,
) -> io::Result<Option<PromptResult>> {
    prompt_input_variant(owner, appearance, spec, false)
}

fn prompt_input_variant(
    owner: HWND,
    appearance: PromptAppearance,
    spec: PromptSpec,
    read_only: bool,
) -> io::Result<Option<PromptResult>> {
    // Declare restoration first so prompt teardown precedes it on every path.
    let _owner_guard;
    let prompt = create_prompt_window(owner, appearance, spec, read_only)?;
    let dialog = prompt.window;
    _owner_guard = OwnerEnableGuard::new(owner);
    // SAFETY: dialog is our live prompt; no PromptState reference survives
    // showing, repainting, or any modal message dispatch below.
    unsafe {
        ShowWindow(dialog, SW_SHOW);
        UpdateWindow(dialog);
    }
    if !run_prompt_message_loop(&prompt)? {
        return Ok(None);
    }
    let mut lease = prompt.lease()?;
    let state = lease.state_mut();
    if let Some(error) = state.creation_error.take() {
        return Err(error);
    }
    Ok(state.result.take())
}

fn run_prompt_message_loop(prompt: &PromptWindow) -> io::Result<bool> {
    let dialog = prompt.window;
    let mut message = MSG::default();
    while !prompt.finished()? {
        #[cfg(test)]
        tests::inject_prompt_quit_for_test();
        // SAFETY: message is writable storage and no state lease is held.
        let status = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        #[cfg(test)]
        tests::record_prompt_quit_for_test(status, &message);
        if status == -1 {
            let error = io::Error::last_os_error();
            prompt.close();
            return Err(error);
        }
        if status == 0 {
            prompt.close();
            // SAFETY: repost the original quit code after the prompt is closed.
            unsafe { PostQuitMessage(message.wParam as i32) };
            return Ok(false);
        }
        // SAFETY: message is initialized and dialog is the modal target. No
        // state reference is retained across this synchronous dialog dispatch.
        if unsafe { IsDialogMessageW(dialog, &message) } == 0 {
            // SAFETY: message remains live through translation and dispatch.
            unsafe {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }
    Ok(true)
}

fn create_prompt_window(
    owner: HWND,
    appearance: PromptAppearance,
    spec: PromptSpec,
    read_only: bool,
) -> io::Result<PromptWindow> {
    // SAFETY: A null module name requests the current process module and dereferences no caller memory.
    let instance = unsafe { GetModuleHandleW(null()) };
    let class_name = wide("DarkReNamerInputWindow");
    let caption = wide(&spec.caption);
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(prompt_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        hIcon: null_mut(),
        // SAFETY: A null instance plus IDC_ARROW is the documented predefined-cursor request.
        hCursor: unsafe { LoadCursorW(null_mut(), IDC_ARROW) },
        hbrBackground: (COLOR_WINDOW + 1) as *mut c_void,
        lpszMenuName: null(),
        lpszClassName: class_name.as_ptr(),
        hIconSm: null_mut(),
    };
    // SAFETY: WNDCLASSEXW is initialized and its class name and callback remain valid during registration.
    unsafe { RegisterClassExW(&class) };
    // SAFETY: owner is the live top-level window for this modal prompt.
    let owner_dpi = unsafe { GetDpiForWindow(owner) };
    let dpi = if owner_dpi == 0 { BASE_DPI } else { owner_dpi };
    let slot = CallbackState::into_raw(PromptState {
        spec,
        read_only,
        result: None,
        done: false,
        owner,
        title: null_mut(),
        label_one: null_mut(),
        label_two: null_mut(),
        edit_one: null_mut(),
        edit_two: null_mut(),
        combo: null_mut(),
        separator: null_mut(),
        ok: null_mut(),
        cancel: null_mut(),
        font: OwnedFont::default(),
        appearance,
        appearance_resources: None,
        creation_error: None,
        dpi,
    });
    let mut prompt = PromptWindow {
        window: null_mut(),
        slot,
    };
    // SAFETY: owner/instance and strings are live. The owned callback slot stays
    // allocated through creation, the modal loop, and complete window teardown.
    let dialog = unsafe {
        CreateWindowExW(
            prompt_extended_style(read_only),
            class_name.as_ptr(),
            caption.as_ptr(),
            WS_POPUP | WS_CAPTION | WS_SYSMENU,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            scale_dip(380, dpi),
            scale_dip(210, dpi),
            owner,
            null_mut(),
            instance,
            slot.cast(),
        )
    };
    if dialog.is_null() {
        // Failed creation has completed its WM_NCDESTROY before returning;
        // no publication or callback lease remains when this owner is dropped.
        return Err(prompt
            .lease()?
            .state_mut()
            .creation_error
            .take()
            .unwrap_or_else(io::Error::last_os_error));
    }
    prompt.window = dialog;
    Ok(prompt)
}

const MAX_TEXT_DETAILS_UTF16_UNITS: usize = MAX_PATH_UNITS * 8;

fn text_details_value(text: &str) -> io::Result<LegacyText> {
    let mut source = text.encode_utf16().peekable();
    let mut normalized_len = 0_usize;
    while let Some(unit) = source.next() {
        let required = if unit == u16::from(b'\r') && source.peek() == Some(&u16::from(b'\n')) {
            source.next();
            2
        } else if unit == u16::from(b'\r') || unit == u16::from(b'\n') {
            2
        } else {
            if unit == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "전체 정보에 NUL 문자가 포함되어 있습니다.",
                ));
            }
            1
        };
        normalized_len = normalized_len.checked_add(required).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "전체 정보가 안전한 표시 길이를 초과했습니다.",
            )
        })?;
        if normalized_len > MAX_TEXT_DETAILS_UTF16_UNITS {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "전체 정보가 안전한 표시 길이를 초과했습니다.",
            ));
        }
    }
    let mut units = Vec::new();
    units
        .try_reserve_exact(normalized_len)
        .map_err(|_| io::Error::other("전체 정보를 표시할 메모리가 부족합니다."))?;
    let mut source = text.encode_utf16().peekable();
    while let Some(unit) = source.next() {
        let newline = unit == u16::from(b'\r') || unit == u16::from(b'\n');
        if unit == u16::from(b'\r') && source.peek() == Some(&u16::from(b'\n')) {
            source.next();
        }
        if newline {
            units.extend_from_slice(&[u16::from(b'\r'), u16::from(b'\n')]);
        } else {
            units.push(unit);
        }
    }
    debug_assert_eq!(units.len(), normalized_len);
    Ok(LegacyText::from_units(units))
}

pub(super) fn text_details(
    owner: HWND,
    appearance: PromptAppearance,
    caption: &str,
    text: &str,
) -> io::Result<()> {
    let value = text_details_value(text)?;
    prompt_input_variant(
        owner,
        appearance,
        PromptSpec {
            caption: caption.to_owned(),
            title: "전체 이름과 경로".to_owned(),
            label_one: String::new(),
            label_two: String::new(),
            value_one: value,
            value_two: LegacyText::default(),
            choices: Vec::new(),
        },
        true,
    )?;
    Ok(())
}

pub(super) fn prompt_input_or_report(
    owner: HWND,
    appearance: PromptAppearance,
    spec: PromptSpec,
) -> Option<PromptResult> {
    match prompt_input(owner, appearance, spec) {
        Ok(result) => result,
        Err(error) => {
            let detail = error
                .raw_os_error()
                .map_or_else(|| error.to_string(), |code| format!("OS {code}"));
            message(
                owner,
                &format!("입력창을 처리하지 못했습니다. {detail}"),
                "DarkReNamer",
            );
            None
        }
    }
}

fn prompt_controls(state: &PromptState) -> [HWND; 9] {
    [
        state.title,
        state.label_one,
        state.label_two,
        state.edit_one,
        state.edit_two,
        state.combo,
        state.separator,
        state.ok,
        state.cancel,
    ]
}

fn prompt_native_themed_controls(state: &PromptState) -> impl Iterator<Item = HWND> + '_ {
    [
        state.edit_one,
        state.edit_two,
        state.combo,
        state.ok,
        state.cancel,
    ]
    .into_iter()
    .filter(|control| !control.is_null())
}

fn set_prompt_control_theme_disabled(state: &PromptState, disabled: bool) -> bool {
    let empty = [0_u16];
    let theme = if disabled { empty.as_ptr() } else { null() };
    prompt_native_themed_controls(state).fold(true, |all_applied, control| {
        // SAFETY: every control is a live prompt child. Empty strings disable
        // visual styles for palette drawing; null restores native rendering.
        let applied = unsafe { SetWindowTheme(control, theme, theme) } >= 0;
        all_applied && applied
    })
}

fn apply_prompt_appearance(window: HWND, state: &mut PromptState) {
    let resolved = state.appearance.preference.resolve(
        state.appearance.forced_colors,
        state.appearance.system_theme,
    );
    let replacement = semantic_palette(resolved.theme)
        .and_then(|palette| AppearanceResources::create(palette).ok());
    let resources_complete = replacement.is_some();
    let controls_complete = resources_complete && set_prompt_control_theme_disabled(state, true);
    let custom = prompt_custom_theme_enabled(resolved, resources_complete, controls_complete);
    if custom {
        state.appearance_resources = replacement;
    } else {
        set_prompt_control_theme_disabled(state, false);
        state.appearance_resources = None;
    }
    apply_auxiliary_dwm_title_frame(
        window,
        if custom {
            resolved.theme
        } else {
            ResolvedTheme::NativeSystem
        },
    );
    // SAFETY: window is live and PromptState owns the installed resources before
    // every child is invalidated synchronously on this UI thread.
    unsafe {
        RedrawWindow(
            window,
            null(),
            null_mut(),
            RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
        )
    };
}

fn requery_prompt_appearance(window: HWND, state: &mut PromptState) {
    state.appearance.forced_colors =
        ForcedColorsState::from_high_contrast_query(query_high_contrast_active());
    state.appearance.system_theme = query_system_theme();
    apply_prompt_appearance(window, state);
}

fn prompt_static_color(resources: &AppearanceResources, dc: HDC) -> LRESULT {
    let palette = resources.palette();
    // SAFETY: dc is live for the synchronous WM_CTLCOLORSTATIC callback.
    unsafe {
        SetTextColor(dc, palette.text_primary);
        SetBkMode(dc, TRANSPARENT as i32);
    }
    resources.dialog_brush() as LRESULT
}

fn prompt_input_color(resources: &AppearanceResources, dc: HDC) -> LRESULT {
    let palette = resources.palette();
    // SAFETY: dc is live for the synchronous edit/list-box color callback.
    unsafe {
        SetTextColor(dc, palette.text_primary);
        SetBkColor(dc, palette.control_normal);
    }
    resources.control_normal_brush() as LRESULT
}

fn recreate_prompt_font(state: &mut PromptState) {
    let replacement = create_message_font(state.dpi);
    if replacement.is_null() {
        return;
    }
    for control in prompt_controls(state) {
        if !control.is_null() {
            // SAFETY: control is a live child HWND and replacement remains owned by PromptState.
            unsafe { SendMessageW(control, WM_SETFONT, replacement as usize, 1) };
        }
    }
    state.font.replace(replacement);
}

fn measured_prompt_text(window: HWND, font: HFONT, text: &str, max_width: i32) -> LayoutRect {
    // SAFETY: window is live and GetDC returns a display context valid until ReleaseDC below.
    let dc = unsafe { GetDC(window) };
    if dc.is_null() {
        return LayoutRect::default();
    }
    // SAFETY: dc is live and font is a PromptState-owned HFONT.
    let previous = unsafe { SelectObject(dc, font) };
    let mut value = wide(text);
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: max_width.max(1),
        bottom: 0,
    };
    // SAFETY: value is mutable terminated UTF-16 and rect is writable through synchronous measurement.
    unsafe {
        DrawTextW(
            dc,
            value.as_mut_ptr(),
            -1,
            &mut rect,
            DT_CALCRECT | DT_NOPREFIX | DT_WORDBREAK,
        );
        SelectObject(dc, previous);
        ReleaseDC(window, dc);
    }
    LayoutRect {
        x: 0,
        y: 0,
        width: rect.right.saturating_sub(rect.left).max(0),
        height: rect.bottom.saturating_sub(rect.top).max(0),
    }
}

fn measure_prompt_font(
    window: HWND,
    state: &PromptState,
    maximum_client: LayoutRect,
) -> PromptFontMetrics {
    if state.font.as_raw().is_null() {
        return PromptFontMetrics::default();
    }
    let horizontal_padding = scale_dip(24, state.dpi);
    let maximum_title_width = scale_dip(520, state.dpi)
        .min(maximum_client.width.saturating_sub(horizontal_padding))
        .max(1);
    let maximum_label_width = scale_dip(138, state.dpi)
        .min(maximum_title_width.saturating_sub(scale_dip(8, state.dpi)) / 3);
    let title = measured_prompt_text(
        window,
        state.font.as_raw(),
        &state.spec.title,
        maximum_title_width,
    );
    let line = measured_prompt_text(window, state.font.as_raw(), "Mg", maximum_title_width);
    let label_one = measured_prompt_text(
        window,
        state.font.as_raw(),
        &state.spec.label_one,
        maximum_label_width,
    );
    let label_two = measured_prompt_text(
        window,
        state.font.as_raw(),
        &state.spec.label_two,
        maximum_label_width,
    );
    let details = if state.read_only {
        measured_prompt_text(
            window,
            state.font.as_raw(),
            &state.spec.value_one.to_string_lossy(),
            maximum_title_width,
        )
    } else {
        LayoutRect::default()
    };
    PromptFontMetrics {
        title_width: title.width.max(details.width),
        title_height: title.height,
        label_width: label_one.width.max(label_two.width),
        label_height: label_one.height.max(label_two.height),
        line_height: line.height,
    }
}

fn calculate_read_only_prompt_layout(
    dpi: u32,
    measured: PromptFontMetrics,
    maximum_client: LayoutRect,
) -> PromptLayout {
    let mut layout = calculate_prompt_layout(
        dpi,
        measured,
        PromptFields {
            value_one: true,
            value_two: false,
            choice: false,
        },
        maximum_client,
    );
    let Some(mut edit) = layout.edit_one else {
        return layout;
    };
    edit.x = layout.title.x;
    edit.width = layout.title.width;
    let desired_edit_height = measured
        .line_height
        .max(scale_dip(16, dpi))
        .saturating_mul(12)
        .saturating_add(scale_dip(8, dpi));
    let available_growth = maximum_client
        .height
        .saturating_sub(layout.client.height)
        .max(0);
    let growth = desired_edit_height
        .saturating_sub(edit.height)
        .max(0)
        .min(available_growth);
    edit.height = edit.height.saturating_add(growth);
    layout.edit_one = Some(edit);
    layout.label_one = None;
    layout.separator.y = layout.separator.y.saturating_add(growth);
    layout.ok.y = layout.ok.y.saturating_add(growth);
    layout.cancel.y = layout.cancel.y.saturating_add(growth);
    layout.client.height = layout.client.height.saturating_add(growth);
    let line_height = measured.line_height.max(scale_dip(16, dpi));
    let button_gap = scale_dip(8, dpi).min(layout.title.width.saturating_sub(2) / 3);
    let button_width = line_height
        .saturating_mul(7)
        .saturating_add(scale_dip(8, dpi))
        .min(layout.title.width.saturating_sub(button_gap) / 2)
        .max(1);
    layout.cancel.width = button_width;
    layout.cancel.x = layout.title.right().saturating_sub(layout.cancel.width);
    layout.ok.width = button_width;
    layout.ok.x = layout
        .cancel
        .x
        .saturating_sub(button_gap)
        .saturating_sub(layout.ok.width);
    layout
}

fn move_prompt_control(window: HWND, rect: LayoutRect) {
    if window.is_null() {
        return;
    }
    // The pure layout already returns pixels, so BASE_DPI keeps this shared helper at identity scale.
    move_window_dip(window, rect.x, rect.y, rect.width, rect.height, BASE_DPI);
}

fn prompt_work_area(anchor: HWND) -> Option<RECT> {
    // SAFETY: anchor is live and the nearest-monitor fallback returns its nearest monitor.
    let monitor = unsafe { MonitorFromWindow(anchor, MONITOR_DEFAULTTONEAREST) };
    if monitor.is_null() {
        return None;
    }
    let mut monitor_info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        rcMonitor: RECT::default(),
        rcWork: RECT::default(),
        dwFlags: 0,
    };
    // SAFETY: monitor is resolved from the live anchor and monitor_info is writable storage.
    (unsafe { GetMonitorInfoW(monitor, &mut monitor_info) } != 0).then_some(monitor_info.rcWork)
}

fn maximum_prompt_client(state: &PromptState, anchor: HWND) -> LayoutRect {
    let Some(work) = prompt_work_area(anchor) else {
        return LayoutRect {
            x: 0,
            y: 0,
            width: scale_dip(380, state.dpi),
            height: scale_dip(210, state.dpi),
        };
    };
    let mut nonclient = RECT::default();
    // SAFETY: nonclient is writable and the style/ex-style match this prompt window.
    let adjusted = unsafe {
        AdjustWindowRectExForDpi(
            &mut nonclient,
            WS_POPUP | WS_CAPTION | WS_SYSMENU,
            0,
            prompt_extended_style(state.read_only),
            state.dpi,
        )
    } != 0;
    let (nonclient_width, nonclient_height) = if adjusted {
        (
            nonclient.right.saturating_sub(nonclient.left),
            nonclient.bottom.saturating_sub(nonclient.top),
        )
    } else {
        (0, 0)
    };
    LayoutRect {
        x: 0,
        y: 0,
        width: work
            .right
            .saturating_sub(work.left)
            .saturating_sub(nonclient_width)
            .max(1),
        height: work
            .bottom
            .saturating_sub(work.top)
            .saturating_sub(nonclient_height)
            .max(1),
    }
}

fn position_prompt(window: HWND, state: &PromptState, client: LayoutRect, center_on_owner: bool) {
    let mut outer = RECT {
        left: 0,
        top: 0,
        right: client.width,
        bottom: client.height,
    };
    // SAFETY: outer is writable and the style/ex-style match this prompt window.
    if unsafe {
        AdjustWindowRectExForDpi(
            &mut outer,
            WS_POPUP | WS_CAPTION | WS_SYSMENU,
            0,
            prompt_extended_style(state.read_only),
            state.dpi,
        )
    } == 0
    {
        return;
    }
    let width = outer.right.saturating_sub(outer.left).max(1);
    let height = outer.bottom.saturating_sub(outer.top).max(1);
    let anchor = if center_on_owner { state.owner } else { window };
    let mut anchor_rect = RECT::default();
    // SAFETY: anchor is the live modal owner or prompt and anchor_rect is writable.
    if unsafe { GetWindowRect(anchor, &mut anchor_rect) } == 0 {
        return;
    }
    let Some(work) = prompt_work_area(anchor) else {
        return;
    };
    let work_width = work.right.saturating_sub(work.left).max(1);
    let work_height = work.bottom.saturating_sub(work.top).max(1);
    if width > work_width || height > work_height {
        return;
    }
    let centered_x = anchor_rect
        .left
        .saturating_add(anchor_rect.right.saturating_sub(anchor_rect.left) / 2)
        .saturating_sub(width / 2);
    let centered_y = anchor_rect
        .top
        .saturating_add(anchor_rect.bottom.saturating_sub(anchor_rect.top) / 2)
        .saturating_sub(height / 2);
    let x = centered_x.clamp(work.left, work.right.saturating_sub(width));
    let y = centered_y.clamp(work.top, work.bottom.saturating_sub(height));
    // SAFETY: window is live and the bounded geometry lies within the monitor work area.
    unsafe {
        SetWindowPos(
            window,
            null_mut(),
            x,
            y,
            width,
            height,
            SWP_NOACTIVATE | SWP_NOZORDER,
        )
    };
}

fn arrange_prompt(window: HWND, state: &PromptState, center_on_owner: bool) {
    let fields = PromptFields {
        value_one: !state.spec.label_one.is_empty(),
        value_two: !state.spec.label_two.is_empty(),
        choice: !state.spec.choices.is_empty(),
    };
    let anchor = if center_on_owner { state.owner } else { window };
    let maximum_client = maximum_prompt_client(state, anchor);
    let measured = measure_prompt_font(window, state, maximum_client);
    let layout = if state.read_only {
        calculate_read_only_prompt_layout(state.dpi, measured, maximum_client)
    } else {
        calculate_prompt_layout(state.dpi, measured, fields, maximum_client)
    };
    move_prompt_control(state.title, layout.title);
    if let Some(rect) = layout.edit_one {
        move_prompt_control(state.edit_one, rect);
    }
    if let Some(rect) = layout.label_one {
        move_prompt_control(state.label_one, rect);
    }
    if let Some(rect) = layout.edit_two {
        move_prompt_control(state.edit_two, rect);
    }
    if let Some(rect) = layout.label_two {
        move_prompt_control(state.label_two, rect);
    }
    if let Some(rect) = layout.choice {
        move_prompt_control(state.combo, rect);
    }
    move_prompt_control(state.separator, layout.separator);
    move_prompt_control(state.ok, layout.ok);
    move_prompt_control(state.cancel, layout.cancel);
    position_prompt(window, state, layout.client, center_on_owner);
}

pub(super) fn create_prompt_children(window: HWND, state: &mut PromptState) -> io::Result<()> {
    state.title = child(window, "STATIC", &state.spec.title, 1001, SS_NOPREFIX)?;
    if state.read_only {
        state.edit_one = create_prompt_details_edit(window, &state.spec.value_one, 1004)?;
        state.ok = child(window, "BUTTON", "전체 복사(&C)", IDOK as u16, WS_TABSTOP)?;
        state.cancel = child(
            window,
            "BUTTON",
            "닫기",
            IDCANCEL as u16,
            WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
        )?;
        state.separator = child(window, "STATIC", "", 1010, SS_OWNERDRAW)?;
        return Ok(());
    }
    if !state.spec.label_one.is_empty() {
        state.label_one = child(window, "STATIC", &state.spec.label_one, 1002, SS_NOPREFIX)?;
        state.edit_one = create_prompt_edit(window, &state.spec.value_one, 1004)?;
    }
    if !state.spec.label_two.is_empty() {
        state.label_two = child(window, "STATIC", &state.spec.label_two, 1003, SS_NOPREFIX)?;
        state.edit_two = create_prompt_edit(window, &state.spec.value_two, 1005)?;
    }
    if !state.spec.choices.is_empty() {
        let combo = child(
            window,
            "COMBOBOX",
            "",
            1006,
            WS_TABSTOP | CBS_DROPDOWNLIST as u32,
        )?;
        for choice in &state.spec.choices {
            let choice = wide(choice);
            // SAFETY: combo is live and each terminated choice is retained through
            // this synchronous message.
            let added = unsafe { SendMessageW(combo, CB_ADDSTRING, 0, choice.as_ptr() as isize) };
            validate_combo_result(ComboOperation::AddString, added).map_err(|error| {
                io::Error::other(match error {
                    ComboControlError::Rejected => "combo box rejected a prompt choice",
                    ComboControlError::OutOfSpace => {
                        "combo box ran out of space for prompt choices"
                    }
                })
            })?;
        }
        // SAFETY: combo is live and choice zero exists because choices is non-empty.
        let selected = unsafe { SendMessageW(combo, CB_SETCURSEL, 0, 0) };
        validate_combo_result(ComboOperation::Select, selected).map_err(|error| {
            debug_assert_eq!(error, ComboControlError::Rejected);
            io::Error::other("combo box could not select the first prompt choice")
        })?;
        state.combo = combo;
    }
    state.ok = child(
        window,
        "BUTTON",
        "확인",
        IDOK as u16,
        WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
    )?;
    state.cancel = child(window, "BUTTON", "취소", IDCANCEL as u16, WS_TABSTOP)?;
    state.separator = child(window, "STATIC", "", 1010, SS_OWNERDRAW)?;
    Ok(())
}

pub(super) unsafe extern "system" fn prompt_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        let create = lparam as *const CREATESTRUCTW;
        if !create.is_null() {
            // SAFETY: creation supplies the pointer to the modal caller's live
            // CallbackState slot. Publication does not borrow its value.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, (*create).lpCreateParams as isize) };
        }
    }
    let slot = prompt_state_slot(window);
    if message == WM_NCDESTROY {
        // SAFETY: clear publication even during a nested destruction. The
        // modal owner retains the slot until every synchronous callback ends.
        unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
        // SAFETY: final default processing needs no PromptState reference.
        return unsafe { DefWindowProcW(window, message, wparam, lparam) };
    }
    if slot.is_null()
        || !matches!(
            message,
            WM_CREATE
                | WM_ERASEBKGND
                | WM_DRAWITEM
                | WM_NOTIFY
                | WM_CTLCOLORSTATIC
                | WM_CTLCOLOREDIT
                | WM_CTLCOLORLISTBOX
                | WM_DPICHANGED
                | WM_THEMECHANGED
                | WM_SYSCOLORCHANGE
                | WM_SETTINGCHANGE
                | WM_FONTCHANGE
                | WM_COMMAND
                | WM_CLOSE
        )
    {
        // In particular, default WM_PAINT may synchronously request erase and
        // child colors; those callbacks must be able to acquire their own lease.
        // SAFETY: default dispatch receives only copied callback arguments.
        return unsafe { DefWindowProcW(window, message, wparam, lparam) };
    }
    // SAFETY: the modal owner retains this published UI-thread slot. A nested
    // callback tests only its disjoint scalar status before forming a reference.
    let Some(mut lease) = (unsafe { CallbackState::try_lease(slot) }) else {
        if message == WM_CLOSE || message == WM_COMMAND {
            if message == WM_CLOSE
                || (((wparam >> 16) & 0xFFFF) as u32 == BN_CLICKED
                    && matches!((wparam & 0xFFFF) as i32, IDOK | IDCANCEL))
            {
                // SAFETY: defer an actionable close/button message using only
                // scalar arguments; no borrowed state survives this dispatch.
                unsafe { PostMessageW(window, message, wparam, lparam) };
            }
            return 0;
        }
        // SAFETY: native paint/notification fallback never accesses the busy
        // PromptState. Refresh completion repaints again after its lease ends.
        return unsafe { DefWindowProcW(window, message, wparam, lparam) };
    };
    let result = match message {
        WM_CREATE => {
            let state = lease.state_mut();
            if let Err(error) = create_prompt_children(window, state) {
                state.creation_error = Some(error);
                return -1;
            }
            recreate_prompt_font(state);
            apply_prompt_appearance(window, state);
            arrange_prompt(window, state, true);
            let first = if !state.edit_one.is_null() {
                state.edit_one
            } else {
                state.combo
            };
            drop(lease);
            if prompt_state_slot(window) == slot && !first.is_null() {
                // SAFETY: first is our live prompt's child and no state lease
                // remains while synchronous focus notifications are delivered.
                unsafe { SetFocus(first) };
            }
            redraw_prompt(window, slot);
            return 0;
        }
        WM_ERASEBKGND => {
            if let Some(resources) = lease.state().appearance_resources.as_ref() {
                let mut rect = RECT::default();
                // SAFETY: window/DC are live and rect is writable.
                unsafe {
                    GetClientRect(window, &mut rect);
                    FillRect(wparam as HDC, &rect, resources.dialog_brush());
                }
                1
            } else {
                // SAFETY: system class background remains the native fallback.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_DRAWITEM => {
            let state = lease.state();
            if draw_owner_separator(
                state.appearance_resources.as_ref(),
                state.separator,
                SeparatorSurface::Dialog,
                lparam,
            ) {
                1
            } else {
                // SAFETY: unrecognized drawing retains default processing.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_NOTIFY => {
            let state = lease.state();
            let resources = state.appearance_resources.as_ref();
            if resources.is_some()
                && let Some(result) = draw_custom_button(resources, state.ok, state.dpi, lparam)
                    .or_else(|| draw_custom_button(resources, state.cancel, state.dpi, lparam))
            {
                result
            } else {
                // SAFETY: unrelated notifications retain native processing.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_CTLCOLORSTATIC => {
            let state = lease.state();
            state.appearance_resources.as_ref().map_or_else(
                // SAFETY: native fallback retains system control coloring.
                || unsafe { DefWindowProcW(window, message, wparam, lparam) },
                |resources| {
                    if lparam as HWND == state.combo
                        || (state.read_only && lparam as HWND == state.edit_one)
                    {
                        prompt_input_color(resources, wparam as HDC)
                    } else {
                        prompt_static_color(resources, wparam as HDC)
                    }
                },
            )
        }
        WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX => {
            lease.state().appearance_resources.as_ref().map_or_else(
                // SAFETY: native fallback retains system edit/list-box coloring.
                || unsafe { DefWindowProcW(window, message, wparam, lparam) },
                |resources| prompt_input_color(resources, wparam as HDC),
            )
        }
        WM_DPICHANGED => {
            let state = lease.state_mut();
            let next_dpi = (wparam & 0xFFFF) as u32;
            state.dpi = if next_dpi == 0 { BASE_DPI } else { next_dpi };
            let suggested = lparam as *const RECT;
            if !suggested.is_null() {
                // SAFETY: the DPI message supplies readable suggested geometry.
                let suggested = unsafe { *suggested };
                // SAFETY: window is live and this is the OS-suggested geometry.
                unsafe {
                    SetWindowPos(
                        window,
                        null_mut(),
                        suggested.left,
                        suggested.top,
                        suggested.right.saturating_sub(suggested.left),
                        suggested.bottom.saturating_sub(suggested.top),
                        SWP_NOACTIVATE | SWP_NOZORDER,
                    )
                };
            }
            recreate_prompt_font(state);
            arrange_prompt(window, state, false);
            0
        }
        WM_THEMECHANGED | WM_SYSCOLORCHANGE => {
            requery_prompt_appearance(window, lease.state_mut());
            0
        }
        WM_SETTINGCHANGE | WM_FONTCHANGE => {
            let state = lease.state_mut();
            // SAFETY: window is the live prompt HWND.
            let dpi = unsafe { GetDpiForWindow(window) };
            state.dpi = if dpi == 0 { BASE_DPI } else { dpi };
            recreate_prompt_font(state);
            if message == WM_SETTINGCHANGE {
                requery_prompt_appearance(window, state);
            }
            arrange_prompt(window, state, false);
            0
        }
        WM_COMMAND => {
            let id = (wparam & 0xFFFF) as i32;
            let notification = ((wparam >> 16) & 0xFFFF) as u32;
            match prompt_button_action(lease.state().read_only, id, notification) {
                PromptButtonAction::CopyAll => {
                    let text = lease.state().spec.value_one.clone();
                    drop(lease);
                    if let Err(error) = copy_clipboard(window, &text) {
                        show_message_now(
                            window,
                            &format!(
                                "클립보드에 복사하지 못했습니다: {error}\n다시 시도할 수 있습니다."
                            ),
                            "DarkReNamer - 복사 실패",
                        );
                    }
                    return 0;
                }
                PromptButtonAction::Accept => {
                    let state = lease.state_mut();
                    match prompt_result(state) {
                        Ok(result) => state.result = Some(result),
                        Err(error) => state.creation_error = Some(error),
                    }
                    state.done = true;
                    drop(lease);
                    close_prompt(window, slot);
                    return 0;
                }
                PromptButtonAction::Close => {
                    lease.state_mut().done = true;
                    drop(lease);
                    close_prompt(window, slot);
                    return 0;
                }
                PromptButtonAction::None => {}
            }
            0
        }
        WM_CLOSE => {
            lease.state_mut().done = true;
            drop(lease);
            close_prompt(window, slot);
            return 0;
        }
        // SAFETY: arguments are unchanged values from the active callback.
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    };
    drop(lease);
    if matches!(
        message,
        WM_DPICHANGED | WM_THEMECHANGED | WM_SYSCOLORCHANGE | WM_SETTINGCHANGE | WM_FONTCHANGE
    ) {
        redraw_prompt(window, slot);
    }
    result
}

const MAX_PROMPT_TEXT_UTF16_UNITS: usize = darknamer_core::MAX_PROPOSED_NAME_UTF16_UNITS;
// Retain one sentinel unit above the valid command boundary. An oversized
// paste is therefore preserved as invalid input instead of being silently
// truncated into a valid 255-unit command, while allocation stays bounded.
const MAX_PROMPT_CONTROL_UTF16_UNITS: usize = MAX_PROMPT_TEXT_UTF16_UNITS + 1;

fn prompt_text_too_long(length: usize) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("입력값이 너무 깁니다(UTF-16 {length}/{MAX_PROMPT_TEXT_UTF16_UNITS}자)."),
    )
}

fn create_prompt_edit(parent: HWND, value: &LegacyText, id: u16) -> io::Result<HWND> {
    if value.len() > MAX_PROMPT_TEXT_UTF16_UNITS {
        return Err(prompt_text_too_long(value.len()));
    }
    let edit = child(
        parent,
        "EDIT",
        "",
        id,
        WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
    )?;
    let mut terminated = value.units().to_vec();
    terminated.push(0);
    // SAFETY: edit is the live standard EDIT just created. The first message
    // carries no pointer, and the second copies the retained terminated UTF-16
    // synchronously. The validated unit bound excludes the terminator.
    let displayed = unsafe {
        SendMessageW(
            edit,
            windows_sys::Win32::UI::Controls::EM_SETLIMITTEXT,
            MAX_PROMPT_CONTROL_UTF16_UNITS,
            0,
        );
        SendMessageW(
            edit,
            windows_sys::Win32::UI::WindowsAndMessaging::WM_SETTEXT,
            0,
            terminated.as_ptr() as isize,
        )
    };
    if displayed == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(edit)
}

fn create_prompt_details_edit(parent: HWND, value: &LegacyText, id: u16) -> io::Result<HWND> {
    if value.len() > MAX_TEXT_DETAILS_UTF16_UNITS {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "전체 정보가 안전한 표시 길이를 초과했습니다.",
        ));
    }
    let edit = child(
        parent,
        "EDIT",
        "",
        id,
        WS_BORDER
            | WS_TABSTOP
            | windows_sys::Win32::UI::WindowsAndMessaging::WS_VSCROLL
            | windows_sys::Win32::UI::WindowsAndMessaging::ES_MULTILINE as u32
            | windows_sys::Win32::UI::WindowsAndMessaging::ES_AUTOVSCROLL as u32
            | windows_sys::Win32::UI::WindowsAndMessaging::ES_READONLY as u32,
    )?;
    let terminated = wide(&value.to_string_lossy());
    // SAFETY: edit is the live standard EDIT just created. The first message
    // carries no pointer, and the second copies the retained terminated text
    // synchronously after the control limit is raised to the validated bound.
    let displayed = unsafe {
        SendMessageW(
            edit,
            windows_sys::Win32::UI::Controls::EM_SETLIMITTEXT,
            MAX_TEXT_DETAILS_UTF16_UNITS,
            0,
        );
        SendMessageW(
            edit,
            windows_sys::Win32::UI::WindowsAndMessaging::WM_SETTEXT,
            0,
            terminated.as_ptr() as isize,
        )
    };
    if displayed == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(edit)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PromptButtonAction {
    None,
    Accept,
    CopyAll,
    Close,
}

fn prompt_button_action(read_only: bool, id: i32, notification: u32) -> PromptButtonAction {
    if notification != BN_CLICKED {
        return PromptButtonAction::None;
    }
    match id {
        IDOK if read_only => PromptButtonAction::CopyAll,
        IDOK => PromptButtonAction::Accept,
        IDCANCEL => PromptButtonAction::Close,
        _ => PromptButtonAction::None,
    }
}

fn prompt_result(state: &PromptState) -> io::Result<PromptResult> {
    let value_one = prompt_window_text(state.edit_one)?;
    let value_two = prompt_window_text(state.edit_two)?;
    Ok(PromptResult {
        value_one,
        value_two,
        choice: if state.combo.is_null() {
            0
        } else {
            // SAFETY: combo is live and each choice pointer is owned terminated
            // UTF-16 retained through synchronous SendMessageW.
            usize::try_from(unsafe { SendMessageW(state.combo, CB_GETCURSEL, 0, 0) }).unwrap_or(0)
        },
    })
}

fn prompt_window_text(window: HWND) -> io::Result<LegacyText> {
    prompt_window_text_with_limit(window, MAX_PROMPT_TEXT_UTF16_UNITS)
}

fn prompt_window_text_with_limit(window: HWND, maximum: usize) -> io::Result<LegacyText> {
    if window.is_null() {
        return Ok(LegacyText::default());
    }
    // SAFETY: window is a live edit HWND and this call uses no caller output pointer.
    let length = unsafe { GetWindowTextLengthW(window) };
    if length <= 0 {
        return Ok(LegacyText::default());
    }
    let length = usize::try_from(length)
        .map_err(|_| io::Error::other("invalid native prompt text length"))?;
    if length > maximum {
        return Err(if maximum == MAX_PROMPT_TEXT_UTF16_UNITS {
            prompt_text_too_long(length)
        } else {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "전체 정보가 안전한 표시 길이를 초과했습니다.",
            )
        });
    }
    let mut value = vec![0_u16; maximum.saturating_add(1)];
    // SAFETY: value is writable for the fixed maximum plus terminator and
    // remains allocated through the synchronous copy from this live control.
    let copied = unsafe {
        GetWindowTextW(
            window,
            value.as_mut_ptr(),
            i32::try_from(value.len())
                .map_err(|_| io::Error::other("native prompt text limit is invalid"))?,
        )
    };
    let copied = usize::try_from(copied)
        .map_err(|_| io::Error::other("invalid native prompt text copy length"))?;
    // A programmatic WM_SETTEXT can bypass EM_SETLIMITTEXT. Re-query after the
    // bounded copy so a changed or misbehaving control cannot turn truncation
    // into an accepted command.
    // SAFETY: window remains the same live edit HWND and this call has no
    // caller output pointer.
    let final_length = unsafe { GetWindowTextLengthW(window) };
    let final_length = usize::try_from(final_length)
        .map_err(|_| io::Error::other("invalid native prompt text length"))?;
    if final_length > maximum {
        return Err(if maximum == MAX_PROMPT_TEXT_UTF16_UNITS {
            prompt_text_too_long(final_length)
        } else {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "전체 정보가 안전한 표시 길이를 초과했습니다.",
            )
        });
    }
    if copied != final_length || final_length > length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "입력값이 읽는 동안 변경되어 적용하지 않았습니다.",
        ));
    }
    value.truncate(copied);
    Ok(LegacyText::from_units(value))
}

#[cfg(test)]
pub(super) fn window_text(window: HWND) -> LegacyText {
    prompt_window_text(window).unwrap_or_default()
}

pub(super) fn copy_clipboard_or_report(owner: HWND, text: &LegacyText) {
    if let Err(error) = copy_clipboard(owner, text) {
        message(
            owner,
            &format!("클립보드에 복사하지 못했습니다: {error}"),
            "DarkReNamer - 복사 실패",
        );
    }
}

pub(super) enum PreparedFileDialogKind {
    AddFiles {
        remaining_count: usize,
        remaining_path_bytes: usize,
    },
    UnifyDestinationParent,
    SaveText {
        text: LegacyText,
        names: bool,
    },
    ImportNames,
    ImportPaths,
    ExportRecoveryJournal,
}

pub(super) enum PreparedFileDialogSelection {
    Cancelled,
    AddFiles(Vec<PathBuf>),
    UnifyDestinationParent(PathBuf),
    SaveText {
        target: crate::rename::windows_native::TextExportTarget,
        text: LegacyText,
    },
    ImportNames(PathBuf),
    ImportPaths(PathBuf),
    RecoveryExportDirectory(PreparedRecoveryExportDirectory),
}

pub(super) struct PreparedRecoveryExportDirectory {
    pub(super) parent: crate::rename::windows_native::TextExportParent,
    pub(super) display_path: PathBuf,
}

#[cfg(test)]
pub(super) fn prepare_recovery_export_directory_for_test(
    path: &Path,
) -> io::Result<PreparedRecoveryExportDirectory> {
    Ok(PreparedRecoveryExportDirectory {
        parent: crate::rename::windows_native::prepare_text_export_parent_from_path(path)?,
        display_path: path.to_owned(),
    })
}

pub(super) fn select_prepared_file_dialog(
    owner: HWND,
    kind: PreparedFileDialogKind,
) -> PreparedFileDialogSelection {
    match kind {
        PreparedFileDialogKind::AddFiles {
            remaining_count,
            remaining_path_bytes,
        } => match modal_native_dialog(owner, || {
            pick_bounded_files(owner, remaining_count, remaining_path_bytes)
        }) {
            Ok(Some(paths)) => PreparedFileDialogSelection::AddFiles(paths),
            Ok(None) => PreparedFileDialogSelection::Cancelled,
            Err(error) => {
                message(
                    owner,
                    &format!(
                        "파일 선택을 완료하지 못했습니다: {error}\n다시 파일을 선택해 주세요."
                    ),
                    "DarkReNamer - 파일 선택 실패",
                );
                PreparedFileDialogSelection::Cancelled
            }
        },
        PreparedFileDialogKind::UnifyDestinationParent => modal_native_dialog(owner, || {
            native_file_dialog(owner)
                .set_title("모든 파일을 이동할 대상 폴더 선택")
                .pick_folder()
        })
        .map_or(PreparedFileDialogSelection::Cancelled, |path| {
            PreparedFileDialogSelection::UnifyDestinationParent(path)
        }),
        PreparedFileDialogKind::SaveText { text, names } => {
            let title = if names {
                "파일명 저장"
            } else {
                "경로명 저장"
            };
            let default_name = if names { "names.txt" } else { "paths.txt" };
            match modal_native_dialog(owner, || {
                show_secure_text_save_dialog(owner, title, default_name)
            }) {
                Ok(Some(target)) => PreparedFileDialogSelection::SaveText { target, text },
                Ok(None) => PreparedFileDialogSelection::Cancelled,
                Err(error) => {
                    message(
                        owner,
                        &format!("저장 대화상자를 열지 못했습니다: {error}"),
                        "DarkReNamer - 저장 실패",
                    );
                    PreparedFileDialogSelection::Cancelled
                }
            }
        }
        PreparedFileDialogKind::ImportNames => modal_native_dialog(owner, || {
            native_file_dialog(owner)
                .set_title("바꿀 파일 이름 불러오기")
                .add_filter("Text Files", &["txt"])
                .add_filter("All Files", &["*"])
                .pick_file()
        })
        .map_or(PreparedFileDialogSelection::Cancelled, |path| {
            PreparedFileDialogSelection::ImportNames(path)
        }),
        PreparedFileDialogKind::ImportPaths => modal_native_dialog(owner, || {
            native_file_dialog(owner)
                .set_title("파일에서 경로목록 읽어 추가하기")
                .add_filter("Text Files", &["txt"])
                .add_filter("All Files", &["*"])
                .pick_file()
        })
        .map_or(PreparedFileDialogSelection::Cancelled, |path| {
            PreparedFileDialogSelection::ImportPaths(path)
        }),
        PreparedFileDialogKind::ExportRecoveryJournal => {
            match modal_native_dialog(owner, || show_secure_recovery_export_folder_dialog(owner)) {
                Ok(Some(directory)) => {
                    PreparedFileDialogSelection::RecoveryExportDirectory(directory)
                }
                Ok(None) => PreparedFileDialogSelection::Cancelled,
                Err(error) => {
                    message(
                        owner,
                        &format!("복구 저널 저장 폴더를 열지 못했습니다: {error}"),
                        "DarkReNamer - 진단 내보내기 실패",
                    );
                    PreparedFileDialogSelection::Cancelled
                }
            }
        }
    }
}

// The callbacks use UI-apartment HWND and Rc state. Disabling automatic
// agility removes unsupported free-threaded calls; ordinary COM marshaling
// still follows the caller's apartment rules.
#[implement(IFileDialogEvents, Agile = false)]
struct SecureRecoveryExportFolderEvents {
    owner: HWND,
    directory: Rc<RefCell<Option<PreparedRecoveryExportDirectory>>>,
}

impl IFileDialogEvents_Impl for SecureRecoveryExportFolderEvents_Impl {
    fn OnFileOk(&self, dialog: ::windows::core::Ref<IFileDialog>) -> ::windows::core::Result<()> {
        *self.directory.borrow_mut() = None;
        let mut error_owner = self.owner;
        let directory = dialog
            .ok()
            .map_err(shell_dialog_error)
            .and_then(|dialog| {
                error_owner = file_dialog_message_owner(dialog, self.owner);
                // SAFETY: IFileDialogEvents::OnFileOk is called just before
                // the modal dialog returns and explicitly permits GetResult.
                unsafe { dialog.GetResult() }.map_err(shell_dialog_error)
            })
            .and_then(|item| {
                let (shell_store, shell_identity) = shell_item_identity(&item)?;
                let display_path = dialog_path_for_item(&item)?;
                let parent = crate::rename::windows_native::prepare_text_export_parent(
                    &display_path,
                    shell_identity.volume_id,
                    shell_identity.file_reference_number,
                )?;
                let native_file_reference = parent.ntfs_file_reference_number()?;
                require_matching_folder_identity(
                    shell_identity,
                    ShellFolderIdentity {
                        volume_id: shell_identity.volume_id,
                        file_reference_number: native_file_reference,
                    },
                )?;
                // Keep the shell property store alive until the path traversal
                // and retained native handle have both matched its exact ID.
                drop(shell_store);
                Ok(PreparedRecoveryExportDirectory {
                    parent,
                    display_path,
                })
            });
        match directory {
            Ok(directory) => {
                *self.directory.borrow_mut() = Some(directory);
                Ok(())
            }
            Err(error) => {
                report_recovery_export_folder_error(error_owner, &error);
                Err(WindowsError::from_hresult(::windows::core::HRESULT(1)))
            }
        }
    }

    fn OnFolderChanging(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
        _folder: ::windows::core::Ref<IShellItem>,
    ) -> ::windows::core::Result<()> {
        Ok(())
    }

    fn OnFolderChange(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
    ) -> ::windows::core::Result<()> {
        Ok(())
    }

    fn OnSelectionChange(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
    ) -> ::windows::core::Result<()> {
        Ok(())
    }

    fn OnShareViolation(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
        _item: ::windows::core::Ref<IShellItem>,
    ) -> ::windows::core::Result<::windows::Win32::UI::Shell::FDE_SHAREVIOLATION_RESPONSE> {
        Ok(FDESVR_DEFAULT)
    }

    fn OnTypeChange(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
    ) -> ::windows::core::Result<()> {
        Ok(())
    }

    fn OnOverwrite(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
        _item: ::windows::core::Ref<IShellItem>,
    ) -> ::windows::core::Result<::windows::Win32::UI::Shell::FDE_OVERWRITE_RESPONSE> {
        Ok(FDEOR_DEFAULT)
    }
}

// The retained folder and target state belong to the modal UI apartment.
#[implement(IFileDialogEvents, Agile = false)]
struct SecureTextSaveDialogEvents {
    owner: HWND,
    target: Rc<RefCell<Option<crate::rename::windows_native::TextExportTarget>>>,
    folder: Rc<RefCell<Option<SecureTextSaveFolder>>>,
}

struct SecureTextSaveFolder {
    identity: ShellFolderIdentity,
    parent: crate::rename::windows_native::TextExportParent,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ShellFolderIdentity {
    volume_id: u128,
    file_reference_number: u64,
}

// PKEY_FileFRN and PKEY_VolumeId from Propkey.h. Keep the documented keys local
// because the generated constants require an unrelated EnhancedStorage feature.
const PKEY_FILE_FRN: PROPERTYKEY = PROPERTYKEY {
    fmtid: GUID::from_u128(0xb725f130_47ef_101a_a5f1_02608c9eebac),
    pid: 21,
};

const PKEY_VOLUME_ID: PROPERTYKEY = PROPERTYKEY {
    fmtid: GUID::from_u128(0x446d16b1_8dad_4870_a748_402ea43d788c),
    pid: 104,
};

fn shell_item_identity(item: &IShellItem) -> io::Result<(IPropertyStore, ShellFolderIdentity)> {
    let item = item.cast::<IShellItem2>().map_err(shell_dialog_error)?;
    let keys = [PKEY_VOLUME_ID, PKEY_FILE_FRN];
    // SAFETY: item is a live filesystem shell item on the initialized UI
    // thread; keys remains valid through the synchronous property-store call.
    // The returned store is live while both exact values are read, and the
    // PROPVARIANT conversions finish before their owned storage is released.
    let identity: ::windows::core::Result<(IPropertyStore, GUID, u64)> = unsafe {
        (|| {
            let store: IPropertyStore = item.GetPropertyStoreForKeys(&keys, GPS_DEFAULT)?;
            let volume_id = store.GetValue(&PKEY_VOLUME_ID)?;
            let file_reference_number = store.GetValue(&PKEY_FILE_FRN)?;
            if !has_exact_shell_identity_property_types(
                volume_id.Anonymous.Anonymous.vt,
                file_reference_number.Anonymous.Anonymous.vt,
            ) {
                return Err(WindowsError::new(
                    ::windows::core::HRESULT(0x8007_0057_u32 as i32),
                    "the shell item has no exact NTFS volume and file-reference identity",
                ));
            }
            Ok((
                store,
                PropVariantToGUID(&volume_id)?,
                PropVariantToUInt64(&file_reference_number)?,
            ))
        })()
    };
    let (store, volume_id, file_reference_number) = identity.map_err(shell_dialog_error)?;
    Ok((
        store,
        ShellFolderIdentity {
            volume_id: volume_id.to_u128(),
            file_reference_number,
        },
    ))
}

fn has_exact_shell_identity_property_types(volume_id: VARENUM, file_reference: VARENUM) -> bool {
    volume_id == VT_CLSID && file_reference == VT_UI8
}

fn require_matching_folder_identity(
    expected: ShellFolderIdentity,
    actual: ShellFolderIdentity,
) -> io::Result<()> {
    if expected == actual {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "the selected folder identity changed while the save dialog was open",
        ))
    }
}

impl IFileDialogEvents_Impl for SecureTextSaveDialogEvents_Impl {
    fn OnFileOk(&self, dialog: ::windows::core::Ref<IFileDialog>) -> ::windows::core::Result<()> {
        *self.target.borrow_mut() = None;
        let mut error_owner = self.owner;
        let target = dialog
            .ok()
            .map_err(shell_dialog_error)
            .and_then(|dialog| {
                error_owner = file_dialog_message_owner(dialog, self.owner);
                // SAFETY: IFileDialogEvents::OnFileOk is called just before
                // the modal dialog returns and explicitly permits GetResult.
                unsafe { dialog.GetResult() }.map_err(shell_dialog_error)
            })
            .and_then(|item| {
                // SAFETY: the selected filesystem item has a shell parent, and
                // this COM call borrows both live shell interfaces.
                let selected_parent = unsafe { item.GetParent() }.map_err(shell_dialog_error)?;
                let (selected_parent_store, selected_parent_identity) =
                    shell_item_identity(&selected_parent)?;
                let selected_leaf_snapshot = shell_item_identity(&item).ok();
                let selected_leaf_identity = selected_leaf_snapshot
                    .as_ref()
                    .map(|(_, identity)| *identity);
                let path = dialog_path_for_item(&item)?;
                let leaf = path.file_name().ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "text export destination must have a file name",
                    )
                })?;
                let folder = self.folder.borrow();
                let folder = folder.as_ref().ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "the current save folder was not retained; navigate to it again",
                    )
                })?;
                require_matching_folder_identity(folder.identity, selected_parent_identity)?;
                let target = folder.parent.target_for_leaf(
                    leaf,
                    selected_leaf_identity
                        .map(|identity| (identity.volume_id, identity.file_reference_number)),
                )?;
                drop(selected_leaf_snapshot);
                drop(selected_parent_store);
                Ok(target)
            });
        match target {
            Ok(target) => {
                *self.target.borrow_mut() = Some(target);
                Ok(())
            }
            Err(error) => {
                report_text_save_target_error(error_owner, &error);
                Err(WindowsError::from_hresult(::windows::core::HRESULT(1)))
            }
        }
    }

    fn OnFolderChanging(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
        _folder: ::windows::core::Ref<IShellItem>,
    ) -> ::windows::core::Result<()> {
        Ok(())
    }

    fn OnFolderChange(
        &self,
        dialog: ::windows::core::Ref<IFileDialog>,
    ) -> ::windows::core::Result<()> {
        let folder = dialog
            .ok()
            .ok()
            .and_then(|dialog| {
                // SAFETY: this callback is running for the live modal dialog
                // on the initialized UI thread.
                unsafe { dialog.GetFolder() }.ok()
            })
            .and_then(|item| {
                let (shell_store, shell_identity) = shell_item_identity(&item).ok()?;
                let path = dialog_path_for_item(&item).ok()?;
                let parent = crate::rename::windows_native::prepare_text_export_parent(
                    &path,
                    shell_identity.volume_id,
                    shell_identity.file_reference_number,
                )
                .ok()?;
                let native_file_reference = parent.ntfs_file_reference_number().ok()?;
                require_matching_folder_identity(
                    shell_identity,
                    ShellFolderIdentity {
                        volume_id: shell_identity.volume_id,
                        file_reference_number: native_file_reference,
                    },
                )
                .ok()?;
                // GetPropertyStoreForKeys retains the shell item while the
                // native FRN and volume binding above is established.
                drop(shell_store);
                Some(SecureTextSaveFolder {
                    identity: shell_identity,
                    parent,
                })
            });
        *self.folder.borrow_mut() = folder;
        Ok(())
    }

    fn OnSelectionChange(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
    ) -> ::windows::core::Result<()> {
        Ok(())
    }

    fn OnShareViolation(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
        _item: ::windows::core::Ref<IShellItem>,
    ) -> ::windows::core::Result<::windows::Win32::UI::Shell::FDE_SHAREVIOLATION_RESPONSE> {
        Ok(FDESVR_DEFAULT)
    }

    fn OnTypeChange(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
    ) -> ::windows::core::Result<()> {
        Ok(())
    }

    fn OnOverwrite(
        &self,
        _dialog: ::windows::core::Ref<IFileDialog>,
        _item: ::windows::core::Ref<IShellItem>,
    ) -> ::windows::core::Result<::windows::Win32::UI::Shell::FDE_OVERWRITE_RESPONSE> {
        Ok(FDEOR_REFUSE)
    }
}

fn file_dialog_message_owner(dialog: &IFileDialog, fallback: HWND) -> HWND {
    let Ok(ole_window) = dialog.cast::<IOleWindow>() else {
        return fallback;
    };
    // SAFETY: dialog is the live modal IFileDialog and IOleWindow is queried
    // from that same COM object while its OnFileOk callback is active.
    unsafe { ole_window.GetWindow() }.map_or(fallback, |window| window.0)
}

fn show_secure_text_save_dialog(
    owner: HWND,
    title: &str,
    default_name: &str,
) -> io::Result<Option<crate::rename::windows_native::TextExportTarget>> {
    // SAFETY: the native UI thread was initialized as STA by OleInitialize and
    // keeps every returned COM interface on that same thread.
    let dialog: IFileSaveDialog =
        unsafe { CoCreateInstance(&FileSaveDialog, None, CLSCTX_INPROC_SERVER) }
            .map_err(shell_dialog_error)?;
    let title = wide(title);
    let default_name = wide(default_name);
    let default_extension = wide("txt");
    let text_label = wide("Text Files");
    let text_pattern = wide("*.txt");
    let all_label = wide("All Files");
    let all_pattern = wide("*");
    let filters = [
        COMDLG_FILTERSPEC {
            pszName: PCWSTR(text_label.as_ptr()),
            pszSpec: PCWSTR(text_pattern.as_ptr()),
        },
        COMDLG_FILTERSPEC {
            pszName: PCWSTR(all_label.as_ptr()),
            pszSpec: PCWSTR(all_pattern.as_ptr()),
        },
    ];
    // SAFETY: the dialog is live on its initialized UI thread and GetOptions
    // retrieves its default Save policy before applying the required flags.
    let options = unsafe { dialog.GetOptions() }.map_err(shell_dialog_error)?;
    // SAFETY: the dialog is live on its initialized UI thread and all string
    // and filter buffers remain valid through each synchronous COM call.
    unsafe {
        dialog.SetOptions(secure_text_save_dialog_options(options))?;
        dialog.SetTitle(PCWSTR(title.as_ptr()))?;
        dialog.SetFileName(PCWSTR(default_name.as_ptr()))?;
        dialog.SetDefaultExtension(PCWSTR(default_extension.as_ptr()))?;
        dialog.SetFileTypes(&filters)?;
        dialog.SetFileTypeIndex(1)?;
    }

    let target = Rc::new(RefCell::new(None));
    let folder = Rc::new(RefCell::new(None));
    let events: IFileDialogEvents = SecureTextSaveDialogEvents {
        owner,
        target: Rc::clone(&target),
        folder,
    }
    .into();
    // SAFETY: dialog and event sink stay live through Show. Advise owns a sink
    // reference until Unadvise succeeds or the dialog itself is released.
    let cookie = unsafe { dialog.Advise(&events) }.map_err(shell_dialog_error)?;
    // SAFETY: the dialog and owner belong to the initialized UI thread; Show
    // is modal and OnFileOk retains the selected leaf's metadata guard while
    // the shell identity is live. The exclusive writer opens later, after the
    // dialog releases its shell references.
    let shown = unsafe { dialog.Show(Some(::windows::Win32::Foundation::HWND(owner))) };
    // SAFETY: cookie is the event registration returned by Advise above.
    let unadvised = unsafe { dialog.Unadvise(cookie) };
    drop(events);
    drop(dialog);
    complete_secure_dialog(
        shown,
        unadvised,
        &target,
        "save dialog returned without a retained target",
    )
}

fn complete_secure_dialog<T>(
    shown: ::windows::core::Result<()>,
    unadvised: ::windows::core::Result<()>,
    selected: &RefCell<Option<T>>,
    missing_selection: &'static str,
) -> io::Result<Option<T>> {
    unadvised.map_err(shell_dialog_error)?;
    match shown {
        Ok(()) => selected
            .borrow_mut()
            .take()
            .map(Some)
            .ok_or_else(|| io::Error::other(missing_selection)),
        Err(error) if error.code() == ::windows::core::HRESULT(0x8007_04C7_u32 as i32) => Ok(None),
        Err(error) => Err(shell_dialog_error(error)),
    }
}

fn secure_text_save_dialog_options(
    defaults: ::windows::Win32::UI::Shell::FILEOPENDIALOGOPTIONS,
) -> ::windows::Win32::UI::Shell::FILEOPENDIALOGOPTIONS {
    (defaults & !FOS_OVERWRITEPROMPT) | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR
}

fn report_text_save_target_error(owner: HWND, error: &io::Error) {
    let text = wide(&if error.kind() == io::ErrorKind::AlreadyExists {
        "기존 파일은 덮어쓰지 않습니다. 사용하지 않는 새 파일 이름을 선택해 주세요.".to_owned()
    } else {
        format!(
            "선택한 저장 위치를 안전하게 고정하지 못했습니다. 다른 위치를 선택해 주세요.\n{error}"
        )
    });
    let title = wide("DarkReNamer - 저장 위치 확인");
    // SAFETY: both strings remain NUL-terminated for the synchronous call and
    // owner is the live parent window for this modal file dialog.
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::MessageBoxW(
            owner,
            text.as_ptr(),
            title.as_ptr(),
            windows_sys::Win32::UI::WindowsAndMessaging::MB_OK
                | windows_sys::Win32::UI::WindowsAndMessaging::MB_ICONERROR,
        )
    };
}

fn show_secure_recovery_export_folder_dialog(
    owner: HWND,
) -> io::Result<Option<PreparedRecoveryExportDirectory>> {
    // SAFETY: the native UI thread was initialized as STA by OleInitialize and
    // keeps every returned COM interface on that same thread.
    let dialog: IFileOpenDialog =
        unsafe { CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER) }
            .map_err(shell_dialog_error)?;
    let title = wide("복구 저널 원본을 저장할 폴더 선택");
    // SAFETY: the dialog is live on its initialized UI thread and GetOptions
    // retrieves its default Open policy before applying the required flags.
    let options = unsafe { dialog.GetOptions() }.map_err(shell_dialog_error)?;
    // SAFETY: the dialog is live on its initialized UI thread and the title
    // buffer remains valid through this synchronous COM call.
    unsafe {
        dialog.SetOptions(
            options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR,
        )?;
        dialog.SetTitle(PCWSTR(title.as_ptr()))?;
    }

    let directory = Rc::new(RefCell::new(None));
    let events: IFileDialogEvents = SecureRecoveryExportFolderEvents {
        owner,
        directory: Rc::clone(&directory),
    }
    .into();
    // SAFETY: dialog and event sink stay live through Show. Advise owns a sink
    // reference until Unadvise succeeds or the dialog itself is released.
    let cookie = unsafe { dialog.Advise(&events) }.map_err(shell_dialog_error)?;
    // SAFETY: dialog and owner belong to the initialized UI thread. Show is
    // modal, and OnFileOk binds the selected shell identity to retained native
    // directory handles before the dialog is allowed to return successfully.
    let shown = unsafe { dialog.Show(Some(::windows::Win32::Foundation::HWND(owner))) };
    // SAFETY: cookie is the event registration returned by Advise above.
    let unadvised = unsafe { dialog.Unadvise(cookie) };
    drop(events);
    drop(dialog);
    complete_secure_dialog(
        shown,
        unadvised,
        &directory,
        "folder dialog returned without a retained export directory",
    )
}

fn report_recovery_export_folder_error(owner: HWND, error: &io::Error) {
    let text = wide(&format!(
        "선택한 저장 폴더를 안전하게 고정하지 못했습니다. 다른 폴더를 선택해 주세요.\n{error}"
    ));
    let title = wide("DarkReNamer - 진단 내보내기 위치 확인");
    // SAFETY: both strings remain NUL-terminated for the synchronous call and
    // owner is the live parent window for this modal folder dialog.
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::MessageBoxW(
            owner,
            text.as_ptr(),
            title.as_ptr(),
            windows_sys::Win32::UI::WindowsAndMessaging::MB_OK
                | windows_sys::Win32::UI::WindowsAndMessaging::MB_ICONERROR,
        )
    };
}

fn show_bounded_file_open_dialog(owner: HWND) -> io::Result<Option<IShellItemArray>> {
    // SAFETY: the native UI thread was initialized as STA by OleInitialize and
    // keeps the returned COM interface on that same thread.
    let dialog: IFileOpenDialog =
        unsafe { CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER) }
            .map_err(shell_dialog_error)?;
    let title = wide("이름 붙일 파일 불러오기");
    // SAFETY: the dialog and owner belong to the initialized UI thread; title
    // remains NUL-terminated and alive through SetTitle, and Show is modal.
    unsafe {
        dialog
            .SetOptions(
                FOS_ALLOWMULTISELECT
                    | FOS_FILEMUSTEXIST
                    | FOS_FORCEFILESYSTEM
                    | FOS_NOCHANGEDIR
                    | FOS_PATHMUSTEXIST,
            )
            .map_err(shell_dialog_error)?;
        dialog
            .SetTitle(PCWSTR(title.as_ptr()))
            .map_err(shell_dialog_error)?;
    }
    // SAFETY: `owner` is the live window supplied by the UI-thread caller;
    // the dialog remains alive during this synchronous modal call.
    let shown = unsafe { dialog.Show(Some(::windows::Win32::Foundation::HWND(owner))) };
    complete_bounded_file_dialog(shown, || {
        // SAFETY: this closure runs only after `Show` succeeds, while the
        // dialog and its initialized COM apartment remain live on this thread.
        unsafe { dialog.GetResults() }
    })
}

fn pick_bounded_files(
    owner: HWND,
    remaining_count: usize,
    remaining_path_bytes: usize,
) -> io::Result<Option<Vec<PathBuf>>> {
    let Some(results) = show_bounded_file_open_dialog(owner)? else {
        return Ok(None);
    };
    // SAFETY: results is a live IShellItemArray returned by the successful
    // modal file-open dialog on the initialized UI thread.
    let reported = dialog_item_count(unsafe { results.GetCount() })?;
    let paths = collect_bounded_dialog_paths(
        reported,
        remaining_count,
        PathBudget::from_remaining_bytes(remaining_path_bytes),
        |index| {
            let index =
                u32::try_from(index).map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
            dialog_path_at(&results, index)
        },
    )?;
    Ok(Some(paths))
}

fn complete_bounded_file_dialog<T>(
    shown: ::windows::core::Result<()>,
    get_results: impl FnOnce() -> ::windows::core::Result<T>,
) -> io::Result<Option<T>> {
    match shown {
        Ok(()) => get_results().map(Some).map_err(shell_dialog_error),
        Err(error) if error.code() == ::windows::core::HRESULT(0x8007_04C7_u32 as i32) => Ok(None),
        Err(error) => Err(shell_dialog_error(error)),
    }
}

fn dialog_item_count(result: ::windows::core::Result<u32>) -> io::Result<usize> {
    let reported = result.map_err(shell_dialog_error)?;
    usize::try_from(reported).map_err(|_| io::Error::from(io::ErrorKind::InvalidData))
}

fn collect_bounded_dialog_paths(
    reported: usize,
    remaining_count: usize,
    mut path_budget: PathBudget,
    mut get_path: impl FnMut(usize) -> io::Result<PathBuf>,
) -> io::Result<Vec<PathBuf>> {
    let bounded = bounded_selection(reported, remaining_count);
    let mut paths = Vec::new();
    paths
        .try_reserve_exact(bounded.take)
        .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
    for index in 0..bounded.take {
        let path = get_path(index)?;
        let path_units = path.as_os_str().encode_wide().count();
        let budget_exhausted =
            path_budget.reserve_utf16_units(path_units) == PathBudgetReservation::Exhausted;
        paths.push(path);
        if budget_exhausted {
            break;
        }
    }
    Ok(paths)
}

struct CoTaskMemPath(::windows::core::PWSTR);

impl Drop for CoTaskMemPath {
    fn drop(&mut self) {
        // SAFETY: GetDisplayName returns one CoTaskMem allocation, retained by
        // this guard and released exactly once after its contents are copied.
        unsafe {
            CoTaskMemFree(Some(
                self.0.0.cast::<std::ffi::c_void>() as *const std::ffi::c_void
            ));
        }
    }
}

fn dialog_path_at(results: &IShellItemArray, index: u32) -> io::Result<PathBuf> {
    // SAFETY: results remains live, and index is below the dialog's reported
    // item count and the bounded extraction limit.
    let item = unsafe { results.GetItemAt(index) }.map_err(shell_dialog_error)?;
    dialog_path_for_item(&item)
}

fn dialog_path_for_item(item: &IShellItem) -> io::Result<PathBuf> {
    // SAFETY: item is a live shell item from a dialog configured to return only
    // filesystem objects; the returned CoTaskMem string is owned below.
    let name = unsafe { item.GetDisplayName(SIGDN_FILESYSPATH) }.map_err(shell_dialog_error)?;
    if name.0.is_null() {
        return Err(io::Error::from(io::ErrorKind::InvalidData));
    }
    let name = CoTaskMemPath(name);
    // SAFETY: GetDisplayName returned a readable, NUL-terminated UTF-16 string
    // allocated for this live CoTaskMemPath guard.
    let length = usize::try_from(unsafe { lstrlenW(name.0.0) })
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
    if length == 0 || length > MAX_PATH_UNITS {
        return Err(io::Error::from(io::ErrorKind::InvalidData));
    }
    // SAFETY: lstrlenW measured the NUL-terminated allocation returned by
    // GetDisplayName, and the checked length excludes the terminator.
    let units = unsafe { std::slice::from_raw_parts(name.0.0, length) };
    Ok(PathBuf::from(std::ffi::OsString::from_wide(units)))
}

fn shell_dialog_error(error: ::windows::core::Error) -> io::Error {
    io::Error::other(format!("native file picker failed: {error}"))
}

pub(super) fn set_status(status: HWND, text: &str) {
    let text = wide(text);
    // SAFETY: status is a live UI-thread control and SetWindowTextW copies the
    // terminated buffer synchronously. Callers must release AppState before
    // entry because control/accessibility callbacks may also run synchronously.
    unsafe { windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(status, text.as_ptr()) };
}

pub(super) fn modal_native_dialog<T>(owner: HWND, dialog: impl FnOnce() -> T) -> T {
    let _owner_guard = OwnerEnableGuard::new(owner);
    dialog()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::marker::PhantomData;
    use windows_core::{IInspectable, IUnknown};
    use windows_sys::Win32::System::Ole::{OleInitialize, OleUninitialize};

    struct TestOle {
        _apartment: PhantomData<Rc<()>>,
    }

    impl TestOle {
        fn initialize() -> io::Result<Self> {
            // SAFETY: the reserved pointer is null; Drop balances each
            // successful initialization on this test's current thread.
            let status = unsafe { OleInitialize(null()) };
            if status < 0 {
                Err(io::Error::other(format!(
                    "test OLE initialization failed: 0x{:08X}",
                    status as u32
                )))
            } else {
                Ok(Self {
                    _apartment: PhantomData,
                })
            }
        }
    }

    impl Drop for TestOle {
        fn drop(&mut self) {
            // SAFETY: this guard stays on the initializing test thread and
            // outlives both locally created file-dialog COM objects.
            unsafe { OleUninitialize() };
        }
    }

    fn assert_file_dialog_event_sink_interfaces(
        events: &IFileDialogEvents,
    ) -> windows_core::Result<()> {
        let unknown = events.cast::<IUnknown>()?;
        let supported = unknown.cast::<IFileDialogEvents>()?;
        assert_eq!(supported.cast::<IUnknown>()?, unknown);
        let inspectable = events.cast::<IInspectable>()?;
        assert_eq!(inspectable.cast::<IUnknown>()?, unknown);
        assert!(events.cast::<windows_core::imp::IAgileObject>().is_err());
        assert!(events.cast::<windows_core::imp::IMarshal>().is_err());
        Ok(())
    }

    #[test]
    fn secure_recovery_export_folder_events_are_apartment_bound() -> windows_core::Result<()> {
        let directory = Rc::new(RefCell::new(None));
        let events: IFileDialogEvents = SecureRecoveryExportFolderEvents {
            owner: null_mut(),
            directory: Rc::clone(&directory),
        }
        .into();
        assert_eq!(Rc::strong_count(&directory), 2);
        assert_file_dialog_event_sink_interfaces(&events)?;
        drop(events);
        assert_eq!(Rc::strong_count(&directory), 1);
        Ok(())
    }

    #[test]
    fn secure_text_save_dialog_events_are_apartment_bound() -> windows_core::Result<()> {
        let target = Rc::new(RefCell::new(None));
        let folder = Rc::new(RefCell::new(None));
        let events: IFileDialogEvents = SecureTextSaveDialogEvents {
            owner: null_mut(),
            target: Rc::clone(&target),
            folder: Rc::clone(&folder),
        }
        .into();
        assert_eq!(Rc::strong_count(&target), 2);
        assert_eq!(Rc::strong_count(&folder), 2);
        assert_file_dialog_event_sink_interfaces(&events)?;
        drop(events);
        assert_eq!(Rc::strong_count(&target), 1);
        assert_eq!(Rc::strong_count(&folder), 1);
        Ok(())
    }

    #[test]
    fn secure_dialogs_release_registered_event_sinks() -> Result<(), Box<dyn std::error::Error>> {
        let _ole = TestOle::initialize()?;

        // SAFETY: OLE is initialized on this test thread; the local interface
        // and its event registration are released before the guard drops.
        let save: IFileSaveDialog =
            unsafe { CoCreateInstance(&FileSaveDialog, None, CLSCTX_INPROC_SERVER) }?;
        let target = Rc::new(RefCell::new(None));
        let folder = Rc::new(RefCell::new(None));
        let save_events: IFileDialogEvents = SecureTextSaveDialogEvents {
            owner: null_mut(),
            target: Rc::clone(&target),
            folder: Rc::clone(&folder),
        }
        .into();
        // SAFETY: the test keeps both apartment-bound COM objects alive until
        // their exact registration has been removed.
        let save_cookie = unsafe { save.Advise(&save_events) }?;
        assert_eq!(Rc::strong_count(&target), 2);
        assert_eq!(Rc::strong_count(&folder), 2);
        drop(save_events);
        assert_eq!(Rc::strong_count(&target), 2);
        assert_eq!(Rc::strong_count(&folder), 2);
        // SAFETY: save_cookie came from this save dialog's Advise call.
        unsafe { save.Unadvise(save_cookie) }?;
        assert_eq!(Rc::strong_count(&target), 1);
        assert_eq!(Rc::strong_count(&folder), 1);
        drop(save);

        // SAFETY: the same initialized apartment owns this dialog and sink.
        let open: IFileOpenDialog =
            unsafe { CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER) }?;
        let directory = Rc::new(RefCell::new(None));
        let open_events: IFileDialogEvents = SecureRecoveryExportFolderEvents {
            owner: null_mut(),
            directory: Rc::clone(&directory),
        }
        .into();
        // SAFETY: both COM objects stay on this initialized test apartment.
        let open_cookie = unsafe { open.Advise(&open_events) }?;
        assert_eq!(Rc::strong_count(&directory), 2);
        drop(open_events);
        assert_eq!(Rc::strong_count(&directory), 2);
        // SAFETY: open_cookie came from this open dialog's Advise call.
        unsafe { open.Unadvise(open_cookie) }?;
        assert_eq!(Rc::strong_count(&directory), 1);
        drop(open);
        Ok(())
    }

    #[test]
    fn secure_dialog_completion_handles_injected_show_outcomes() -> io::Result<()> {
        let selected = RefCell::new(Some(7_u8));
        assert_eq!(
            complete_secure_dialog(Ok(()), Ok(()), &selected, "missing")?,
            Some(7)
        );
        assert_eq!(*selected.borrow(), None);
        assert!(complete_secure_dialog(Ok(()), Ok(()), &selected, "missing").is_err());

        let cancelled =
            WindowsError::from_hresult(::windows::core::HRESULT(0x8007_04C7_u32 as i32));
        assert_eq!(
            complete_secure_dialog(Err(cancelled), Ok(()), &selected, "missing")?,
            None
        );
        let failed = WindowsError::from_hresult(::windows::core::HRESULT(0x8000_4005_u32 as i32));
        assert!(complete_secure_dialog(Err(failed), Ok(()), &selected, "missing").is_err());
        let unadvise_failed =
            WindowsError::from_hresult(::windows::core::HRESULT(0x8000_4005_u32 as i32));
        selected.replace(Some(9));
        assert!(
            complete_secure_dialog(Ok(()), Err(unadvise_failed), &selected, "missing").is_err()
        );
        assert_eq!(*selected.borrow(), Some(9));
        Ok(())
    }

    thread_local! {
        static PROMPT_QUIT_AT_ENTRY: std::cell::Cell<Option<i32>> = const { std::cell::Cell::new(None) };
        static PROMPT_QUIT_RECEIVED: std::cell::Cell<Option<(u32, usize)>> = const { std::cell::Cell::new(None) };
    }

    pub(super) fn inject_prompt_quit_for_test() {
        if let Some(code) = PROMPT_QUIT_AT_ENTRY.with(std::cell::Cell::take) {
            // SAFETY: this thread-local test stimulus queues quit only after
            // native prompt setup, immediately before its actual modal pump.
            unsafe { PostQuitMessage(code) };
        }
    }

    pub(super) fn record_prompt_quit_for_test(status: i32, message: &MSG) {
        if status == 0 {
            PROMPT_QUIT_RECEIVED.with(|received| {
                received.set(Some((message.message, message.wParam)));
            });
        }
    }

    struct PromptTestOwner(HWND);

    impl PromptTestOwner {
        fn create() -> io::Result<Self> {
            // SAFETY: system STATIC and the current module remain live for
            // this UI-thread-owned parent, which its guard destroys exactly once.
            let window = unsafe {
                CreateWindowExW(
                    0,
                    wide("STATIC").as_ptr(),
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
            if window.is_null() {
                Err(io::Error::last_os_error())
            } else {
                Ok(Self(window))
            }
        }
    }

    impl Drop for PromptTestOwner {
        fn drop(&mut self) {
            // SAFETY: this is our one test-owned parent. Its owned prompts have
            // either already closed or still retain their caller-owned slots.
            unsafe { DestroyWindow(self.0) };
        }
    }

    fn prompt_test_appearance(theme: AppThemeMode) -> PromptAppearance {
        PromptAppearance {
            preference: UiAppearance {
                theme,
                ..UiAppearance::default()
            },
            forced_colors: ForcedColorsState::Inactive,
            system_theme: Some(ResolvedTheme::Light),
        }
    }

    fn prompt_test_spec() -> PromptSpec {
        PromptSpec {
            caption: "Prompt callback regression".to_owned(),
            title: "Native prompt controls".to_owned(),
            label_one: "First".to_owned(),
            label_two: "Second".to_owned(),
            value_one: LegacyText::from("one"),
            value_two: LegacyText::from("two"),
            choices: vec!["First choice".to_owned(), "Second choice".to_owned()],
        }
    }

    struct FontReentryProbe {
        parent: HWND,
        slot: *mut PromptStateSlot,
        destroy_parent: bool,
        busy_hits: Cell<usize>,
        color_hits: Cell<usize>,
        idle_paints: Cell<usize>,
        nested_brush: Cell<LRESULT>,
    }

    // Deliberate deterministic regression, separate from natural OS
    // characterization: WM_SETFONT drives one valid parent color callback.
    unsafe extern "system" fn prompt_font_reentry(
        control: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        _id: usize,
        refdata: usize,
    ) -> LRESULT {
        // SAFETY: the subclass guard retains this separate scalar/Cell sidecar
        // until confirmed detach or complete child destruction.
        let probe = unsafe { &*(refdata as *const FontReentryProbe) };
        // SAFETY: the modal owner retains the slot through this child callback;
        // is_busy reads only its disjoint scalar status, never PromptState.
        let busy = unsafe { CallbackState::is_busy(probe.slot) };
        if message == WM_SETFONT {
            probe
                .busy_hits
                .set(probe.busy_hits.get() + usize::from(busy));
            if probe.destroy_parent {
                // SAFETY: deliberately destroy the actual parent while its
                // font callback has a lease; the modal owner retains the slot.
                unsafe { DestroyWindow(probe.parent) };
                return 0;
            }
            // SAFETY: control and its parent are live; the borrowed DC is
            // retained through one synchronous color notification and released.
            unsafe {
                let dc = GetDC(control);
                if !dc.is_null() {
                    probe.color_hits.set(probe.color_hits.get() + 1);
                    probe.nested_brush.set(SendMessageW(
                        probe.parent,
                        WM_CTLCOLORSTATIC,
                        dc as usize,
                        control as isize,
                    ));
                    ReleaseDC(control, dc);
                }
            }
        } else if message == windows_sys::Win32::UI::WindowsAndMessaging::WM_PAINT && !busy {
            probe.idle_paints.set(probe.idle_paints.get() + 1);
        }
        // SAFETY: callback arguments are unchanged and the subclass is live.
        unsafe { DefSubclassProc(control, message, wparam, lparam) }
    }

    struct PromptFontSubclass {
        control: HWND,
        probe: Option<Box<FontReentryProbe>>,
    }

    impl PromptFontSubclass {
        fn install(prompt: &PromptWindow, destroy_parent: bool) -> io::Result<Self> {
            let control = prompt.lease()?.state().title;
            let probe = Box::new(FontReentryProbe {
                parent: prompt.window,
                slot: prompt.slot,
                destroy_parent,
                busy_hits: Cell::new(0),
                color_hits: Cell::new(0),
                idle_paints: Cell::new(0),
                nested_brush: Cell::new(0),
            });
            // SAFETY: control is the live STATIC title. The boxed scalar
            // sidecar remains stable until this guard detaches the subclass.
            if unsafe {
                SetWindowSubclass(
                    control,
                    Some(prompt_font_reentry),
                    1,
                    (&*probe as *const FontReentryProbe) as usize,
                )
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(Self {
                control,
                probe: Some(probe),
            })
        }
    }

    impl Drop for PromptFontSubclass {
        fn drop(&mut self) {
            // SAFETY: detach this exact callback/id or confirm that child
            // destruction has already ended every native use of its refdata.
            let detached = unsafe {
                RemoveWindowSubclass(self.control, Some(prompt_font_reentry), 1) != 0
                    || IsWindow(self.control) == 0
            };
            if !detached && let Some(probe) = self.probe.take() {
                // Preserve the bounded context if native detach is ambiguous.
                let _ = Box::leak(probe);
            }
        }
    }

    #[test]
    fn native_prompt_font_reentry_uses_fallback_then_repaints_current_palette() -> io::Result<()> {
        let owner = PromptTestOwner::create()?;
        let prompt = create_prompt_window(
            owner.0,
            prompt_test_appearance(AppThemeMode::Dark),
            prompt_test_spec(),
            false,
        )?;
        let brush = prompt
            .lease()?
            .state()
            .appearance_resources
            .as_ref()
            .ok_or_else(|| io::Error::other("native prompt palette was not created"))?
            .dialog_brush() as LRESULT;
        let subclass = PromptFontSubclass::install(&prompt, false)?;
        let probe = subclass
            .probe
            .as_ref()
            .ok_or_else(|| io::Error::other("missing subclass probe"))?;
        // SAFETY: show the actual live prompt without retaining its state.
        unsafe {
            ShowWindow(prompt.window, SW_SHOW);
            UpdateWindow(prompt.window);
        }
        probe.idle_paints.set(0);
        // SAFETY: drive the production refresh after excluding initial paint
        // counts; this test retains only the disjoint scalar/Cell sidecar.
        unsafe { SendMessageW(prompt.window, WM_FONTCHANGE, 0, 0) };
        assert!(probe.busy_hits.get() > 0);
        assert!(probe.color_hits.get() > 0);
        assert_ne!(probe.nested_brush.get(), brush);
        assert!(
            probe.idle_paints.get() > 0,
            "font refresh must repaint after releasing its lease"
        );
        // SAFETY: the STATIC child/DC are live and the parent callback now has
        // no outer lease. Verify that palette coloring is restored immediately.
        let current_brush = unsafe {
            let dc = GetDC(subclass.control);
            if dc.is_null() {
                return Err(io::Error::last_os_error());
            }
            let brush = SendMessageW(
                prompt.window,
                WM_CTLCOLORSTATIC,
                dc as usize,
                subclass.control as isize,
            );
            ReleaseDC(subclass.control, dc);
            brush
        };
        assert_eq!(current_brush, brush);
        drop(prompt.lease()?);
        Ok(())
    }

    #[test]
    fn native_prompt_nested_destruction_ends_modal_wait_without_reclaiming_active_state()
    -> io::Result<()> {
        let owner = PromptTestOwner::create()?;
        let prompt = create_prompt_window(
            owner.0,
            prompt_test_appearance(AppThemeMode::Dark),
            prompt_test_spec(),
            false,
        )?;
        let _subclass = PromptFontSubclass::install(&prompt, true)?;
        // SAFETY: the child callback deliberately destroys its parent during
        // this actual production refresh. The caller still owns the state slot.
        unsafe { SendMessageW(prompt.window, WM_FONTCHANGE, 0, 0) };
        assert!(prompt_state_slot(prompt.window).is_null());
        drop(prompt.lease()?);
        assert!(
            !prompt.lease()?.state().done,
            "native destruction does not use the close command path"
        );
        assert!(
            prompt.finished()?,
            "detached publication must end the modal loop"
        );
        Ok(())
    }

    #[test]
    fn native_prompt_refresh_preserves_values_buttons_and_final_palette() -> io::Result<()> {
        let owner = PromptTestOwner::create()?;
        for theme in [
            AppThemeMode::Light,
            AppThemeMode::Dark,
            AppThemeMode::System,
        ] {
            for read_only in [false, true] {
                let prompt = create_prompt_window(
                    owner.0,
                    prompt_test_appearance(theme),
                    prompt_test_spec(),
                    read_only,
                )?;
                let window = prompt.window;
                let setting = wide("WindowMetrics");
                // SAFETY: show the actual prompt and refresh standard children
                // without subclassing or injecting parent paint/color messages.
                unsafe {
                    ShowWindow(window, SW_SHOW);
                    UpdateWindow(window);
                    SendMessageW(window, WM_FONTCHANGE, 0, 0);
                    SendMessageW(window, WM_SETTINGCHANGE, 0, setting.as_ptr() as isize);
                    SendMessageW(window, WM_THEMECHANGED, 0, 0);
                    SendMessageW(window, WM_SYSCOLORCHANGE, 0, 0);
                    let dpi = GetDpiForWindow(window) as usize;
                    SendMessageW(window, WM_DPICHANGED, dpi | (dpi << 16), 0);
                }
                drop(prompt.lease()?);
                assert!(!prompt.finished()?);
                let (edit, ok, cancel, font) = {
                    let lease = prompt.lease()?;
                    let state = lease.state();
                    (state.edit_one, state.ok, state.cancel, state.font.as_raw())
                };
                assert!(!font.is_null());
                assert_eq!(prompt_window_text(edit)?, LegacyText::from("one"));
                let palette =
                    prompt
                        .lease()?
                        .state()
                        .appearance_resources
                        .as_ref()
                        .map(|resources| {
                            (
                                resources.control_normal_brush() as LRESULT,
                                resources.palette().control_normal,
                            )
                        });
                if let Some((expected_brush, expected_background)) = palette {
                    // SAFETY: the live edit/DC use the actual post-refresh
                    // color callback. Only copied palette scalars are retained.
                    let (brush, background) = unsafe {
                        let dc = GetDC(edit);
                        if dc.is_null() {
                            return Err(io::Error::last_os_error());
                        }
                        let brush = SendMessageW(
                            window,
                            if read_only {
                                WM_CTLCOLORSTATIC
                            } else {
                                WM_CTLCOLOREDIT
                            },
                            dc as usize,
                            edit as isize,
                        );
                        let background = windows_sys::Win32::Graphics::Gdi::GetBkColor(dc);
                        ReleaseDC(edit, dc);
                        (brush, background)
                    };
                    assert_eq!(brush, expected_brush);
                    assert_eq!(background, expected_background);
                }
                // SAFETY: these are live standard BUTTON controls; copied
                // style queries and a focus notification cannot close the prompt.
                unsafe {
                    assert_ne!(
                        GetWindowLongPtrW(
                            if read_only { cancel } else { ok },
                            windows_sys::Win32::UI::WindowsAndMessaging::GWL_STYLE
                        ) as u32
                            & BS_DEFPUSHBUTTON as u32,
                        0
                    );
                    SendMessageW(
                        window,
                        WM_COMMAND,
                        IDOK as usize | ((BN_SETFOCUS as usize) << 16),
                        ok as isize,
                    );
                }
                assert!(!prompt.finished()?);
                // SAFETY: only an actual clicked Accept/Close command ends this
                // prompt. The read-only Copy action remains covered separately.
                unsafe {
                    SendMessageW(
                        window,
                        WM_COMMAND,
                        if read_only { IDCANCEL } else { IDOK } as usize,
                        if read_only { cancel } else { ok } as isize,
                    );
                }
                assert!(prompt.finished()?);
                let result = prompt.lease()?.state_mut().result.take();
                if read_only {
                    assert!(result.is_none());
                } else {
                    let result =
                        result.ok_or_else(|| io::Error::other("native prompt did not accept"))?;
                    assert_eq!(result.value_one, LegacyText::from("one"));
                    assert_eq!(result.value_two, LegacyText::from("two"));
                    assert_eq!(result.choice, 0);
                }
            }
        }
        Ok(())
    }

    #[test]
    fn native_prompt_failed_creation_and_quit_restore_owner_and_clear_publication() -> io::Result<()>
    {
        let owner = PromptTestOwner::create()?;
        let mut spec = prompt_test_spec();
        spec.value_one =
            LegacyText::from_units(vec![u16::from(b'x'); MAX_TEXT_DETAILS_UTF16_UNITS + 1]);
        let Err(error) = prompt_input_variant(
            owner.0,
            prompt_test_appearance(AppThemeMode::Dark),
            spec,
            true,
        ) else {
            return Err(io::Error::other(
                "oversized details prompt unexpectedly opened",
            ));
        };
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        // Arm the quit only at the real modal GetMessage entry. Queuing it
        // before native control creation also exercises unrelated setup pumps.
        PROMPT_QUIT_AT_ENTRY.with(|pending| pending.set(Some(7)));
        PROMPT_QUIT_RECEIVED.with(|received| received.set(None));
        // SAFETY: the owned parent is live and must still be enabled after the
        // failed creation. The injected quit belongs only to this test thread.
        unsafe {
            assert_ne!(IsWindowEnabled(owner.0), 0);
        }
        assert!(
            prompt_input_variant(
                owner.0,
                prompt_test_appearance(AppThemeMode::Dark),
                prompt_test_spec(),
                false
            )?
            .is_none()
        );
        assert_eq!(
            PROMPT_QUIT_RECEIVED.with(std::cell::Cell::take),
            Some((windows_sys::Win32::UI::WindowsAndMessaging::WM_QUIT, 7))
        );
        let mut quit = MSG::default();
        let mut received_quit = false;
        // PostQuitMessage generates a low-priority message once the queue is
        // quiet. Drain teardown messages as the outer, unfiltered pump would;
        // one filtered Peek can return zero while those messages remain queued.
        for _ in 0..256 {
            // SAFETY: this test owns the UI thread and writable message storage.
            let available = unsafe {
                windows_sys::Win32::UI::WindowsAndMessaging::PeekMessageW(
                    &mut quit,
                    null_mut(),
                    0,
                    0,
                    windows_sys::Win32::UI::WindowsAndMessaging::PM_REMOVE,
                )
            };
            if available == 0 {
                break;
            }
            if quit.message == windows_sys::Win32::UI::WindowsAndMessaging::WM_QUIT {
                received_quit = true;
                break;
            }
            // SAFETY: normally dispatch only messages retrieved on this owned
            // UI thread, without retaining any prompt-state reference.
            unsafe {
                TranslateMessage(&quit);
                DispatchMessageW(&quit);
            }
        }
        assert!(
            received_quit,
            "the outer pump must receive the reposted quit"
        );
        assert_eq!(quit.wParam, 7);
        // SAFETY: the owned parent outlives prompt teardown and quit retrieval.
        assert_ne!(unsafe { IsWindowEnabled(owner.0) }, 0);
        Ok(())
    }

    #[test]
    fn add_files_picker_extracts_only_capacity_plus_one_witness() -> io::Result<()> {
        let mut calls = 0;
        let paths = collect_bounded_dialog_paths(100_000, 2, PathBudget::new(), |index| {
            calls += 1;
            Ok(PathBuf::from(format!(r"C:\selected\{index}.txt")))
        })?;

        assert_eq!(calls, 3);
        assert_eq!(paths.len(), 3);
        Ok(())
    }

    #[test]
    fn add_files_picker_stops_after_one_path_budget_witness() -> io::Result<()> {
        let mut calls = 0;
        let paths =
            collect_bounded_dialog_paths(100, 100, PathBudget::from_remaining_bytes(1), |_| {
                calls += 1;
                Ok(PathBuf::from(r"C:\selected\first.txt"))
            })?;

        assert_eq!(calls, 1);
        assert_eq!(paths.len(), 1);
        Ok(())
    }

    #[test]
    fn add_files_picker_treats_only_shell_cancel_as_cancellation() -> io::Result<()> {
        let cancelled =
            ::windows::core::Error::from_hresult(::windows::core::HRESULT(0x8007_04C7_u32 as i32));
        let mut get_results_calls = 0;
        assert!(
            complete_bounded_file_dialog(Err(cancelled), || {
                get_results_calls += 1;
                Ok(())
            })?
            .is_none()
        );
        assert_eq!(get_results_calls, 0);

        let failure =
            ::windows::core::Error::from_hresult(::windows::core::HRESULT(0x8000_4005_u32 as i32));
        assert_eq!(
            complete_bounded_file_dialog(Err(failure), || Ok(()))
                .err()
                .map(|error| error.kind()),
            Some(io::ErrorKind::Other)
        );

        let get_results_failure =
            ::windows::core::Error::from_hresult(::windows::core::HRESULT(0x8000_4005_u32 as i32));
        assert_eq!(
            complete_bounded_file_dialog(Ok(()), || Err::<(), _>(get_results_failure))
                .err()
                .map(|error| error.kind()),
            Some(io::ErrorKind::Other)
        );

        Ok(())
    }

    #[test]
    fn add_files_picker_preserves_item_count_and_path_errors() {
        let count_error =
            ::windows::core::Error::from_hresult(::windows::core::HRESULT(0x8000_4005_u32 as i32));
        assert_eq!(
            dialog_item_count(Err(count_error))
                .err()
                .map(|error| error.kind()),
            Some(io::ErrorKind::Other)
        );

        assert!(matches!(
            collect_bounded_dialog_paths(1, 1, PathBudget::new(), |_| {
                Err(io::Error::from(io::ErrorKind::PermissionDenied))
            }),
            Err(error) if error.kind() == io::ErrorKind::PermissionDenied
        ));
    }

    #[test]
    fn secure_save_dialog_keeps_default_read_only_protection() {
        use ::windows::Win32::UI::Shell::FOS_NOREADONLYRETURN;

        let options = secure_text_save_dialog_options(FOS_NOREADONLYRETURN | FOS_OVERWRITEPROMPT);

        assert!(options.contains(FOS_NOREADONLYRETURN));
        assert!(options.contains(FOS_FORCEFILESYSTEM));
        assert!(options.contains(FOS_PATHMUSTEXIST));
        assert!(options.contains(FOS_NOCHANGEDIR));
        assert!(!options.contains(FOS_OVERWRITEPROMPT));
    }

    #[test]
    fn secure_save_dialog_rejects_changed_folder_identity() {
        let expected = ShellFolderIdentity {
            volume_id: 1,
            file_reference_number: 0x1234,
        };
        assert!(matches!(
            require_matching_folder_identity(
                expected,
                ShellFolderIdentity {
                    volume_id: 1,
                    file_reference_number: 0x5678,
                },
            ),
            Err(error) if error.kind() == io::ErrorKind::InvalidInput
        ));
        assert!(
            require_matching_folder_identity(
                expected,
                ShellFolderIdentity {
                    volume_id: 2,
                    file_reference_number: expected.file_reference_number,
                },
            )
            .is_err()
        );
    }

    #[test]
    fn secure_save_dialog_treats_empty_shell_file_identity_as_missing() {
        use ::windows::Win32::System::Variant::VT_EMPTY;

        assert!(has_exact_shell_identity_property_types(VT_CLSID, VT_UI8));
        assert!(!has_exact_shell_identity_property_types(VT_CLSID, VT_EMPTY));
        assert!(!has_exact_shell_identity_property_types(VT_EMPTY, VT_UI8));
    }

    #[test]
    fn read_only_layout_grows_by_measured_lines_and_keeps_footer_inside_work_area() -> io::Result<()>
    {
        let maximum = LayoutRect {
            x: 0,
            y: 0,
            width: 640,
            height: 480,
        };
        let layout = calculate_read_only_prompt_layout(
            BASE_DPI,
            PromptFontMetrics {
                title_width: 520,
                title_height: 18,
                label_width: 0,
                label_height: 0,
                line_height: 18,
            },
            maximum,
        );
        let edit = layout
            .edit_one
            .ok_or_else(|| io::Error::other("missing read-only edit"))?;
        assert_eq!(edit.x, layout.title.x);
        assert_eq!(edit.width, layout.title.width);
        assert!(edit.height >= 12 * 18);
        assert!(layout.client.width <= maximum.width);
        assert!(layout.client.height <= maximum.height);
        assert!(layout.separator.y >= edit.bottom());
        assert!(layout.ok.width > scale_dip(75, BASE_DPI));
        assert!(layout.ok.right() <= layout.cancel.x);
        assert!(layout.cancel.right() <= layout.client.width);
        assert!(layout.cancel.bottom() <= layout.client.height);

        let constrained = calculate_read_only_prompt_layout(
            192,
            PromptFontMetrics {
                title_width: 1_200,
                title_height: 72,
                label_width: 0,
                label_height: 0,
                line_height: 36,
            },
            LayoutRect {
                x: 0,
                y: 0,
                width: 360,
                height: 260,
            },
        );
        assert!(constrained.client.width <= 360);
        assert!(constrained.client.height <= 260);
        assert!(constrained.ok.bottom() <= constrained.client.height);
        assert!(constrained.cancel.bottom() <= constrained.client.height);
        assert_eq!(prompt_extended_style(false), WS_EX_TOOLWINDOW);
        assert_eq!(prompt_extended_style(true), 0);
        Ok(())
    }

    #[test]
    fn text_details_reject_text_beyond_the_bounded_path_budget() -> io::Result<()> {
        let oversized = "x".repeat(MAX_TEXT_DETAILS_UTF16_UNITS + 1);
        let Err(error) = text_details_value(&oversized) else {
            return Err(io::Error::other("oversized details were accepted"));
        };
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        Ok(())
    }

    #[test]
    fn dynamic_system_symbol_resolution_succeeds_and_missing_symbols_fail_closed()
    -> Result<(), Box<dyn std::error::Error>> {
        let kernel = DynamicLibrary::load_system("kernel32.dll")?;
        assert!(kernel.resolve(b"GetCurrentProcessId\0").is_ok());
        let Err(error) = kernel.resolve(b"DarkReNamerMissingSymbol\0") else {
            return Err(io::Error::other("missing symbol unexpectedly resolved").into());
        };
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert!(error.to_string().contains("DarkReNamerMissingSymbol"));
        Ok(())
    }

    #[test]
    fn native_prompt_bounds_both_edits_and_rejects_programmatic_limit_bypass()
    -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: the system STATIC class and current module remain live for
        // this hidden, test-owned prompt parent.
        let parent = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
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
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }

        let result = (|| -> io::Result<()> {
            let mut maximum_units =
                vec![u16::from(b'a'); darknamer_core::MAX_PROPOSED_NAME_UTF16_UNITS];
            maximum_units[..5].copy_from_slice(&[0xd800, u16::from(b'a'), 0xdc00, 0xd83d, 0xde00]);
            let maximum_value = LegacyText::from_units(maximum_units);
            let exact_second_value = LegacyText::from_units(vec![
                0xdc00,
                u16::from(b'-'),
                0xd800,
                0xd83d,
                0xde00,
                0xac12,
            ]);
            let mut state = PromptState {
                spec: PromptSpec {
                    caption: "테스트 입력".to_owned(),
                    title: "입력".to_owned(),
                    label_one: "첫째".to_owned(),
                    label_two: "둘째".to_owned(),
                    value_one: maximum_value.clone(),
                    value_two: exact_second_value.clone(),
                    choices: Vec::new(),
                },
                read_only: false,
                result: None,
                done: false,
                owner: parent,
                title: null_mut(),
                label_one: null_mut(),
                label_two: null_mut(),
                edit_one: null_mut(),
                edit_two: null_mut(),
                combo: null_mut(),
                separator: null_mut(),
                ok: null_mut(),
                cancel: null_mut(),
                font: OwnedFont::default(),
                appearance: PromptAppearance {
                    preference: UiAppearance::default(),
                    forced_colors: ForcedColorsState::Inactive,
                    system_theme: Some(ResolvedTheme::Light),
                },
                appearance_resources: None,
                creation_error: None,
                dpi: BASE_DPI,
            };
            create_prompt_children(parent, &mut state)?;

            for edit in [state.edit_one, state.edit_two] {
                assert_eq!(
                    // SAFETY: edit is a live test-owned standard EDIT control
                    // and EM_GETLIMITTEXT has no pointer payload.
                    unsafe {
                        SendMessageW(
                            edit,
                            windows_sys::Win32::UI::Controls::EM_GETLIMITTEXT,
                            0,
                            0,
                        )
                    },
                    (darknamer_core::MAX_PROPOSED_NAME_UTF16_UNITS + 1) as LRESULT
                );
            }
            assert_eq!(prompt_window_text(state.edit_one)?, maximum_value);
            assert_eq!(prompt_window_text(state.edit_two)?, exact_second_value);
            let accepted_without_edit = prompt_result(&state)?;
            assert_eq!(accepted_without_edit.value_one, maximum_value);
            assert_eq!(accepted_without_edit.value_two, exact_second_value);

            let oversized = wide(&"x".repeat(darknamer_core::MAX_PROPOSED_NAME_UTF16_UNITS + 1));
            assert_ne!(
                // SAFETY: edit_two is live and oversized is terminated and
                // retained through this synchronous programmatic WM_SETTEXT
                // path. EM_SETLIMITTEXT does not constrain this path.
                unsafe {
                    windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(
                        state.edit_two,
                        oversized.as_ptr(),
                    )
                },
                0
            );
            let error = match prompt_window_text(state.edit_two) {
                Ok(_) => return Err(io::Error::other("oversized prompt text was accepted")),
                Err(error) => error,
            };
            assert_eq!(error.kind(), io::ErrorKind::InvalidData);
            Ok(())
        })();

        // SAFETY: parent is test-owned and destroys every prompt child.
        unsafe { DestroyWindow(parent) };
        result.map_err(Into::into)
    }

    #[test]
    fn read_only_details_preserve_crlf_text_and_native_copy_selection_styles()
    -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: the system STATIC class and current module remain live for
        // this hidden, test-owned prompt parent.
        let parent = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
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
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }

        let result = (|| -> io::Result<()> {
            let long_path = format!(r"C:\긴 상위 경로\{}-𠮷.txt", "공통접두어".repeat(3_000));
            assert!(LegacyText::from(long_path.as_str()).len() <= MAX_PATH_UNITS);
            let source =
                format!("현재: {long_path}\n변경 후: {long_path}.renamed\r선택 경로: {long_path}");
            let details = text_details_value(&source)?;
            let expected = LegacyText::from(
                format!(
                    "현재: {long_path}\r\n변경 후: {long_path}.renamed\r\n선택 경로: {long_path}"
                )
                .as_str(),
            );
            assert!(details.len() > MAX_PROMPT_TEXT_UTF16_UNITS);
            assert!(details.len() > MAX_PATH_UNITS);
            assert_eq!(details, expected);

            let mut state = PromptState {
                spec: PromptSpec {
                    caption: "전체 정보".to_owned(),
                    title: "전체 이름과 경로".to_owned(),
                    label_one: String::new(),
                    label_two: String::new(),
                    value_one: details.clone(),
                    value_two: LegacyText::default(),
                    choices: Vec::new(),
                },
                read_only: true,
                result: None,
                done: false,
                owner: parent,
                title: null_mut(),
                label_one: null_mut(),
                label_two: null_mut(),
                edit_one: null_mut(),
                edit_two: null_mut(),
                combo: null_mut(),
                separator: null_mut(),
                ok: null_mut(),
                cancel: null_mut(),
                font: OwnedFont::default(),
                appearance: PromptAppearance {
                    preference: UiAppearance::default(),
                    forced_colors: ForcedColorsState::Inactive,
                    system_theme: Some(ResolvedTheme::Light),
                },
                appearance_resources: None,
                creation_error: None,
                dpi: BASE_DPI,
            };
            create_prompt_children(parent, &mut state)?;

            // SAFETY: edit_one is the live test-owned EDIT; both queries return
            // scalar values and use no caller-provided output pointers.
            let (edit_style, text_limit) = unsafe {
                (
                    GetWindowLongPtrW(state.edit_one, GWL_STYLE) as u32,
                    SendMessageW(
                        state.edit_one,
                        windows_sys::Win32::UI::Controls::EM_GETLIMITTEXT,
                        0,
                        0,
                    ),
                )
            };
            assert_ne!(
                edit_style & windows_sys::Win32::UI::WindowsAndMessaging::ES_MULTILINE as u32,
                0
            );
            assert_ne!(
                edit_style & windows_sys::Win32::UI::WindowsAndMessaging::ES_READONLY as u32,
                0
            );
            assert_ne!(
                edit_style & windows_sys::Win32::UI::WindowsAndMessaging::ES_AUTOVSCROLL as u32,
                0
            );
            assert_ne!(
                edit_style & windows_sys::Win32::UI::WindowsAndMessaging::WS_VSCROLL,
                0
            );
            assert_eq!(edit_style & ES_AUTOHSCROLL as u32, 0);
            assert_eq!(text_limit, MAX_TEXT_DETAILS_UTF16_UNITS as LRESULT);
            assert_eq!(
                prompt_window_text_with_limit(state.edit_one, MAX_TEXT_DETAILS_UTF16_UNITS)?,
                details
            );
            assert_eq!(
                prompt_window_text(state.ok)?,
                LegacyText::from("전체 복사(&C)")
            );
            assert_eq!(prompt_window_text(state.cancel)?, LegacyText::from("닫기"));
            assert_eq!(
                prompt_button_action(true, IDOK, BN_CLICKED),
                PromptButtonAction::CopyAll
            );
            assert_eq!(
                prompt_button_action(true, IDCANCEL, BN_CLICKED),
                PromptButtonAction::Close
            );
            assert_eq!(
                prompt_button_action(false, IDOK, BN_CLICKED),
                PromptButtonAction::Accept
            );
            assert_eq!(
                prompt_button_action(true, IDOK, BN_SETFOCUS),
                PromptButtonAction::None
            );
            Ok(())
        })();

        // SAFETY: parent is test-owned and destroys every details child.
        unsafe { DestroyWindow(parent) };
        result.map_err(Into::into)
    }

    #[test]
    fn owned_task_dialog_keeps_cancel_default_and_all_native_buffers_live()
    -> Result<(), Box<dyn std::error::Error>> {
        let owner = 1_usize as HWND;
        let button_specs = [
            TaskDialogButtonSpec {
                id: DIRECTORY_DIRECT_BUTTON_ID,
                text: "선택한 폴더만 추가",
            },
            TaskDialogButtonSpec {
                id: DIRECTORY_RECURSE_BUTTON_ID,
                text: "하위 파일을 모두 추가",
            },
        ];
        let dialog = OwnedTaskDialog::new(
            owner,
            TaskDialogSpec {
                title: "제목",
                main_instruction: "선택",
                content: "범위",
                expanded_information: Some("진단"),
                buttons: &button_specs,
                warning: true,
            },
        )?;

        let config = dialog.config;
        let configured_owner = config.hwndParent;
        let flags = config.dwFlags;
        let common_buttons = config.dwCommonButtons;
        let default_button = config.nDefaultButton;
        let button_count = config.cButtons;
        let button_pointer = config.pButtons;
        let title_pointer = config.pszWindowTitle;
        let instruction_pointer = config.pszMainInstruction;
        let content_pointer = config.pszContent;
        let expanded_pointer = config.pszExpandedInformation;
        let expand_label_pointer = config.pszCollapsedControlText;
        let collapse_label_pointer = config.pszExpandedControlText;
        // SAFETY: Anonymous1 was initialized with the warning-icon pointer above.
        let main_icon = unsafe { config.Anonymous1.pszMainIcon };
        let first_button_id = dialog._buttons[0].nButtonID;
        let second_button_id = dialog._buttons[1].nButtonID;
        let first_button_text = dialog._buttons[0].pszButtonText;
        let second_button_text = dialog._buttons[1].pszButtonText;

        assert_eq!(configured_owner, owner);
        assert_eq!(common_buttons, TDCBF_CANCEL_BUTTON);
        assert_eq!(default_button, IDCANCEL);
        assert_eq!(button_count, 2);
        assert_eq!(button_pointer, dialog._buttons.as_ptr());
        assert_eq!(first_button_id, DIRECTORY_DIRECT_BUTTON_ID);
        assert_eq!(second_button_id, DIRECTORY_RECURSE_BUTTON_ID);
        assert_eq!(main_icon, TD_WARNING_ICON);
        assert_ne!(flags & TDF_USE_COMMAND_LINKS, 0);
        assert_ne!(flags & TDF_ALLOW_DIALOG_CANCELLATION, 0);
        assert_ne!(flags & TDF_POSITION_RELATIVE_TO_WINDOW, 0);
        assert_ne!(flags & TDF_SIZE_TO_CONTENT, 0);
        for pointer in [
            title_pointer,
            instruction_pointer,
            content_pointer,
            expanded_pointer,
            expand_label_pointer,
            collapse_label_pointer,
            first_button_text,
            second_button_text,
        ] {
            assert!(!pointer.is_null());
        }
        Ok(())
    }
}
