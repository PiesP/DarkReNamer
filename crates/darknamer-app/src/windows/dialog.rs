use super::*;
use windows_sys::Win32::Foundation::{FreeLibrary, HMODULE};
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
    let mut state = Box::new(PromptState {
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
    let state_ptr: *mut PromptState = &mut *state;
    // SAFETY: owner/instance are live and class_name/title plus stack PromptState
    // remain allocated for the complete synchronous prompt CreateWindowExW call.
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
            state_ptr.cast(),
        )
    };
    if dialog.is_null() {
        return Err(state
            .creation_error
            .take()
            .unwrap_or_else(io::Error::last_os_error));
    }
    // SAFETY: window is the non-null top-level HWND just created and remains owned by this UI thread.
    let _owner_guard = OwnerEnableGuard::new(owner);
    // SAFETY: window is the non-null top-level HWND just created and remains owned by this UI thread.
    unsafe {
        ShowWindow(dialog, SW_SHOW);
        UpdateWindow(dialog);
    }
    let mut message = MSG::default();
    while !state.done {
        // SAFETY: message is writable MSG storage outliving GetMessageW; null HWND requests this thread queue.
        let status = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if status == -1 {
            let error = io::Error::last_os_error();
            // SAFETY: dialog is the live prompt HWND created above and has not
            // been destroyed on this GetMessageW error path.
            unsafe { DestroyWindow(dialog) };
            state.done = true;
            return Err(error);
        }
        if status == 0 {
            // SAFETY: dialog is the live prompt HWND; it is destroyed once before
            // the original WM_QUIT code is reposted to the same thread.
            unsafe {
                DestroyWindow(dialog);
                PostQuitMessage(message.wParam as i32);
            }
            state.done = true;
            return Ok(None);
        }
        // SAFETY: dialog is the live prompt HWND and message is initialized MSG storage from GetMessageW.
        if unsafe { IsDialogMessageW(dialog, &message) } == 0 {
            // SAFETY: message was initialized by GetMessageW and remains valid through synchronous translation and dispatch.
            unsafe {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }
    if let Some(error) = state.creation_error.take() {
        return Err(error);
    }
    Ok(state.result.take())
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
            // SAFETY: WM_NCCREATE supplies a readable CREATESTRUCTW whose
            // lpCreateParams is the borrowed pointer to prompt_input's live local Box.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, (*create).lpCreateParams as isize) };
        }
    }
    // SAFETY: GWLP_USERDATA holds the borrowed pointer to prompt_input's local
    // PromptState Box, which remains live until this modal dialog is destroyed.
    let state_ptr = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut PromptState;
    match message {
        WM_CREATE if !state_ptr.is_null() => {
            // SAFETY: state_ptr borrows prompt_input's live local Box and is
            // confined to this modal callback thread until WM_NCDESTROY clears it.
            let state = unsafe { &mut *state_ptr };
            let created = create_prompt_children(window, state);
            if let Err(error) = created {
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
            if !first.is_null() {
                // SAFETY: first is a non-null child HWND created for this active dialog and remains live while focus is assigned.
                unsafe { SetFocus(first) };
            }
            0
        }
        WM_ERASEBKGND if !state_ptr.is_null() => {
            // SAFETY: state_ptr is live prompt state and wparam is this callback's DC.
            let state = unsafe { &*state_ptr };
            if let Some(resources) = state.appearance_resources.as_ref() {
                let mut rect = RECT::default();
                // SAFETY: window/DC are live and rect is writable.
                unsafe {
                    GetClientRect(window, &mut rect);
                    FillRect(wparam as HDC, &rect, resources.dialog_brush());
                }
                1
            } else {
                // SAFETY: native fallback retains the system class background path.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_DRAWITEM if !state_ptr.is_null() => {
            // SAFETY: state_ptr and the synchronous draw payload are live.
            let state = unsafe { &*state_ptr };
            if draw_owner_separator(state.appearance_resources.as_ref(), state.separator, lparam) {
                1
            } else {
                // SAFETY: unrecognized payload retains standard handling.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_NOTIFY if !state_ptr.is_null() => {
            // SAFETY: state_ptr and the synchronous notification are live.
            let state = unsafe { &*state_ptr };
            let resources = state.appearance_resources.as_ref();
            if resources.is_some()
                && let Some(result) = draw_custom_button(resources, state.ok, lparam)
                    .or_else(|| draw_custom_button(resources, state.cancel, lparam))
            {
                result
            } else {
                // SAFETY: native fallback and unrelated notifications retain default handling.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_CTLCOLORSTATIC if !state_ptr.is_null() => {
            // SAFETY: state_ptr and callback DC/control HWND are live synchronously.
            let state = unsafe { &*state_ptr };
            let resources = state.appearance_resources.as_ref();
            resources.map_or_else(
                || {
                    // SAFETY: native fallback retains system control coloring.
                    unsafe { DefWindowProcW(window, message, wparam, lparam) }
                },
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
        WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX if !state_ptr.is_null() => {
            // SAFETY: state_ptr and callback DC are live synchronously.
            let resources = unsafe { (*state_ptr).appearance_resources.as_ref() };
            resources.map_or_else(
                || {
                    // SAFETY: native fallback retains system edit/list-box coloring.
                    unsafe { DefWindowProcW(window, message, wparam, lparam) }
                },
                |resources| prompt_input_color(resources, wparam as HDC),
            )
        }
        WM_DPICHANGED if !state_ptr.is_null() => {
            // SAFETY: state_ptr borrows the live prompt state on its owning UI thread.
            let state = unsafe { &mut *state_ptr };
            let next_dpi = (wparam & 0xFFFF) as u32;
            state.dpi = if next_dpi == 0 { BASE_DPI } else { next_dpi };
            let suggested = lparam as *const RECT;
            if !suggested.is_null() {
                // SAFETY: WM_DPICHANGED provides a readable suggested RECT for this live prompt.
                let suggested = unsafe { *suggested };
                // SAFETY: window is live and suggested geometry is supplied by Windows for this DPI transition.
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
        WM_THEMECHANGED | WM_SYSCOLORCHANGE if !state_ptr.is_null() => {
            // SAFETY: state_ptr borrows the live prompt state on its owning UI thread.
            let state = unsafe { &mut *state_ptr };
            requery_prompt_appearance(window, state);
            0
        }
        WM_SETTINGCHANGE if !state_ptr.is_null() => {
            // SAFETY: state_ptr borrows the live prompt state on its owning UI thread.
            let state = unsafe { &mut *state_ptr };
            // SAFETY: window is the live prompt HWND.
            let dpi = unsafe { GetDpiForWindow(window) };
            state.dpi = if dpi == 0 { BASE_DPI } else { dpi };
            recreate_prompt_font(state);
            requery_prompt_appearance(window, state);
            arrange_prompt(window, state, false);
            0
        }
        WM_FONTCHANGE if !state_ptr.is_null() => {
            // SAFETY: state_ptr borrows the live prompt state on its owning UI thread.
            let state = unsafe { &mut *state_ptr };
            // SAFETY: window is the live prompt HWND.
            let dpi = unsafe { GetDpiForWindow(window) };
            state.dpi = if dpi == 0 { BASE_DPI } else { dpi };
            recreate_prompt_font(state);
            arrange_prompt(window, state, false);
            0
        }
        WM_COMMAND if !state_ptr.is_null() => {
            let id = (wparam & 0xFFFF) as i32;
            let notification = ((wparam >> 16) & 0xFFFF) as u32;
            // SAFETY: state_ptr is the live prompt state and this scalar read
            // creates no reference that survives synchronous command handling.
            let read_only = unsafe { (*state_ptr).read_only };
            match prompt_button_action(read_only, id, notification) {
                PromptButtonAction::CopyAll => {
                    // SAFETY: state_ptr borrows the live local PromptState. The
                    // cloned text ends this borrow before clipboard ownership
                    // or any resulting synchronous window work begins.
                    let text = unsafe { (*state_ptr).spec.value_one.clone() };
                    if let Err(error) = copy_clipboard(window, &text) {
                        // SAFETY: clipboard work has returned, so state_ptr may
                        // be borrowed again only to record the terminal error.
                        unsafe {
                            (*state_ptr).creation_error = Some(error);
                            (*state_ptr).done = true;
                            DestroyWindow(window);
                        }
                    }
                }
                PromptButtonAction::Accept => {
                    // SAFETY: state_ptr borrows prompt_input's live local Box and is
                    // confined to this modal callback thread until WM_NCDESTROY clears it.
                    let state = unsafe { &mut *state_ptr };
                    match prompt_result(state) {
                        Ok(result) => state.result = Some(result),
                        Err(error) => state.creation_error = Some(error),
                    }
                    state.done = true;
                    // SAFETY: window is the live prompt HWND and IDOK has not yet
                    // destroyed it on this callback path.
                    unsafe { DestroyWindow(window) };
                }
                PromptButtonAction::Close => {
                    // SAFETY: state_ptr is the non-null borrowed pointer to the live
                    // local PromptState Box for this modal callback.
                    unsafe { (*state_ptr).done = true };
                    // SAFETY: window is the live prompt HWND and IDCANCEL destroys it
                    // exactly once after recording completion.
                    unsafe { DestroyWindow(window) };
                }
                PromptButtonAction::None => {}
            }
            0
        }
        WM_CLOSE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the non-null borrowed pointer to the live local
            // PromptState Box for this modal callback.
            unsafe { (*state_ptr).done = true };
            // SAFETY: window is the live prompt HWND and WM_CLOSE destroys it once
            // after marking the local boxed PromptState complete.
            unsafe { DestroyWindow(window) };
            0
        }
        WM_NCDESTROY if !state_ptr.is_null() => {
            // SAFETY: window is the active prompt HWND; clearing GWLP_USERDATA
            // ends the borrowed association before prompt_input drops its local
            // Box and its unambiguously owned font.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
            // SAFETY: window, message, wparam, and lparam are unchanged values from the active Windows callback.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
        // SAFETY: window, message, wparam, and lparam are unchanged values from the active Windows callback.
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
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
        &value.to_string_lossy(),
        id,
        WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
    )?;
    // SAFETY: edit is the live standard EDIT just created above. The message
    // copies no pointer payload and the UTF-16-unit bound excludes the null.
    unsafe {
        SendMessageW(
            edit,
            windows_sys::Win32::UI::Controls::EM_SETLIMITTEXT,
            MAX_PROMPT_CONTROL_UTF16_UNITS,
            0,
        )
    };
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
    AddFiles,
    UnifyDestinationParent,
    SaveText { text: LegacyText, names: bool },
    ImportNames,
    ImportPaths,
    ExportRecoveryJournal,
}

pub(super) enum PreparedFileDialogSelection {
    Cancelled,
    AddFiles(Vec<PathBuf>),
    UnifyDestinationParent(PathBuf),
    SaveText { path: PathBuf, text: LegacyText },
    ImportNames(PathBuf),
    ImportPaths(PathBuf),
    RecoveryExportDirectory(PathBuf),
}

pub(super) fn select_prepared_file_dialog(
    owner: HWND,
    kind: PreparedFileDialogKind,
) -> PreparedFileDialogSelection {
    match kind {
        PreparedFileDialogKind::AddFiles => modal_native_dialog(owner, || {
            native_file_dialog(owner)
                .set_title("이름 붙일 파일 불러오기")
                .add_filter("All Files", &["*"])
                .pick_files()
        })
        .map_or(PreparedFileDialogSelection::Cancelled, |paths| {
            PreparedFileDialogSelection::AddFiles(paths)
        }),
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
            modal_native_dialog(owner, || {
                native_file_dialog(owner)
                    .set_title(title)
                    .add_filter("Text Files", &["txt"])
                    .add_filter("All Files", &["*"])
                    .set_file_name(default_name)
                    .save_file()
            })
            .map_or(PreparedFileDialogSelection::Cancelled, |path| {
                PreparedFileDialogSelection::SaveText { path, text }
            })
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
        PreparedFileDialogKind::ExportRecoveryJournal => modal_native_dialog(owner, || {
            native_file_dialog(owner)
                .set_title("복구 저널 원본을 저장할 폴더 선택")
                .pick_folder()
        })
        .map_or(PreparedFileDialogSelection::Cancelled, |path| {
            PreparedFileDialogSelection::RecoveryExportDirectory(path)
        }),
    }
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
            let maximum_value = LegacyText::from_units(vec![
                u16::from(b'a');
                darknamer_core::MAX_PROPOSED_NAME_UTF16_UNITS
            ]);
            let ordinary_second_value = LegacyText::from("둘째 값");
            let mut state = PromptState {
                spec: PromptSpec {
                    caption: "테스트 입력".to_owned(),
                    title: "입력".to_owned(),
                    label_one: "첫째".to_owned(),
                    label_two: "둘째".to_owned(),
                    value_one: maximum_value.clone(),
                    value_two: ordinary_second_value.clone(),
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
            assert_eq!(prompt_window_text(state.edit_two)?, ordinary_second_value);

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
