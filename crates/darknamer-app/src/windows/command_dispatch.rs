use super::*;

pub(super) struct AcceleratorTable(HACCEL);

impl AcceleratorTable {
    pub(super) fn create() -> io::Result<Self> {
        let entries = native_accelerator_entries();
        let count = i32::try_from(entries.len())
            .map_err(|_| io::Error::other("too many native accelerators"))?;
        // SAFETY: entries is contiguous initialized ACCEL storage retained for
        // the complete synchronous CreateAcceleratorTableW call.
        let handle = unsafe { CreateAcceleratorTableW(entries.as_ptr(), count) };
        if handle.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self(handle))
        }
    }

    pub(super) fn translate(&self, window: HWND, message: &MSG) -> bool {
        // TranslateAcceleratorW provides the standard key-down command path;
        // only the catalog's intentional legacy command mappings are retained.
        // SAFETY: self owns a live accelerator table, window is the live main
        // HWND, and message is initialized MSG storage from GetMessageW.
        unsafe { TranslateAcceleratorW(window, self.0, message) != 0 }
    }
}

impl Drop for AcceleratorTable {
    fn drop(&mut self) {
        // SAFETY: this RAII owner destroys its non-null HACCEL exactly once and
        // no TranslateAcceleratorW call can outlive the UI-thread owner.
        unsafe { DestroyAcceleratorTable(self.0) };
    }
}

fn native_accelerator_entries() -> Vec<ACCEL> {
    legacy_command_shortcuts()
        .map(|spec| ACCEL {
            fVirt: FVIRTKEY
                | match spec.shortcut.modifiers {
                    LegacyShortcutModifiers::None => 0,
                    LegacyShortcutModifiers::Control => FCONTROL,
                    LegacyShortcutModifiers::ControlShift => FCONTROL | FSHIFT,
                },
            key: match spec.shortcut.virtual_key {
                LegacyVirtualKey::Character(key) => key,
                LegacyVirtualKey::Delete => VK_DELETE,
                LegacyVirtualKey::Escape => VK_ESCAPE,
                LegacyVirtualKey::OemComma => VK_OEM_COMMA,
                LegacyVirtualKey::OemPeriod => VK_OEM_PERIOD,
            },
            cmd: spec.command,
        })
        .collect()
}

#[cfg(test)]
mod accelerator_tests {
    use super::*;

    #[test]
    fn native_accelerators_use_standard_key_down_with_exact_legacy_bindings() {
        let entries = native_accelerator_entries();
        assert_eq!(entries.len(), legacy_command_shortcuts().count());
        let exact = |command| entries.iter().find(|entry| entry.cmd == command).copied();
        assert_eq!(
            exact(SORT).map(|entry| (entry.fVirt, entry.key)),
            Some((FVIRTKEY | FCONTROL, u16::from(b'A')))
        );
        assert_eq!(
            exact(SAVE_NAMES).map(|entry| (entry.fVirt, entry.key)),
            Some((FVIRTKEY | FCONTROL, u16::from(b'X')))
        );
        assert_eq!(
            exact(IMPORT_NAMES).map(|entry| (entry.fVirt, entry.key)),
            Some((FVIRTKEY | FCONTROL, u16::from(b'V')))
        );
        assert_eq!(
            exact(EXIT_COMMAND).map(|entry| (entry.fVirt, entry.key)),
            Some((FVIRTKEY, VK_ESCAPE))
        );
        assert_eq!(exact(MOVE_UP).map(|entry| entry.key), Some(VK_OEM_COMMA));
        assert_eq!(exact(MOVE_DOWN).map(|entry| entry.key), Some(VK_OEM_PERIOD));
        let mut bindings = entries
            .iter()
            .map(|entry| (entry.fVirt, entry.key))
            .collect::<Vec<_>>();
        bindings.sort_unstable();
        bindings.dedup();
        assert_eq!(bindings.len(), entries.len());
    }

    #[test]
    fn programmatic_list_update_deferral_is_scoped_and_nestable() {
        assert!(!programmatic_list_update_active());
        let outer = ProgrammaticListUpdateGuard::begin();
        assert!(programmatic_list_update_active());
        {
            let _inner = ProgrammaticListUpdateGuard::begin();
            assert!(programmatic_list_update_active());
        }
        assert!(programmatic_list_update_active());
        drop(outer);
        assert!(!programmatic_list_update_active());
    }

    #[test]
    fn prompt_completion_requires_the_same_session_revision_and_unlocked_state() {
        let revision = ModelRevision::new(7);
        assert!(prompt_result_can_apply(
            Some(3),
            3,
            PromptCompletionLocks::default(),
            revision,
            revision,
        ));
        for blocked in [
            prompt_result_can_apply(
                Some(4),
                3,
                PromptCompletionLocks::default(),
                revision,
                revision,
            ),
            prompt_result_can_apply(
                None,
                3,
                PromptCompletionLocks::default(),
                revision,
                revision,
            ),
            prompt_result_can_apply(
                Some(3),
                3,
                PromptCompletionLocks {
                    close_pending: true,
                    ..PromptCompletionLocks::default()
                },
                revision,
                revision,
            ),
            prompt_result_can_apply(
                Some(3),
                3,
                PromptCompletionLocks {
                    read_only_locked: true,
                    ..PromptCompletionLocks::default()
                },
                revision,
                revision,
            ),
            prompt_result_can_apply(
                Some(3),
                3,
                PromptCompletionLocks {
                    mutation_locked: true,
                    ..PromptCompletionLocks::default()
                },
                revision,
                revision,
            ),
            prompt_result_can_apply(
                Some(3),
                3,
                PromptCompletionLocks {
                    worker_active: true,
                    ..PromptCompletionLocks::default()
                },
                revision,
                revision,
            ),
            prompt_result_can_apply(
                Some(3),
                3,
                PromptCompletionLocks::default(),
                ModelRevision::new(8),
                revision,
            ),
        ] {
            assert!(!blocked);
        }
    }
}

pub(super) fn selected_indices(list: HWND) -> Vec<usize> {
    let mut indices = Vec::new();
    let mut index = -1_i32;
    loop {
        // SAFETY: list is the live AppState ListView HWND and LVM_GETNEXTITEM uses
        // only index/state values, with no pointer payload.
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

thread_local! {
    static PROGRAMMATIC_LIST_UPDATE_DEPTH: Cell<u32> = const { Cell::new(0) };
}

pub(super) struct ProgrammaticListUpdateGuard;

impl ProgrammaticListUpdateGuard {
    pub(super) fn begin() -> Self {
        PROGRAMMATIC_LIST_UPDATE_DEPTH.with(|depth| depth.set(depth.get().saturating_add(1)));
        Self
    }
}

impl Drop for ProgrammaticListUpdateGuard {
    fn drop(&mut self) {
        PROGRAMMATIC_LIST_UPDATE_DEPTH.with(|depth| depth.set(depth.get().saturating_sub(1)));
    }
}

pub(super) fn programmatic_list_update_active() -> bool {
    PROGRAMMATIC_LIST_UPDATE_DEPTH.with(|depth| depth.get() != 0)
}

pub(super) fn select_rows(list: HWND, rows: &[usize]) {
    select_rows_with_focus(list, rows, rows.first().copied());
}

pub(super) fn focused_index(list: HWND) -> Option<usize> {
    // SAFETY: list is the live AppState ListView HWND and LVM_GETNEXTITEM carries
    // only the focused-state mask, with no pointer payload.
    let index = unsafe { SendMessageW(list, LVM_GETNEXTITEM, usize::MAX, LVNI_FOCUSED as isize) };
    (index >= 0).then_some(index as usize)
}

pub(super) fn select_rows_with_focus(list: HWND, rows: &[usize], focused: Option<usize>) {
    let _selection_guard = ProgrammaticListUpdateGuard::begin();
    for row in rows {
        let mut item = LVITEMW {
            stateMask: LVIS_SELECTED | LVIS_FOCUSED,
            state: LVIS_SELECTED
                | if Some(*row) == focused {
                    LVIS_FOCUSED
                } else {
                    0
                },
            ..LVITEMW::default()
        };
        // SAFETY: list is live and item is writable LVITEMW storage retained until
        // synchronous LVM_SETITEMSTATE returns.
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
        // SAFETY: list is live and LVM_ENSUREVISIBLE carries only the validated
        // row index, with no pointer payload.
        unsafe { SendMessageW(list, LVM_ENSUREVISIBLE, *row, 0) };
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct SelectionToken {
    path: LegacyText,
    occurrence: usize,
}

pub(super) fn selection_tokens(model: &LegacyList, selected: &[usize]) -> Vec<SelectionToken> {
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

pub(super) fn selection_token(model: &LegacyList, index: usize) -> Option<SelectionToken> {
    model.items().get(index).map(|item| SelectionToken {
        path: item.source_path().clone(),
        occurrence: model.items()[..index]
            .iter()
            .filter(|previous| previous.source_path() == item.source_path())
            .count(),
    })
}

pub(super) fn rows_for_tokens(model: &LegacyList, tokens: &[SelectionToken]) -> Vec<usize> {
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

pub(super) struct PreparedPrompt {
    session_id: u64,
    expected_revision: ModelRevision,
    appearance: PromptAppearance,
    spec: PromptSpec,
    continuation: PromptContinuation,
}

enum PromptContinuation {
    ManualChange { row: usize },
    Replace,
    Prefix,
    Suffix,
    ExtensionAdd,
    ExtensionReplace,
    PadDigits,
    Sequence,
    DeletePosition,
    DeleteDelimited,
    Sort,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct PromptCompletionLocks {
    close_pending: bool,
    read_only_locked: bool,
    mutation_locked: bool,
    worker_active: bool,
}

pub(super) fn dispatch_command(
    window: HWND,
    state: &mut AppState,
    command: u16,
) -> Option<PreparedPrompt> {
    if state.active_prompt.is_some() {
        return None;
    }
    if let Some(dialog) = active_appearance_dialog(state) {
        // SAFETY: dialog is the live owned modal surface; owner commands remain
        // inert until the dialog reaches OK or Cancel.
        unsafe { SetForegroundWindow(dialog) };
        return None;
    }
    if state.read_only_locked() && !recovery_command_allowed(command) {
        message(
            window,
            "복구 잠금 상태에서는 진단 저널 내보내기, 테마 변경, 정보 보기, 종료만 사용할 수 있습니다.",
            "DarkReNamer - 읽기 전용",
        );
        return None;
    }
    let activity = state.worker_activity();
    let worker_active = activity.admission || activity.plan || activity.apply;
    if state.mutation_locked
        && !matches!(command, VERSION | EXIT_COMMAND)
        && !appearance_command_allowed(command, worker_active)
    {
        message(
            window,
            "파일 변경이 끝날 때까지 테마 변경, 정보 보기와 종료 요청만 사용할 수 있습니다.",
            "DarkReNamer - 변경 중",
        );
        return None;
    }
    if let Some(prompt) = prepare_prompt_command(state, command) {
        return Some(prompt);
    }
    let mut selection_restore = None;
    let outcome = match command {
        APPLY => {
            apply_changes(window, state);
            CommandOutcome::ui(UiEffect::None)
        }
        RESET => proposal_mutation(state, LegacyList::reset_proposals_changed),
        CLEAR_LIST => {
            let changed = state.model.clear();
            model_outcome(state, changed, UiEffect::AllRowsChanged)
        }
        DELETE_SELECTED_COMMAND => {
            let selected = selected_indices(state.list_window);
            selection_restore = Some(SelectionRestore::default());
            let changed = state.model.remove_rows(&selected) != 0;
            model_outcome(state, changed, UiEffect::AllRowsChanged)
        }
        MOVE_UP => {
            let selected = selected_indices(state.list_window);
            let focused_position = focused_index(state.list_window)
                .and_then(|focused| selected.iter().position(|index| *index == focused));
            let movement = state.model.move_rows_earlier_changed(&selected);
            let changed = movement.changed();
            let moved = movement.into_rows();
            let outcome = model_outcome(
                state,
                changed,
                UiEffect::RowsChanged(changed_move_rows(&selected, &moved)),
            );
            let focused = focused_position.and_then(|position| moved.get(position).copied());
            selection_restore = Some(SelectionRestore {
                rows: moved,
                focused,
            });
            outcome
        }
        MOVE_DOWN => {
            let selected = selected_indices(state.list_window);
            let focused_position = focused_index(state.list_window)
                .and_then(|focused| selected.iter().position(|index| *index == focused));
            let movement = state.model.move_rows_later_changed(&selected);
            let changed = movement.changed();
            let moved = movement.into_rows();
            let outcome = model_outcome(
                state,
                changed,
                UiEffect::RowsChanged(changed_move_rows(&selected, &moved)),
            );
            let focused = focused_position.and_then(|position| moved.get(position).copied());
            selection_restore = Some(SelectionRestore {
                rows: moved,
                focused,
            });
            outcome
        }
        CLEAR_NAME => proposal_mutation(state, LegacyList::clear_name_changed),
        KEEP_DIGITS => proposal_mutation(state, LegacyList::keep_ascii_digits_changed),
        EXT_DELETE => proposal_mutation(state, LegacyList::delete_extension_changed),
        PARENT_PREFIX => proposal_mutation(state, LegacyList::prefix_parent_folder_changed),
        PARENT_SUFFIX => proposal_mutation(state, LegacyList::suffix_parent_folder_changed),
        UNIFY_PATH => {
            message(
                window,
                safe_mode_unify_path_message(),
                "DarkReNamer - Safe 모드",
            );
            CommandOutcome::ui(UiEffect::None)
        }
        ADD_FILES => {
            add_files_dialog(window, state);
            CommandOutcome::ui(UiEffect::None)
        }
        COPY_NAMES => {
            copy_clipboard_or_report(window, &state.model.export_names());
            CommandOutcome::ui(UiEffect::None)
        }
        COPY_PATHS => {
            copy_clipboard_or_report(window, &state.model.export_paths());
            CommandOutcome::ui(UiEffect::None)
        }
        SAVE_NAMES => {
            save_text_dialog(window, state.model.export_names(), true);
            CommandOutcome::ui(UiEffect::None)
        }
        SAVE_PATHS => {
            save_text_dialog(window, state.model.export_paths(), false);
            CommandOutcome::ui(UiEffect::None)
        }
        IMPORT_NAMES => {
            let changed = import_names_dialog(window, state);
            proposal_outcome(state, changed)
        }
        IMPORT_PATHS => {
            import_paths_dialog(window, state);
            CommandOutcome::ui(UiEffect::None)
        }
        SHOW_FULL_PATH | SHOW_SIZE | SHOW_MODIFIED | SHOW_CREATED => {
            let index = usize::from(command - SHOW_FULL_PATH);
            state.shown_columns[index] = !state.shown_columns[index];
            CommandOutcome::ui(UiEffect::ColumnsChanged(index))
        }
        VERSION => {
            message(window, &super::about_text(), "DarkReNamer 정보");
            CommandOutcome::ui(UiEffect::None)
        }
        EXPORT_RECOVERY_JOURNAL => {
            export_recovery_journal(window, state);
            CommandOutcome::ui(UiEffect::None)
        }
        DISCARD_STAGED_JOURNAL => {
            discard_staged_journal(window, state);
            CommandOutcome::ui(UiEffect::None)
        }
        SHOW_RECOVERY_STATUS => {
            show_recovery_status(window, state);
            CommandOutcome::ui(UiEffect::None)
        }
        THEME_SYSTEM | THEME_LIGHT | THEME_DARK => {
            let appearance = appearance_after_theme_command(state.appearance, command)?;
            if appearance == state.appearance {
                CommandOutcome::ui(UiEffect::None)
            } else {
                state.appearance = appearance;
                CommandOutcome::ui(UiEffect::AppearanceChanged)
            }
        }
        APPEARANCE_ADVANCED => {
            open_appearance_dialog(window, state);
            CommandOutcome::ui(UiEffect::None)
        }
        EXIT_COMMAND => CommandOutcome::ui(UiEffect::CloseRequested),
        _ => CommandOutcome::ui(UiEffect::None),
    };
    debug_assert!(command_effect_fits_policy(command, &outcome));
    apply_command_outcome(window, state, outcome, selection_restore);
    None
}

#[derive(Default)]
struct SelectionRestore {
    rows: Box<[usize]>,
    focused: Option<usize>,
}

fn model_outcome(state: &mut AppState, changed: bool, effect: UiEffect) -> CommandOutcome {
    state.commit_known_model_change(changed);
    CommandOutcome::model(changed, effect)
}

fn proposal_outcome(state: &mut AppState, changed: Box<[usize]>) -> CommandOutcome {
    let did_change = !changed.is_empty();
    model_outcome(state, did_change, UiEffect::ProposalRowsChanged(changed))
}

fn proposal_mutation(
    state: &mut AppState,
    mutation: impl FnOnce(&mut LegacyList) -> Box<[usize]>,
) -> CommandOutcome {
    let changed = mutation(&mut state.model);
    proposal_outcome(state, changed)
}

fn apply_command_outcome(
    window: HWND,
    state: &mut AppState,
    outcome: CommandOutcome,
    selection: Option<SelectionRestore>,
) {
    match outcome.into_effect() {
        UiEffect::None => {}
        UiEffect::RowsChanged(rows) => {
            refresh_changed_rows(state, &rows);
            restore_selection(state, selection);
            update_controls(state);
        }
        UiEffect::ProposalRowsChanged(rows) => {
            refresh_proposal_rows(state, &rows);
            update_controls(state);
        }
        UiEffect::AllRowsChanged => {
            if selection.is_some() {
                clear_selection(state.list_window);
            }
            refresh_all_rows(state);
            restore_selection(state, selection);
            update_controls(state);
            state.set_status_item_count();
        }
        UiEffect::ColumnsChanged(index) => {
            update_column_visibility(state, index);
            update_primary_column_widths(state);
            state.persist_column_preferences();
            update_controls(state);
        }
        UiEffect::AppearanceChanged => {
            state.persist_appearance_preferences();
            apply_native_appearance_nonblocking(window, state);
            update_controls(state);
            arrange(window, state);
        }
        UiEffect::CloseRequested => request_window_close(window, state),
    }
}

fn restore_selection(state: &mut AppState, selection: Option<SelectionRestore>) {
    let Some(selection) = selection else {
        return;
    };
    clear_selection(state.list_window);
    select_rows_with_focus(state.list_window, &selection.rows, selection.focused);
}

pub(super) const fn recovery_command_allowed(command: u16) -> bool {
    appearance_command_allowed(command, false)
        || matches!(
            command,
            VERSION
                | EXPORT_RECOVERY_JOURNAL
                | DISCARD_STAGED_JOURNAL
                | SHOW_RECOVERY_STATUS
                | EXIT_COMMAND
        )
}

pub(super) fn prompt_spec(
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

pub(super) fn legacy_atoi(text: &LegacyText) -> i32 {
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

fn prepare_prompt_command(state: &mut AppState, command: u16) -> Option<PreparedPrompt> {
    let (spec, continuation) = match command {
        MANUAL_CHANGE => {
            let row = selected_indices(state.list_window).first().copied()?;
            let current = state.model.items().get(row)?.proposed_name().clone();
            (
                prompt_spec(
                    format!("{} 를", current.to_string_lossy()),
                    "으로",
                    "",
                    current,
                    LegacyText::default(),
                    &[],
                ),
                PromptContinuation::ManualChange { row },
            )
        }
        REPLACE => (
            prompt_spec(
                "이름에 들어있는 문자열을 바꿉니다.",
                "를",
                "으로",
                LegacyText::default(),
                LegacyText::default(),
                &[],
            ),
            PromptContinuation::Replace,
        ),
        PREFIX => (
            prompt_spec(
                "이름의 앞에 지정한 문자열을 붙여줍니다.",
                "붙일 문자열",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &[],
            ),
            PromptContinuation::Prefix,
        ),
        SUFFIX => (
            prompt_spec(
                "이름의 뒤에 지정한 문자열을 붙여줍니다.",
                "붙일 문자열",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &[],
            ),
            PromptContinuation::Suffix,
        ),
        EXT_ADD => (
            prompt_spec(
                "확장자를 뒤에 붙입니다.",
                "붙일 확장자",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &[],
            ),
            PromptContinuation::ExtensionAdd,
        ),
        EXT_REPLACE => (
            prompt_spec(
                "확장자를 바꿔 줍니다.",
                "바꿀 확장자",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &[],
            ),
            PromptContinuation::ExtensionReplace,
        ),
        PAD_DIGITS => (
            prompt_spec(
                "숫자부분의 자리수를 맞춰 0을 붙입니다.",
                "자리수",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &["제일 뒷번호 맞춤", "제일 앞번호 맞춤"],
            ),
            PromptContinuation::PadDigits,
        ),
        SEQUENCE => (
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
            PromptContinuation::Sequence,
        ),
        DELETE_POSITION => (
            prompt_spec(
                "지정위치를 삭제합니다.(첫글자는 1번째)",
                "번째부터",
                "번째까지",
                LegacyText::default(),
                LegacyText::default(),
                &["앞에서부터 삭제", "제일 뒤부터 삭제"],
            ),
            PromptContinuation::DeletePosition,
        ),
        DELETE_DELIMITED => (
            prompt_spec(
                "지정된 문자로 묶인 부분을 삭제합니다.",
                ":시작문자",
                ":끝문자",
                LegacyText::default(),
                LegacyText::default(),
                &[],
            ),
            PromptContinuation::DeleteDelimited,
        ),
        SORT => (
            prompt_spec(
                "정렬 기준 설정",
                "",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &[
                    "파일 이름에 따라 오름차순",
                    "파일 이름에 따라 내림차순",
                    "전체경로에 따라 오름차순",
                    "전체경로에 따라 내림차순",
                    "실제 파일 크기에 따라 오름차순",
                    "실제 파일 크기에 따라 내림차순",
                    "수정한 시각에 따라 오름차순",
                    "수정한 시각에 따라 내림차순",
                    "만든 시각에 따라 오름차순",
                    "만든 시각에 따라 내림차순",
                ],
            ),
            PromptContinuation::Sort,
        ),
        _ => return None,
    };
    state.next_prompt_id = state.next_prompt_id.wrapping_add(1).max(1);
    let session_id = state.next_prompt_id;
    state.active_prompt = Some(session_id);
    Some(PreparedPrompt {
        session_id,
        expected_revision: state.revision(),
        appearance: state.prompt_appearance(),
        spec,
        continuation,
    })
}

pub(super) fn run_prepared_prompt(window: HWND, prompt: PreparedPrompt) {
    let result = prompt_input_or_report(window, prompt.appearance, prompt.spec);
    let Some(mut state_lease) = try_app_state(window) else {
        return;
    };
    let state = state_lease.state_mut();
    let worker_activity = state.worker_activity();
    let worker_active = worker_activity.admission || worker_activity.plan || worker_activity.apply;
    let completion_current = prompt_result_can_apply(
        state.active_prompt,
        prompt.session_id,
        PromptCompletionLocks {
            close_pending: state.close_pending,
            read_only_locked: state.read_only_locked(),
            mutation_locked: state.mutation_locked,
            worker_active,
        },
        state.revision(),
        prompt.expected_revision,
    );
    if state.active_prompt != Some(prompt.session_id) {
        return;
    }
    state.active_prompt = None;
    let Some(result) = result else {
        if state.close_pending {
            try_finish_window_close(window, state);
        }
        return;
    };
    if !completion_current {
        state.set_transient_status(
            "입력창이 열린 동안 목록 또는 작업 상태가 바뀌어 입력을 적용하지 않았습니다.",
        );
        update_controls(state);
        if state.close_pending {
            try_finish_window_close(window, state);
        }
        return;
    }
    let (outcome, selection_restore) =
        finish_prompt_command(window, state, prompt.continuation, result);
    apply_command_outcome(window, state, outcome, selection_restore);
}

fn prompt_result_can_apply(
    active_session: Option<u64>,
    session_id: u64,
    locks: PromptCompletionLocks,
    current_revision: ModelRevision,
    expected_revision: ModelRevision,
) -> bool {
    active_session == Some(session_id)
        && !locks.close_pending
        && !locks.read_only_locked
        && !locks.mutation_locked
        && !locks.worker_active
        && current_revision == expected_revision
}

fn finish_prompt_command(
    window: HWND,
    state: &mut AppState,
    continuation: PromptContinuation,
    result: PromptResult,
) -> (CommandOutcome, Option<SelectionRestore>) {
    let outcome = match continuation {
        PromptContinuation::ManualChange { row } => {
            let changed = state.model.manual_change_changed(row, result.value_one);
            model_outcome(
                state,
                changed,
                UiEffect::ProposalRowsChanged(vec![row].into_boxed_slice()),
            )
        }
        PromptContinuation::Replace => proposal_mutation(state, |model| {
            model.replace_complete_changed(&result.value_one, &result.value_two)
        }),
        PromptContinuation::Prefix => proposal_mutation(state, |model| {
            model.prefix_complete_changed(&result.value_one)
        }),
        PromptContinuation::Suffix => proposal_mutation(state, |model| {
            model.suffix_before_extension_changed(&result.value_one)
        }),
        PromptContinuation::ExtensionAdd => proposal_mutation(state, |model| {
            model.add_extension_changed(&result.value_one)
        }),
        PromptContinuation::ExtensionReplace => proposal_mutation(state, |model| {
            model.replace_extension_changed(&result.value_one)
        }),
        PromptContinuation::PadDigits => finish_pad_digits_command(window, state, &result),
        PromptContinuation::Sequence => finish_sequence_command(window, state, &result),
        PromptContinuation::DeletePosition => {
            finish_delete_position_command(window, state, &result)
        }
        PromptContinuation::DeleteDelimited => {
            finish_delete_delimited_command(window, state, &result)
        }
        PromptContinuation::Sort => return finish_sort_command(state, result.choice),
    };
    (outcome, None)
}

fn finish_pad_digits_command(
    _window: HWND,
    state: &mut AppState,
    result: &PromptResult,
) -> CommandOutcome {
    let width = legacy_atoi(&result.value_one);
    if width <= 0 {
        state.set_transient_status("자리수 입력이 잘못되었습니다.");
        return CommandOutcome::ui(UiEffect::None);
    }
    let changed = {
        let outcome = if result.choice == 0 {
            state.model.pad_last_digit_run_changed(width as usize)
        } else {
            state.model.pad_first_digit_run_changed(width as usize)
        };
        match outcome {
            Ok(changed) => changed,
            Err(_) => {
                state.set_transient_status("자리수 입력이 잘못되었습니다.");
                Box::default()
            }
        }
    };
    proposal_outcome(state, changed)
}

fn finish_sequence_command(
    _window: HWND,
    state: &mut AppState,
    result: &PromptResult,
) -> CommandOutcome {
    let width = legacy_atoi(&result.value_one);
    if width <= 0 {
        state.set_transient_status("자리수 입력이 잘못되었습니다.");
        return CommandOutcome::ui(UiEffect::None);
    }
    let mode = match result.choice {
        0 => LegacySequenceMode::Append,
        1 => LegacySequenceMode::Prepend,
        2 => LegacySequenceMode::AppendRestartPerFolder,
        _ => LegacySequenceMode::PrependRestartPerFolder,
    };
    let changed = state
        .model
        .add_sequence_by_changed(
            width as usize,
            legacy_atoi(&result.value_two),
            mode,
            compare_windows,
        )
        .unwrap_or_default();
    proposal_outcome(state, changed)
}

fn finish_delete_position_command(
    _window: HWND,
    state: &mut AppState,
    result: &PromptResult,
) -> CommandOutcome {
    let start = legacy_atoi(&result.value_one);
    let end = legacy_atoi(&result.value_two);
    if start < 0 || end < 0 {
        state.set_transient_status("음수값이나 잘못된 값이 입력되었습니다.");
        return CommandOutcome::ui(UiEffect::None);
    }
    if result.choice == 0 && end > 0 && start > end {
        state.set_transient_status("시작점이 끝점보다 뒤에 있습니다.");
        return CommandOutcome::ui(UiEffect::None);
    }
    if result.choice == 1 && start != 0 {
        state.set_transient_status("맨 뒤에서부터 삭제할때는 '~까지'만 필요합니다.");
        return CommandOutcome::ui(UiEffect::None);
    }
    let changed = {
        if result.choice == 0 {
            state
                .model
                .delete_front_range_changed(start as usize, end as usize)
                .unwrap_or_default()
        } else {
            state.model.delete_last_changed(end as usize)
        }
    };
    proposal_outcome(state, changed)
}

fn finish_delete_delimited_command(
    _window: HWND,
    state: &mut AppState,
    result: &PromptResult,
) -> CommandOutcome {
    let changed = match state
        .model
        .delete_first_delimited_changed(&result.value_one, &result.value_two)
    {
        Ok(changed) => changed,
        Err(LegacyInputError::EmptyDelimiter) => {
            state.set_transient_status("시작/끝 문자가 정확하게 지정되지 않았습니다.");
            Box::default()
        }
        Err(_) => Box::default(),
    };
    proposal_outcome(state, changed)
}

fn finish_sort_command(
    state: &mut AppState,
    choice: usize,
) -> (CommandOutcome, Option<SelectionRestore>) {
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
    if let Some(mode) = modes.get(choice) {
        let selected = selected_indices(state.list_window);
        let tokens = selection_tokens(&state.model, &selected);
        let focused =
            focused_index(state.list_window).and_then(|index| selection_token(&state.model, index));
        let changed = state.model.sort_by_with_semantics_changed(
            *mode,
            SortSemantics::SafeActualSize,
            compare_windows,
        );
        let outcome = model_outcome(state, changed, UiEffect::AllRowsChanged);
        let moved = rows_for_tokens(&state.model, &tokens);
        let focused = focused.as_ref().and_then(|token| {
            rows_for_tokens(&state.model, slice::from_ref(token))
                .first()
                .copied()
        });
        return (
            outcome,
            Some(SelectionRestore {
                rows: moved.into_boxed_slice(),
                focused,
            }),
        );
    }
    (CommandOutcome::ui(UiEffect::None), None)
}

pub(super) fn clear_selection(list: HWND) {
    let _selection_guard = ProgrammaticListUpdateGuard::begin();
    let mut item = LVITEMW {
        stateMask: LVIS_SELECTED | LVIS_FOCUSED,
        state: 0,
        ..LVITEMW::default()
    };
    // SAFETY: list is live and item remains writable LVITEMW storage through the
    // synchronous all-items LVM_SETITEMSTATE call.
    unsafe {
        SendMessageW(
            list,
            LVM_SETITEMSTATE,
            usize::MAX,
            (&mut item as *mut LVITEMW) as isize,
        );
    }
}
