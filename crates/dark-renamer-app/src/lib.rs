//! Native preview-first workbench for Dark Renamer.

#![forbid(unsafe_code)]

use std::env;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};

use dark_renamer_core::{
    CaseStyle, CaseTarget, Diagnostic, RenamePlan, RenameRule, RowState, SequencePlacement,
};
use dark_renamer_platform::{
    AdmissionRejection, PlatformError, Preview, RecoveryAction, RecoveryInspection, RenameEngine,
    TransactionKind, TransactionSummary,
};
use eframe::egui::{
    self, Align, Button, Color32, ComboBox, Context, DragValue, Grid, Key, Layout, Modal, RichText,
    ScrollArea, TextEdit, Ui,
};

const APP_TITLE: &str = "Dark Renamer";
const PREVIEW_ROW_HEIGHT: f32 = 44.0;

/// Starts the native Dark Renamer workbench.
///
/// # Errors
///
/// Returns an error when a per-user journal cannot be opened or the native
/// window cannot be created.
pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    let engine = RenameEngine::new(journal_root()?)?;
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1_120.0, 760.0])
            .with_min_inner_size([760.0, 560.0]),
        ..Default::default()
    };
    eframe::run_native(
        APP_TITLE,
        options,
        Box::new(move |_creation_context| Ok(Box::new(DarkRenamerApp::new(engine)))),
    )?;
    Ok(())
}

fn journal_root() -> Result<PathBuf, JournalRootError> {
    #[cfg(windows)]
    {
        env::var_os("LOCALAPPDATA")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .map(|path| path.join("DarkRenamer").join("journals"))
            .ok_or(JournalRootError::MissingPerUserDataDirectory)
    }
    #[cfg(not(windows))]
    {
        if let Some(path) = env::var_os("XDG_DATA_HOME").filter(|value| !value.is_empty()) {
            return Ok(PathBuf::from(path).join("dark-renamer").join("journals"));
        }
        env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .map(|path| {
                path.join(".local")
                    .join("share")
                    .join("dark-renamer")
                    .join("journals")
            })
            .ok_or(JournalRootError::MissingPerUserDataDirectory)
    }
}

#[derive(Debug)]
enum JournalRootError {
    MissingPerUserDataDirectory,
}

impl std::fmt::Display for JournalRootError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingPerUserDataDirectory => formatter.write_str(
                "no per-user data directory is available; set LOCALAPPDATA, XDG_DATA_HOME, or HOME",
            ),
        }
    }
}

impl std::error::Error for JournalRootError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RuleKind {
    ReplaceText,
    AddPrefix,
    AddSuffix,
    ClearStem,
    RemoveCharacters,
    KeepDigits,
    PadDigits,
    AddSequence,
    RemoveExtension,
    AddExtension,
    ReplaceExtension,
    ConvertCase,
}

impl RuleKind {
    const ALL: [Self; 12] = [
        Self::ReplaceText,
        Self::AddPrefix,
        Self::AddSuffix,
        Self::ClearStem,
        Self::RemoveCharacters,
        Self::KeepDigits,
        Self::PadDigits,
        Self::AddSequence,
        Self::RemoveExtension,
        Self::AddExtension,
        Self::ReplaceExtension,
        Self::ConvertCase,
    ];

    const fn label(self) -> &'static str {
        match self {
            Self::ReplaceText => "Replace text",
            Self::AddPrefix => "Add prefix",
            Self::AddSuffix => "Add suffix",
            Self::ClearStem => "Clear name stem",
            Self::RemoveCharacters => "Remove characters",
            Self::KeepDigits => "Keep digits only",
            Self::PadDigits => "Pad digit runs",
            Self::AddSequence => "Add sequence",
            Self::RemoveExtension => "Remove extension",
            Self::AddExtension => "Add extension",
            Self::ReplaceExtension => "Replace extension",
            Self::ConvertCase => "Convert case",
        }
    }

    fn default_rule(self) -> RenameRule {
        match self {
            Self::ReplaceText => RenameRule::LiteralReplace {
                from: String::new(),
                to: String::new(),
            },
            Self::AddPrefix => RenameRule::Prefix(String::new()),
            Self::AddSuffix => RenameRule::Suffix(String::new()),
            Self::ClearStem => RenameRule::ClearStem,
            Self::RemoveCharacters => RenameRule::RemoveCharacterRange { start: 0, count: 1 },
            Self::KeepDigits => RenameRule::KeepDigits,
            Self::PadDigits => RenameRule::PadDigitRuns { width: 2 },
            Self::AddSequence => RenameRule::Sequence {
                start: 1,
                step: 1,
                width: 1,
                separator: "_".to_owned(),
                placement: SequencePlacement::Prefix,
            },
            Self::RemoveExtension => RenameRule::RemoveExtension,
            Self::AddExtension => RenameRule::AddExtension(String::new()),
            Self::ReplaceExtension => RenameRule::ReplaceExtension(String::new()),
            Self::ConvertCase => RenameRule::ConvertCase {
                style: CaseStyle::Lower,
                target: CaseTarget::Stem,
            },
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RuleAction {
    MoveEarlier(usize),
    MoveLater(usize),
    Remove(usize),
}

#[derive(Debug, Default)]
struct RuleList {
    items: Vec<RenameRule>,
}

impl RuleList {
    fn apply(&mut self, action: RuleAction) -> bool {
        match action {
            RuleAction::MoveEarlier(index) if index > 0 && index < self.items.len() => {
                self.items.swap(index, index - 1);
                true
            }
            RuleAction::MoveLater(index) if index + 1 < self.items.len() => {
                self.items.swap(index, index + 1);
                true
            }
            RuleAction::Remove(index) if index < self.items.len() => {
                self.items.remove(index);
                true
            }
            _ => false,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct PreviewReadiness {
    source_count: usize,
    changed_count: usize,
    blocked_count: usize,
    can_apply: bool,
}

impl PreviewReadiness {
    fn from_plan(plan: &RenamePlan) -> Self {
        Self {
            source_count: plan.rows().len(),
            changed_count: plan.changed_count(),
            blocked_count: plan.rows().iter().filter(|row| row.is_blocked()).count(),
            can_apply: plan.can_apply(),
        }
    }
}

#[derive(Debug, Default)]
struct ExactCountConfirmation {
    expected: usize,
    input: String,
    open: bool,
}

impl ExactCountConfirmation {
    fn open(&mut self, expected: usize) {
        self.expected = expected;
        self.input.clear();
        self.open = true;
    }

    fn close(&mut self) {
        self.open = false;
        self.input.clear();
    }

    fn entered_count(&self) -> Option<usize> {
        self.input.trim().parse().ok()
    }

    fn can_confirm(&self) -> bool {
        self.open && self.entered_count() == Some(self.expected)
    }

    fn dispatch<T, E>(
        &mut self,
        operation: impl FnOnce(usize) -> Result<T, E>,
    ) -> Option<Result<T, E>> {
        let count = self.can_confirm().then(|| self.entered_count()).flatten()?;
        self.close();
        Some(operation(count))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FeedbackKind {
    Information,
    Error,
}

#[derive(Debug)]
struct Feedback {
    kind: FeedbackKind,
    text: String,
}

impl Feedback {
    fn information(text: impl Into<String>) -> Self {
        Self {
            kind: FeedbackKind::Information,
            text: text.into(),
        }
    }

    fn error(text: impl Into<String>) -> Self {
        Self {
            kind: FeedbackKind::Error,
            text: text.into(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct MutationVisibility {
    recovery_banner: bool,
    apply_enabled: bool,
    undo_enabled: bool,
}

impl MutationVisibility {
    fn new(
        readiness: PreviewReadiness,
        recovery_required: bool,
        latest_kind: Option<TransactionKind>,
        mutation_available: bool,
    ) -> Self {
        Self {
            recovery_banner: recovery_required,
            apply_enabled: mutation_available && readiness.can_apply && !recovery_required,
            undo_enabled: mutation_available
                && !recovery_required
                && latest_kind.is_some_and(|kind| matches!(kind, TransactionKind::Apply)),
        }
    }
}

struct DarkRenamerApp {
    engine: RenameEngine,
    rules: RuleList,
    new_rule_kind: RuleKind,
    preview: Option<Preview>,
    has_admission: bool,
    confirmation: ExactCountConfirmation,
    latest_transaction: Option<TransactionSummary>,
    recovery: Option<RecoveryInspection>,
    feedback: Option<Feedback>,
}

impl DarkRenamerApp {
    fn new(mut engine: RenameEngine) -> Self {
        let recovery = if engine.recovery_required() {
            engine.inspect_recovery().ok()
        } else {
            None
        };
        let latest_transaction = engine.latest_transaction().ok();
        Self {
            engine,
            rules: RuleList::default(),
            new_rule_kind: RuleKind::ReplaceText,
            preview: None,
            has_admission: false,
            confirmation: ExactCountConfirmation::default(),
            latest_transaction,
            recovery,
            feedback: None,
        }
    }

    fn readiness(&self) -> PreviewReadiness {
        self.preview
            .as_ref()
            .map_or_else(PreviewReadiness::default, |preview| {
                PreviewReadiness::from_plan(preview.plan())
            })
    }

    fn refresh_preview(&mut self) {
        if !self.has_admission {
            return;
        }
        match self.engine.preview(&self.rules.items) {
            Ok(preview) => {
                self.preview = Some(preview);
                self.feedback = None;
            }
            Err(error) => {
                self.preview = None;
                self.feedback = Some(Feedback::error(platform_error_message(&error)));
            }
        }
    }

    fn admit_paths(&mut self, paths: Vec<PathBuf>) {
        if paths.is_empty() {
            self.feedback = Some(Feedback::information("No regular files were selected."));
            return;
        }
        match self.engine.admit(paths) {
            Ok(_source_ids) => {
                self.has_admission = true;
                match self.engine.preview(&self.rules.items) {
                    Ok(preview) => {
                        let count = preview.source_ids().len();
                        self.preview = Some(preview);
                        self.confirmation.close();
                        self.feedback = Some(Feedback::information(format!(
                            "Admitted {count} file(s). Review the preview before applying."
                        )));
                    }
                    Err(error) => {
                        self.preview = None;
                        self.feedback = Some(Feedback::error(platform_error_message(&error)));
                    }
                }
            }
            Err(error) => {
                self.feedback = Some(Feedback::error(platform_error_message(&error)));
            }
        }
    }

    fn add_files(&mut self) {
        if let Some(paths) = rfd::FileDialog::new().pick_files() {
            self.admit_paths(paths);
        }
    }

    fn add_folder_contents(&mut self) {
        let Some(folder) = rfd::FileDialog::new().pick_folder() else {
            return;
        };
        match regular_files_in(&folder) {
            Ok(paths) => self.admit_paths(paths),
            Err(_error) => {
                self.feedback = Some(Feedback::error(
                    "The selected folder could not be read. Check its permissions and try again.",
                ));
            }
        }
    }

    fn handle_shortcuts_and_drop(&mut self, context: &Context) {
        let (add_files, add_folder, close_modal, dropped) = context.input(|input| {
            let ctrl_o = input.modifiers.ctrl && input.key_pressed(Key::O);
            (
                ctrl_o && !input.modifiers.shift,
                ctrl_o && input.modifiers.shift,
                input.key_pressed(Key::Escape),
                input
                    .raw
                    .dropped_files
                    .iter()
                    .map(|file| file.path())
                    .filter(|path| !path.as_os_str().is_empty())
                    .map(Path::to_path_buf)
                    .collect::<Vec<_>>(),
            )
        });
        if close_modal {
            self.confirmation.close();
        }
        if add_folder {
            self.add_folder_contents();
        } else if add_files {
            self.add_files();
        }
        if !dropped.is_empty() {
            self.admit_paths(dropped);
        }
    }

    fn show_source_bar(&mut self, ui: &mut Ui) {
        ui.horizontal_wrapped(|ui| {
            ui.heading("Sources");
            if ui.button("Add files…").on_hover_text("Ctrl+O").clicked() {
                self.add_files();
            }
            if ui
                .button("Add folder contents…")
                .on_hover_text("Ctrl+Shift+O; regular files in the selected folder only")
                .clicked()
            {
                self.add_folder_contents();
            }
            let count = self.readiness().source_count;
            ui.label(format!("{count} file(s) in the current preview"));
        });
        ui.label("You can also drop files here. Adding sources replaces the current batch.");
    }

    fn show_recovery(&mut self, ui: &mut Ui) {
        if !self.engine.recovery_required() {
            return;
        }
        egui::Frame::group(ui.style())
            .fill(ui.visuals().warn_fg_color.gamma_multiply(0.10))
            .show(ui, |ui| {
                ui.label(RichText::new("Recovery required").strong());
                ui.label(
                    "An incomplete transaction must be resolved before Apply or Undo. Review the recorded progress and choose its final outcome.",
                );
                if self.recovery.is_none() && ui.button("Inspect recovery state").clicked() {
                    match self.engine.inspect_recovery() {
                        Ok(inspection) => self.recovery = Some(inspection),
                        Err(error) => {
                            self.feedback = Some(Feedback::error(platform_error_message(&error)));
                        }
                    }
                }
                if let Some(inspection) = self.recovery {
                    let mutation_supported = self.engine.mutation_supported();
                    ui.label(format!(
                        "{} transaction: {} file(s), {} move step(s) already recorded.",
                        transaction_kind_label(inspection.kind()),
                        inspection.changed_count(),
                        inspection.completed_move_count()
                    ));
                    ui.horizontal_wrapped(|ui| {
                        if ui
                            .add_enabled(
                                mutation_supported,
                                Button::new("Roll back to original names"),
                            )
                            .on_disabled_hover_text(
                                "Recovery execution is unavailable on this platform.",
                            )
                            .clicked()
                        {
                            self.recover(inspection, RecoveryAction::RollBack);
                        }
                        if ui
                            .add_enabled(
                                mutation_supported,
                                Button::new("Roll forward to previewed names"),
                            )
                            .on_disabled_hover_text(
                                "Recovery execution is unavailable on this platform.",
                            )
                            .clicked()
                        {
                            self.recover(inspection, RecoveryAction::RollForward);
                        }
                    });
                }
            });
    }

    fn recover(&mut self, inspection: RecoveryInspection, action: RecoveryAction) {
        match self.engine.recover(inspection.token(), action) {
            Ok(_transaction_id) => {
                self.recovery = None;
                self.preview = None;
                self.has_admission = false;
                self.latest_transaction = self.engine.latest_transaction().ok();
                self.feedback = Some(Feedback::information(match action {
                    RecoveryAction::RollBack => {
                        "Recovery completed: files were returned to their original names."
                    }
                    RecoveryAction::RollForward => {
                        "Recovery completed: files were moved to the previewed names."
                    }
                    _ => "Recovery completed.",
                }));
            }
            Err(error) => {
                self.feedback = Some(Feedback::error(mutation_error_message("Recovery", &error)));
                if matches!(error, PlatformError::StaleRecovery) {
                    self.recovery = self.engine.inspect_recovery().ok();
                }
            }
        }
    }

    fn show_rules(&mut self, ui: &mut Ui) {
        ui.heading("Rules");
        ui.label("Rules run from top to bottom. Every edit refreshes the preview.");
        let mut changed = false;
        let mut pending_action = None;
        let item_count = self.rules.items.len();
        for index in 0..item_count {
            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(RichText::new(format!("Rule {}", index + 1)).strong());
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if ui.button("Remove").clicked() {
                            pending_action = Some(RuleAction::Remove(index));
                        }
                        if ui
                            .add_enabled(index + 1 < item_count, Button::new("Move later"))
                            .clicked()
                        {
                            pending_action = Some(RuleAction::MoveLater(index));
                        }
                        if ui
                            .add_enabled(index > 0, Button::new("Move earlier"))
                            .clicked()
                        {
                            pending_action = Some(RuleAction::MoveEarlier(index));
                        }
                    });
                });
                if let Some(rule) = self.rules.items.get_mut(index) {
                    changed |= show_rule_editor(ui, index, rule);
                }
            });
            ui.add_space(4.0);
        }
        if self.rules.items.is_empty() {
            ui.label("No rules yet. Add a rule to produce renamed filenames.");
        }
        ui.horizontal_wrapped(|ui| {
            ComboBox::from_label("New rule")
                .selected_text(self.new_rule_kind.label())
                .show_ui(ui, |ui| {
                    for kind in RuleKind::ALL {
                        ui.selectable_value(&mut self.new_rule_kind, kind, kind.label());
                    }
                });
            if ui.button("Add rule").clicked() {
                self.rules.items.push(self.new_rule_kind.default_rule());
                changed = true;
            }
        });
        if let Some(action) = pending_action {
            changed |= self.rules.apply(action);
        }
        if changed {
            self.refresh_preview();
        }
    }

    fn show_preview(&mut self, ui: &mut Ui) {
        ui.heading("Preview");
        let readiness = self.readiness();
        ui.horizontal_wrapped(|ui| {
            ui.label(format!("Changed: {}", readiness.changed_count));
            ui.separator();
            ui.label(format!("Blocked: {}", readiness.blocked_count));
        });
        let Some(preview) = self.preview.as_ref() else {
            ui.add_space(16.0);
            ui.label("Add files to see an immediate before-and-after preview.");
            return;
        };

        let available = ui.available_width();
        let before_width = (available * 0.25).max(120.0);
        let after_width = (available * 0.25).max(120.0);
        let state_width = 84.0;
        ui.horizontal(|ui| {
            ui.add_sized(
                [before_width, 22.0],
                egui::Label::new(RichText::new("Before").strong()),
            );
            ui.add_sized(
                [after_width, 22.0],
                egui::Label::new(RichText::new("After").strong()),
            );
            ui.add_sized(
                [state_width, 22.0],
                egui::Label::new(RichText::new("State").strong()),
            );
            ui.label(RichText::new("Diagnostics").strong());
        });
        ui.separator();
        let rows = preview.plan().rows();
        ScrollArea::vertical()
            .auto_shrink([false, false])
            .show_rows(ui, PREVIEW_ROW_HEIGHT, rows.len(), |ui, range| {
                for row in &rows[range] {
                    ui.horizontal(|ui| {
                        ui.add_sized(
                            [before_width, PREVIEW_ROW_HEIGHT],
                            egui::Label::new(display_name(row.original_name())).truncate(),
                        );
                        ui.add_sized(
                            [after_width, PREVIEW_ROW_HEIGHT],
                            egui::Label::new(display_name(row.proposed_name())).truncate(),
                        );
                        let (state, color) = row_state_presentation(row.state(), ui);
                        ui.add_sized(
                            [state_width, PREVIEW_ROW_HEIGHT],
                            egui::Label::new(RichText::new(state).color(color)),
                        );
                        ui.label(diagnostic_summary(row.diagnostics()));
                    });
                }
            });
    }

    fn show_actions(&mut self, ui: &mut Ui) {
        let readiness = self.readiness();
        let visibility = MutationVisibility::new(
            readiness,
            self.engine.recovery_required(),
            self.latest_transaction.map(TransactionSummary::kind),
            self.engine.mutation_supported(),
        );
        ui.separator();
        ui.horizontal_wrapped(|ui| {
            if ui
                .add_enabled(visibility.apply_enabled, Button::new("Apply…"))
                .on_disabled_hover_text(
                    "Apply requires at least one changed file, no blocked rows, and no recovery state.",
                )
                .clicked()
            {
                self.confirmation.open(readiness.changed_count);
            }
            if let Some(latest) = self.latest_transaction {
                ui.label(format!(
                    "Latest: {} of {} file(s)",
                    transaction_kind_label(latest.kind()),
                    latest.changed_count()
                ));
                if ui
                    .add_enabled(visibility.undo_enabled, Button::new("Undo latest transaction"))
                    .clicked()
                {
                    self.undo_latest(latest);
                }
            } else {
                ui.label("Latest transaction: none");
            }
        });
        if !self.engine.mutation_supported() {
            ui.small("This platform is preview-only. Apply, Undo, and Recovery are unavailable.");
        }
    }

    fn undo_latest(&mut self, latest: TransactionSummary) {
        match self.engine.undo_latest(latest.id(), latest.changed_count()) {
            Ok(_transaction_id) => {
                self.preview = None;
                self.has_admission = false;
                self.latest_transaction = self.engine.latest_transaction().ok();
                self.feedback = Some(Feedback::information(format!(
                    "Undo completed for {} file(s).",
                    latest.changed_count()
                )));
            }
            Err(error) => {
                self.latest_transaction = self.engine.latest_transaction().ok();
                self.feedback = Some(Feedback::error(mutation_error_message("Undo", &error)));
            }
        }
    }

    fn show_feedback(&self, ui: &mut Ui) {
        if let Some(feedback) = &self.feedback {
            let (prefix, color) = match feedback.kind {
                FeedbackKind::Information => ("Status:", ui.visuals().text_color()),
                FeedbackKind::Error => ("Error:", ui.visuals().error_fg_color),
            };
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(prefix).strong().color(color));
                ui.label(&feedback.text);
            });
        }
    }

    fn show_confirmation(&mut self, context: &Context) {
        if !self.confirmation.open {
            return;
        }
        Modal::new(egui::Id::new("apply-exact-count-confirmation")).show(context, |ui| {
            ui.heading("Confirm rename");
            ui.label(format!(
                "Type {} to confirm the exact number of files that will be renamed.",
                self.confirmation.expected
            ));
            show_exact_count_input(ui, &mut self.confirmation.input);
            ui.horizontal(|ui| {
                if ui.button("Cancel").clicked() {
                    self.confirmation.close();
                }
                let confirm = ui.add_enabled(
                    self.confirmation.can_confirm(),
                    Button::new("Confirm and apply"),
                );
                if confirm.clicked() {
                    let plan_id = self.preview.as_ref().map(Preview::id);
                    let result = self.confirmation.dispatch(|count| {
                        let id = plan_id.ok_or(PlatformError::StalePlan)?;
                        self.engine.apply_confirmed(id, count)
                    });
                    if let Some(result) = result {
                        match result {
                            Ok(_transaction_id) => {
                                self.preview = None;
                                self.has_admission = false;
                                self.latest_transaction = self.engine.latest_transaction().ok();
                                self.feedback = Some(Feedback::information(format!(
                                    "Applied {} file rename(s).",
                                    self.confirmation.expected
                                )));
                            }
                            Err(error) => {
                                self.feedback =
                                    Some(Feedback::error(mutation_error_message("Apply", &error)));
                            }
                        }
                    }
                }
            });
        });
    }
}

impl eframe::App for DarkRenamerApp {
    fn ui(&mut self, ui: &mut Ui, _frame: &mut eframe::Frame) {
        let context = ui.ctx().clone();
        self.handle_shortcuts_and_drop(&context);
        egui::Panel::top("source-bar").show(ui, |ui| {
            ui.add_space(6.0);
            self.show_source_bar(ui);
            self.show_recovery(ui);
            self.show_feedback(ui);
            ui.add_space(6.0);
        });
        egui::Panel::bottom("transaction-actions").show(ui, |ui| {
            self.show_actions(ui);
        });
        egui::Panel::left("ordered-rules")
            .resizable(true)
            .default_size(360.0)
            .size_range(280.0..=520.0)
            .show(ui, |ui| {
                ScrollArea::vertical().show(ui, |ui| self.show_rules(ui));
            });
        egui::CentralPanel::default().show(ui, |ui| {
            self.show_preview(ui);
        });
        self.show_confirmation(&context);
    }
}

fn regular_files_in(folder: &Path) -> Result<Vec<PathBuf>, std::io::Error> {
    let mut paths = Vec::new();
    for entry in fs::read_dir(folder)? {
        let entry = entry?;
        if entry.file_type()?.is_file() {
            paths.push(entry.path());
        }
    }
    paths.sort();
    Ok(paths)
}

fn show_rule_editor(ui: &mut Ui, index: usize, rule: &mut RenameRule) -> bool {
    let mut changed = false;
    match rule {
        RenameRule::LiteralReplace { from, to } => {
            ui.label("Replace text");
            Grid::new(("replace-grid", index)).show(ui, |ui| {
                let label = ui.label("Find");
                changed |= ui
                    .text_edit_singleline(from)
                    .labelled_by(label.id)
                    .changed();
                ui.end_row();
                let label = ui.label("Replace with");
                changed |= ui.text_edit_singleline(to).labelled_by(label.id).changed();
                ui.end_row();
            });
        }
        RenameRule::Prefix(value) => changed |= labeled_text_edit(ui, "Prefix", value),
        RenameRule::Suffix(value) => changed |= labeled_text_edit(ui, "Suffix", value),
        RenameRule::ClearStem => {
            ui.label("Remove the complete name stem and keep the extension.");
        }
        RenameRule::RemoveCharacterRange { start, count } => {
            ui.label("Remove characters by zero-based position");
            ui.horizontal(|ui| {
                let label = ui.label("Start");
                changed |= ui
                    .add(DragValue::new(start).range(0..=usize::MAX))
                    .labelled_by(label.id)
                    .changed();
                let label = ui.label("Count");
                changed |= ui
                    .add(DragValue::new(count).range(0..=usize::MAX))
                    .labelled_by(label.id)
                    .changed();
            });
        }
        RenameRule::KeepDigits => {
            ui.label("Keep only ASCII digits in the name stem.");
        }
        RenameRule::PadDigitRuns { width } => {
            let label = ui.label("Minimum digit-run width");
            changed |= ui
                .add(DragValue::new(width).range(0..=255))
                .labelled_by(label.id)
                .changed();
        }
        RenameRule::Sequence {
            start,
            step,
            width,
            separator,
            placement,
        } => {
            ui.label("Sequence");
            Grid::new(("sequence-grid", index)).show(ui, |ui| {
                let label = ui.label("Start");
                changed |= ui
                    .add(DragValue::new(start))
                    .labelled_by(label.id)
                    .changed();
                ui.end_row();
                let label = ui.label("Step");
                changed |= ui.add(DragValue::new(step)).labelled_by(label.id).changed();
                ui.end_row();
                let label = ui.label("Minimum width");
                changed |= ui
                    .add(DragValue::new(width).range(0..=255))
                    .labelled_by(label.id)
                    .changed();
                ui.end_row();
                let label = ui.label("Separator");
                changed |= ui
                    .text_edit_singleline(separator)
                    .labelled_by(label.id)
                    .changed();
                ui.end_row();
                let label = ui.label("Placement");
                let response = ComboBox::from_id_salt(("sequence-placement", index))
                    .selected_text(sequence_placement_label(*placement))
                    .show_ui(ui, |ui| {
                        changed |= ui
                            .selectable_value(placement, SequencePlacement::Prefix, "Before name")
                            .changed();
                        changed |= ui
                            .selectable_value(placement, SequencePlacement::Suffix, "After name")
                            .changed();
                    })
                    .response
                    .labelled_by(label.id);
                let _ = response;
                ui.end_row();
            });
        }
        RenameRule::RemoveExtension => {
            ui.label("Remove the final extension, if present.");
        }
        RenameRule::AddExtension(value) => {
            changed |= labeled_text_edit(ui, "Extension to append", value);
        }
        RenameRule::ReplaceExtension(value) => {
            changed |= labeled_text_edit(ui, "New extension", value);
        }
        RenameRule::ConvertCase { style, target } => {
            ui.label("Convert case");
            Grid::new(("case-grid", index)).show(ui, |ui| {
                let label = ui.label("Style");
                let response = ComboBox::from_id_salt(("case-style", index))
                    .selected_text(case_style_label(*style))
                    .show_ui(ui, |ui| {
                        for value in [CaseStyle::Lower, CaseStyle::Upper, CaseStyle::Title] {
                            changed |= ui
                                .selectable_value(style, value, case_style_label(value))
                                .changed();
                        }
                    })
                    .response
                    .labelled_by(label.id);
                let _ = response;
                ui.end_row();
                let label = ui.label("Target");
                let response = ComboBox::from_id_salt(("case-target", index))
                    .selected_text(case_target_label(*target))
                    .show_ui(ui, |ui| {
                        for value in [
                            CaseTarget::Stem,
                            CaseTarget::Extension,
                            CaseTarget::StemAndExtension,
                        ] {
                            changed |= ui
                                .selectable_value(target, value, case_target_label(value))
                                .changed();
                        }
                    })
                    .response
                    .labelled_by(label.id);
                let _ = response;
                ui.end_row();
            });
        }
    }
    changed
}

fn labeled_text_edit(ui: &mut Ui, label: &str, value: &mut String) -> bool {
    let mut changed = false;
    ui.horizontal(|ui| {
        let label = ui.label(label);
        changed = ui
            .text_edit_singleline(value)
            .labelled_by(label.id)
            .changed();
    });
    changed
}

fn show_exact_count_input(ui: &mut Ui, input: &mut String) {
    let input_label = ui.label("Exact changed count");
    ui.add(
        TextEdit::singleline(input)
            .hint_text("Enter the count shown above")
            .desired_width(180.0),
    )
    .labelled_by(input_label.id);
}

const fn sequence_placement_label(value: SequencePlacement) -> &'static str {
    match value {
        SequencePlacement::Prefix => "Before name",
        SequencePlacement::Suffix => "After name",
    }
}

const fn case_style_label(value: CaseStyle) -> &'static str {
    match value {
        CaseStyle::Lower => "Lowercase",
        CaseStyle::Upper => "Uppercase",
        CaseStyle::Title => "Title case",
    }
}

const fn case_target_label(value: CaseTarget) -> &'static str {
    match value {
        CaseTarget::Stem => "Name stem",
        CaseTarget::Extension => "Extension",
        CaseTarget::StemAndExtension => "Name stem and extension",
    }
}

fn row_state_presentation(state: RowState, ui: &Ui) -> (&'static str, Color32) {
    match state {
        RowState::Unchanged => ("Unchanged", ui.visuals().weak_text_color()),
        RowState::Ready => ("Ready", Color32::from_rgb(32, 128, 72)),
        RowState::Blocked => ("Blocked", ui.visuals().error_fg_color),
    }
}

fn display_name(value: &OsStr) -> String {
    value.to_string_lossy().into_owned()
}

fn diagnostic_summary(diagnostics: &[Diagnostic]) -> String {
    if diagnostics.is_empty() {
        return "None".to_owned();
    }
    diagnostics
        .iter()
        .map(diagnostic_message)
        .collect::<Vec<_>>()
        .join(" ")
}

fn diagnostic_message(diagnostic: &Diagnostic) -> String {
    match diagnostic {
        Diagnostic::MissingFileName => "The source has no filename.".to_owned(),
        Diagnostic::NonUnicodeFileName => "The filename is not valid Unicode.".to_owned(),
        Diagnostic::EmptyLiteralSearch { rule_index } => {
            format!("Rule {} needs text to find.", rule_index + 1)
        }
        Diagnostic::EmptyExtension { rule_index } => {
            format!("Rule {} needs an extension.", rule_index + 1)
        }
        Diagnostic::SequenceOverflow { rule_index } => {
            format!(
                "Rule {} makes the sequence exceed its limit.",
                rule_index + 1
            )
        }
        Diagnostic::GeneratedWidthTooLarge {
            rule_index,
            width,
            maximum,
        } => format!(
            "Rule {} requests width {width}; the maximum is {maximum}.",
            rule_index + 1
        ),
        Diagnostic::EmptyName => "The proposed filename is empty.".to_owned(),
        Diagnostic::InvalidCharacter { character } => {
            format!("The proposed filename contains the invalid character {character:?}.")
        }
        Diagnostic::TrailingDotOrSpace => {
            "The proposed filename ends with a period or space.".to_owned()
        }
        Diagnostic::ReservedDeviceName { name } => {
            format!("{} is a reserved Windows device name.", display_name(name))
        }
        Diagnostic::DuplicateTarget { rows, .. } => {
            let participants = rows
                .iter()
                .map(|row| (row + 1).to_string())
                .collect::<Vec<_>>()
                .join(", ");
            format!("Rows {participants} produce the same filename.")
        }
        Diagnostic::OccupiedTarget { .. } => {
            "The proposed filename is already occupied in this folder.".to_owned()
        }
    }
}

fn transaction_kind_label(kind: TransactionKind) -> &'static str {
    match kind {
        TransactionKind::Apply => "Applied rename",
        TransactionKind::Undo => "Undo",
        _ => "Completed operation",
    }
}

fn mutation_error_message(action: &str, error: &PlatformError) -> String {
    match error {
        PlatformError::Unsupported { operation } => format!(
            "{action} is unavailable because this build does not support {operation}. No files were changed."
        ),
        PlatformError::ExecutionFailed {
            rolled_back: true, ..
        } => format!("{action} failed. Completed moves were rolled back."),
        PlatformError::ExecutionFailed {
            rolled_back: false, ..
        }
        | PlatformError::RecoveryRequired => format!(
            "{action} did not complete. Recovery is required before another filesystem change."
        ),
        _ => format!(
            "{action} was not completed: {} No successful change was recorded.",
            platform_error_message(error)
        ),
    }
}

fn platform_error_message(error: &PlatformError) -> String {
    match error {
        PlatformError::Unsupported { operation } => {
            format!("This operation is unavailable: {operation}.")
        }
        PlatformError::AdmissionRejected { path, reason } => format!(
            "{} was not admitted: {} Select a regular, non-link file and try again.",
            path.file_name().map_or_else(
                || "The selected source".to_owned(),
                display_name
            ),
            admission_rejection_message(*reason)
        ),
        PlatformError::BoundExceeded { field, maximum } => {
            format!("{field} exceeds the supported maximum of {maximum}. Reduce the batch or value.")
        }
        PlatformError::NoSources => "No files are admitted. Add files and try again.".to_owned(),
        PlatformError::StalePlan => {
            "The preview is stale. Refresh the sources and review it again.".to_owned()
        }
        PlatformError::StaleTransaction => {
            "The latest transaction changed. Review the current transaction before undoing.".to_owned()
        }
        PlatformError::PlanNotApplicable => {
            "The preview has no applicable changes. Resolve blocked rows first.".to_owned()
        }
        PlatformError::ConfirmationMismatch { expected, actual } => format!(
            "The confirmation count was {actual}, but the current plan requires {expected}. Review and confirm again."
        ),
        PlatformError::StaleSource { .. } => {
            "A source file changed after admission. Add the files again and review a fresh preview.".to_owned()
        }
        PlatformError::StaleParent { .. } => {
            "A source folder changed after admission. Add the files again and review a fresh preview.".to_owned()
        }
        PlatformError::DestinationChanged { path } => format!(
            "The destination {} changed after preview. Refresh the batch before applying.",
            path.file_name().map_or_else(
                || "filename".to_owned(),
                display_name
            )
        ),
        PlatformError::RecoveryRequired => {
            "An incomplete transaction requires recovery. Inspect it and choose an outcome.".to_owned()
        }
        PlatformError::StaleRecovery => {
            "The recovery state changed. Inspect it again before choosing an outcome.".to_owned()
        }
        PlatformError::NoCompletedTransaction => {
            "There is no completed transaction to undo.".to_owned()
        }
        PlatformError::LatestTransactionNotUndoable => {
            "The latest transaction is already an undo and cannot be undone again.".to_owned()
        }
        PlatformError::ExecutionFailed {
            rolled_back,
            operation,
        } => format!("{operation} failed. Completed moves rolled back: {rolled_back}."),
        PlatformError::CorruptJournal { .. } => {
            "The recovery journal is corrupt and cannot be resolved automatically.".to_owned()
        }
        PlatformError::Io { operation, source } => {
            format!("Could not {operation}: {source}. Check filesystem access and try again.")
        }
        _ => "The operation could not be completed. Review the current state and try again.".to_owned(),
    }
}

const fn admission_rejection_message(reason: AdmissionRejection) -> &'static str {
    match reason {
        AdmissionRejection::SymbolicLink => "symbolic links are not accepted.",
        AdmissionRejection::NotRegularFile => "it is not a regular file.",
        AdmissionRejection::MissingParent => "it has no parent folder.",
        AdmissionRejection::InvalidParent => "its parent is not a real directory.",
        AdmissionRejection::NonUnicodePath => "its path is not valid Unicode.",
        AdmissionRejection::DuplicateIdentity => "the same file was selected more than once.",
        AdmissionRejection::RelativePath => "its path is not absolute.",
        _ => "it does not meet source admission requirements.",
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    use dark_renamer_core::{PlanningRequest, plan};
    use egui_kittest::Harness;
    use kittest::{NodeT as _, Queryable as _};

    use super::*;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new() -> Result<Self, std::io::Error> {
            let id = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root =
                env::temp_dir().join(format!("dark-renamer-app-{}-{id}", std::process::id()));
            fs::create_dir_all(&root)?;
            Ok(Self { root })
        }

        fn source(&self) -> PathBuf {
            self.root.join("report.txt")
        }

        fn journals(&self) -> PathBuf {
            self.root.join("journals")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _result = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn empty_state_keeps_apply_disabled() {
        let readiness = PreviewReadiness::default();
        let visibility = MutationVisibility::new(readiness, false, None, false);

        assert_eq!(readiness.source_count, 0);
        assert!(!visibility.apply_enabled);
        assert!(!visibility.undo_enabled);
        assert!(!visibility.recovery_banner);
    }

    #[test]
    fn rule_ordering_preserves_rule_values_and_translation_labels() {
        let mut rules = RuleList {
            items: vec![
                RenameRule::Prefix("first-".to_owned()),
                RenameRule::Suffix("-second".to_owned()),
                RenameRule::RemoveExtension,
            ],
        };

        assert!(rules.apply(RuleAction::MoveLater(0)));
        assert_eq!(
            rules.items,
            vec![
                RenameRule::Suffix("-second".to_owned()),
                RenameRule::Prefix("first-".to_owned()),
                RenameRule::RemoveExtension,
            ]
        );
        assert!(rules.apply(RuleAction::MoveEarlier(2)));
        assert!(rules.apply(RuleAction::Remove(0)));
        assert_eq!(rules.items[0], RenameRule::RemoveExtension);
        assert_eq!(case_style_label(CaseStyle::Title), "Title case");
        assert_eq!(
            case_target_label(CaseTarget::StemAndExtension),
            "Name stem and extension"
        );
        assert_eq!(
            sequence_placement_label(SequencePlacement::Suffix),
            "After name"
        );
    }

    #[test]
    fn blocked_and_ready_plans_produce_distinct_readiness() {
        let ready = plan(
            &PlanningRequest::new([PathBuf::from("report.txt")])
                .with_rules([RenameRule::Prefix("final-".to_owned())]),
        );
        let blocked = plan(
            &PlanningRequest::new([PathBuf::from("report.txt")]).with_rules([
                RenameRule::LiteralReplace {
                    from: String::new(),
                    to: "x".to_owned(),
                },
            ]),
        );

        assert_eq!(
            PreviewReadiness::from_plan(&ready),
            PreviewReadiness {
                source_count: 1,
                changed_count: 1,
                blocked_count: 0,
                can_apply: true,
            }
        );
        assert_eq!(PreviewReadiness::from_plan(&blocked).blocked_count, 1);
        assert!(!PreviewReadiness::from_plan(&blocked).can_apply);
    }

    #[test]
    fn exact_count_confirmation_dispatches_only_an_exact_match() {
        let calls = Cell::new(0);
        let mut confirmation = ExactCountConfirmation::default();
        confirmation.open(3);
        confirmation.input = "2".to_owned();
        assert!(
            confirmation
                .dispatch::<(), ()>(|_count| {
                    calls.set(calls.get() + 1);
                    Ok(())
                })
                .is_none()
        );
        assert_eq!(calls.get(), 0);
        assert!(confirmation.open);

        confirmation.input = " 3 ".to_owned();
        let dispatched = confirmation.dispatch::<usize, ()>(|count| {
            calls.set(calls.get() + 1);
            Ok(count)
        });
        assert_eq!(dispatched, Some(Ok(3)));
        assert_eq!(calls.get(), 1);
        assert!(!confirmation.open);
    }

    #[test]
    fn recovery_and_latest_apply_control_mutation_visibility() {
        let ready = PreviewReadiness {
            source_count: 2,
            changed_count: 2,
            blocked_count: 0,
            can_apply: true,
        };

        let without_latest = MutationVisibility::new(ready, false, None, true);
        assert!(without_latest.apply_enabled);
        assert!(!without_latest.undo_enabled);

        let with_latest_apply =
            MutationVisibility::new(ready, false, Some(TransactionKind::Apply), true);
        assert!(with_latest_apply.undo_enabled);

        let with_recovery = MutationVisibility::new(ready, true, None, true);
        assert!(with_recovery.recovery_banner);
        assert!(!with_recovery.apply_enabled);
        assert!(!with_recovery.undo_enabled);

        let preview_only =
            MutationVisibility::new(ready, false, Some(TransactionKind::Apply), false);
        assert!(!preview_only.apply_enabled);
        assert!(!preview_only.undo_enabled);
    }

    #[test]
    fn a_rule_edit_can_restore_preview_after_a_preview_error()
    -> Result<(), Box<dyn std::error::Error>> {
        let fixture = Fixture::new()?;
        fs::write(fixture.source(), b"contents")?;
        let engine = RenameEngine::new(fixture.journals())?;
        let mut app = DarkRenamerApp::new(engine);
        app.rules.items = vec![RenameRule::Prefix("x".repeat(256))];

        app.admit_paths(vec![fixture.source()]);
        assert!(app.has_admission);
        assert!(app.preview.is_none());

        app.rules.items = vec![RenameRule::Prefix("ready-".to_owned())];
        app.refresh_preview();

        assert!(app.preview.is_some());
        assert!(app.readiness().can_apply);
        Ok(())
    }

    #[test]
    fn all_rule_kinds_construct_every_core_variant() {
        let rules = RuleKind::ALL.map(RuleKind::default_rule);

        assert!(matches!(rules[0], RenameRule::LiteralReplace { .. }));
        assert!(matches!(rules[1], RenameRule::Prefix(_)));
        assert!(matches!(rules[2], RenameRule::Suffix(_)));
        assert!(matches!(rules[3], RenameRule::ClearStem));
        assert!(matches!(rules[4], RenameRule::RemoveCharacterRange { .. }));
        assert!(matches!(rules[5], RenameRule::KeepDigits));
        assert!(matches!(rules[6], RenameRule::PadDigitRuns { .. }));
        assert!(matches!(rules[7], RenameRule::Sequence { .. }));
        assert!(matches!(rules[8], RenameRule::RemoveExtension));
        assert!(matches!(rules[9], RenameRule::AddExtension(_)));
        assert!(matches!(rules[10], RenameRule::ReplaceExtension(_)));
        assert!(matches!(rules[11], RenameRule::ConvertCase { .. }));
    }

    #[test]
    fn accesskit_names_rule_and_confirmation_inputs() {
        #[derive(Default)]
        struct Inputs {
            prefix: String,
            count: String,
        }

        let harness = Harness::builder()
            .with_size(egui::vec2(480.0, 180.0))
            .build_ui_state(
                |ui, inputs| {
                    labeled_text_edit(ui, "Prefix", &mut inputs.prefix);
                    show_exact_count_input(ui, &mut inputs.count);
                },
                Inputs::default(),
            );

        let prefix = harness.get_by_role_and_label(egui::accesskit::Role::TextInput, "Prefix");
        let count =
            harness.get_by_role_and_label(egui::accesskit::Role::TextInput, "Exact changed count");
        assert_eq!(
            prefix.accesskit_node().role(),
            egui::accesskit::Role::TextInput
        );
        assert_eq!(
            count.accesskit_node().role(),
            egui::accesskit::Role::TextInput
        );
    }

    #[test]
    fn accesskit_apply_state_matches_the_platform_capability()
    -> Result<(), Box<dyn std::error::Error>> {
        let fixture = Fixture::new()?;
        fs::write(fixture.source(), b"contents")?;
        let engine = RenameEngine::new(fixture.journals())?;
        let mut app = DarkRenamerApp::new(engine);
        app.rules.items = vec![RenameRule::Prefix("final-".to_owned())];
        app.admit_paths(vec![fixture.source()]);

        let harness = Harness::builder()
            .with_size(egui::vec2(640.0, 120.0))
            .build_ui_state(|ui, app| app.show_actions(ui), app);
        let apply = harness.get_by_role_and_label(egui::accesskit::Role::Button, "Apply…");

        assert_eq!(apply.accesskit_node().is_disabled(), !cfg!(windows));
        Ok(())
    }
}
