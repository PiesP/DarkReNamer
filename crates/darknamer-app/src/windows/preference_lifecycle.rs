use std::io;

use super::{
    AppearancePreferencesWriter, LanguagePreferencesWriter, PreferenceWriteEvent, PreferencesWriter,
};
use crate::i18n::LanguagePreference;
use crate::{ColumnState, UiAppearance};

/// Owns independent settings writes, diagnostics and their final close handoff.
#[derive(Default)]
pub(crate) struct PreferencePersistence {
    columns: Option<PreferencesWriter>,
    appearance: Option<AppearancePreferencesWriter>,
    column_status: WriterStatus,
    appearance_status: WriterStatus,
    language: Option<LanguagePreferencesWriter>,
    language_terminal_observed: bool,
    language_notify_saved: bool,
    language_requested: Option<u64>,
    language_saved: Option<LanguagePreference>,
}

#[derive(Default)]
struct WriterStatus {
    failed_generation: Option<u64>,
    terminal_observed: bool,
}

#[derive(Clone, Copy)]
enum PreferenceKind {
    Columns,
    Appearance,
}

impl PreferenceKind {
    fn label(self) -> &'static str {
        match self {
            Self::Columns => crate::i18n::common::Text::ColumnPreferences.get(),
            Self::Appearance => crate::i18n::common::Text::AppearancePreferences.get(),
        }
    }
}

impl WriterStatus {
    fn observe(
        &mut self,
        kind: PreferenceKind,
        events: Vec<PreferenceWriteEvent>,
        closing: bool,
    ) -> Vec<String> {
        let mut messages = Vec::new();
        for event in events {
            let message = match event {
                PreferenceWriteEvent::Saved { generation } => {
                    if self
                        .failed_generation
                        .is_some_and(|failed| generation >= failed)
                    {
                        self.failed_generation = None;
                        (!closing)
                            .then(|| crate::i18n::common::preference_saved_again(&(kind.label())))
                    } else {
                        None
                    }
                }
                PreferenceWriteEvent::Failed { generation, error } => {
                    self.failed_generation = Some(generation);
                    (!closing).then(|| {
                        crate::i18n::common::preference_save_failed(&(kind.label()), &(error))
                    })
                }
                PreferenceWriteEvent::Stopped => {
                    self.terminal_observed = true;
                    None
                }
                PreferenceWriteEvent::Panicked => {
                    self.terminal_observed = true;
                    (!closing)
                        .then(|| crate::i18n::common::preference_writer_stopped(&(kind.label())))
                }
            };
            if let Some(message) = message {
                messages.push(message);
            }
        }
        messages
    }
}

impl PreferencePersistence {
    pub(crate) fn take_saved_language(&mut self) -> Option<LanguagePreference> {
        self.language_saved.take()
    }
    pub(crate) fn install_language_writer(&mut self, writer: LanguagePreferencesWriter) {
        self.language = Some(writer);
    }

    pub(crate) fn submit_language(&mut self, preference: LanguagePreference) -> io::Result<()> {
        let generation = self
            .language
            .as_mut()
            .ok_or_else(|| io::Error::other("language preference writer is unavailable"))?
            .submit(preference)?;
        self.language_requested = Some(generation);
        self.language_notify_saved = true;
        Ok(())
    }

    /// Either writer may be absent after its independent startup failure.
    pub(crate) fn new(
        columns: Option<PreferencesWriter>,
        appearance: Option<AppearancePreferencesWriter>,
    ) -> Self {
        Self {
            columns,
            appearance,
            ..Self::default()
        }
    }

    pub(crate) fn submit_columns(&mut self, columns: [ColumnState; 7]) -> io::Result<()> {
        self.columns
            .as_mut()
            .ok_or_else(|| io::Error::other("column preference writer is unavailable"))?
            .submit(columns)
            .map(|_| ())
    }

    pub(crate) fn submit_appearance(&mut self, appearance: UiAppearance) -> io::Result<()> {
        self.appearance
            .as_mut()
            .ok_or_else(|| io::Error::other("appearance preference writer is unavailable"))?
            .submit(appearance)
            .map(|_| ())
    }

    /// Interprets each file's generations independently, suppressing notices while closing.
    pub(crate) fn drain(&mut self, closing: bool) -> Vec<String> {
        let columns = self
            .columns
            .as_ref()
            .map(PreferencesWriter::drain_events)
            .unwrap_or_default();
        let mut messages = self
            .column_status
            .observe(PreferenceKind::Columns, columns, closing);
        let appearance = self
            .appearance
            .as_ref()
            .map(AppearancePreferencesWriter::drain_events)
            .unwrap_or_default();
        messages.extend(self.appearance_status.observe(
            PreferenceKind::Appearance,
            appearance,
            closing,
        ));
        if let Some(writer) = &self.language {
            if let Some(preference) = writer.take_saved() {
                self.language_saved = Some(preference);
            }
            for event in writer.drain_events() {
                match event {
                    PreferenceWriteEvent::Saved { generation }
                        if !closing
                            && self.language_notify_saved
                            && self
                                .language_requested
                                .is_some_and(|requested| generation >= requested) =>
                    {
                        messages.push(crate::i18n::common::Text::LanguageSaved.get().to_owned());
                        self.language_notify_saved = false;
                    }
                    PreferenceWriteEvent::Failed { error, .. } if !closing => {
                        messages.push(crate::i18n::common::language_save_failed(&(error)))
                    }
                    PreferenceWriteEvent::Stopped | PreferenceWriteEvent::Panicked => {
                        self.language_terminal_observed = true;
                        if !closing && matches!(event, PreferenceWriteEvent::Panicked) {
                            messages.push(
                                crate::i18n::common::Text::LanguageWriterStopped
                                    .get()
                                    .to_owned(),
                            );
                        }
                    }
                    _ => {}
                }
            }
        }
        messages
    }

    /// Requests both final snapshots even if one file cannot accept its request.
    pub(crate) fn shutdown(
        &mut self,
        columns: [ColumnState; 7],
        appearance: UiAppearance,
    ) -> Vec<String> {
        let mut messages = Vec::new();
        if let Some(writer) = self.language.as_mut() {
            writer.request_shutdown();
        }
        if let Some(writer) = self.columns.as_mut()
            && let Err(error) = writer.shutdown_with(columns)
        {
            messages.push(crate::i18n::common::column_close_failed(&(error)));
        }
        if let Some(writer) = self.appearance.as_mut()
            && let Err(error) = writer.shutdown_with(appearance)
        {
            messages.push(crate::i18n::common::appearance_close_failed(&(error)));
        }
        messages
    }

    /// Terminal events may precede thread exit; join still completes before readiness.
    pub(crate) fn finish_if_ready(&mut self) -> bool {
        let _messages = self.drain(true);
        if self
            .columns
            .as_ref()
            .is_some_and(|writer| !self.column_status.terminal_observed && !writer.is_finished())
            || self.appearance.as_ref().is_some_and(|writer| {
                !self.appearance_status.terminal_observed && !writer.is_finished()
            })
            || self
                .language
                .as_ref()
                .is_some_and(|writer| !self.language_terminal_observed && !writer.is_finished())
        {
            return false;
        }
        self.join();
        true
    }

    /// Message-loop failure requires a blocking final flush rather than another wake.
    pub(crate) fn shutdown_and_join(
        &mut self,
        columns: [ColumnState; 7],
        appearance: UiAppearance,
    ) {
        let _messages = self.shutdown(columns, appearance);
        self.join();
    }

    pub(crate) fn is_joined(&self) -> bool {
        self.columns.is_none() && self.appearance.is_none() && self.language.is_none()
    }

    fn join(&mut self) {
        if let Some(mut writer) = self.language.take() {
            let _joined = writer.join();
        }
        if let Some(mut writer) = self.columns.take() {
            let _joined = writer.join();
            let _messages =
                self.column_status
                    .observe(PreferenceKind::Columns, writer.drain_events(), true);
        }
        if let Some(mut writer) = self.appearance.take() {
            let _joined = writer.join();
            let _messages = self.appearance_status.observe(
                PreferenceKind::Appearance,
                writer.drain_events(),
                true,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc::{self, Sender, SyncSender};
    use std::sync::{Arc, Condvar, Mutex};
    use std::thread;
    use std::time::{Duration, Instant};

    use super::*;
    use crate::default_column_states;
    use crate::preferences::{load_appearance_or_default, load_or_default};

    fn controlled_columns() -> (
        PreferencesWriter,
        Sender<PreferenceWriteEvent>,
        SyncSender<()>,
    ) {
        let (sender, events) = mpsc::channel();
        let (release, wait) = mpsc::sync_channel(1);
        let handle = thread::spawn(move || {
            let _released = wait.recv_timeout(Duration::from_secs(5));
        });
        let writer = PreferencesWriter {
            writer: super::super::CoalescingWriter {
                queue: Arc::new((
                    Mutex::new(super::super::PreferenceQueue::default()),
                    Condvar::new(),
                )),
                events,
                handle: Some(handle),
                next_generation: 0,
            },
        };
        (writer, sender, release)
    }

    fn controlled_appearance() -> (
        AppearancePreferencesWriter,
        Sender<PreferenceWriteEvent>,
        SyncSender<()>,
    ) {
        let (sender, events) = mpsc::channel();
        let (release, wait) = mpsc::sync_channel(1);
        let handle = thread::spawn(move || {
            let _released = wait.recv_timeout(Duration::from_secs(5));
        });
        let writer = AppearancePreferencesWriter {
            writer: super::super::CoalescingWriter {
                queue: Arc::new((
                    Mutex::new(super::super::PreferenceQueue::default()),
                    Condvar::new(),
                )),
                events,
                handle: Some(handle),
                next_generation: 0,
            },
        };
        (writer, sender, release)
    }

    #[test]
    fn interleaved_failures_and_stale_successes_remain_independent()
    -> Result<(), Box<dyn std::error::Error>> {
        let (columns, column_events, release_columns) = controlled_columns();
        let (appearance, appearance_events, release_appearance) = controlled_appearance();
        let mut persistence = PreferencePersistence::new(Some(columns), Some(appearance));
        column_events.send(PreferenceWriteEvent::Failed {
            generation: 2,
            error: "column failure".to_owned(),
        })?;
        appearance_events.send(PreferenceWriteEvent::Failed {
            generation: 5,
            error: "appearance failure".to_owned(),
        })?;
        assert_eq!(
            persistence.drain(false),
            [
                "열 표시 설정을 저장하지 못했습니다. 현재 작업에는 영향이 없습니다: column failure",
                "모양 설정을 저장하지 못했습니다. 현재 작업에는 영향이 없습니다: appearance failure",
            ]
        );
        column_events.send(PreferenceWriteEvent::Saved { generation: 1 })?;
        appearance_events.send(PreferenceWriteEvent::Saved { generation: 4 })?;
        assert!(persistence.drain(false).is_empty());
        column_events.send(PreferenceWriteEvent::Saved { generation: 2 })?;
        assert_eq!(
            persistence.drain(false),
            ["열 표시 설정을 다시 저장했습니다."]
        );
        appearance_events.send(PreferenceWriteEvent::Saved { generation: 6 })?;
        assert_eq!(persistence.drain(false), ["모양 설정을 다시 저장했습니다."]);
        column_events.send(PreferenceWriteEvent::Saved { generation: 3 })?;
        assert!(persistence.drain(false).is_empty());
        release_columns.send(())?;
        release_appearance.send(())?;
        Ok(())
    }

    #[test]
    fn close_suppresses_notices_and_waits_for_both_terminal_handoffs()
    -> Result<(), Box<dyn std::error::Error>> {
        let (columns, column_events, release_columns) = controlled_columns();
        let (appearance, appearance_events, release_appearance) = controlled_appearance();
        let mut persistence = PreferencePersistence::new(Some(columns), Some(appearance));
        assert!(!persistence.is_joined());
        assert!(!persistence.finish_if_ready());
        column_events.send(PreferenceWriteEvent::Failed {
            generation: 2,
            error: "suppressed".to_owned(),
        })?;
        assert!(persistence.drain(true).is_empty());
        column_events.send(PreferenceWriteEvent::Saved { generation: 2 })?;
        assert_eq!(
            persistence.drain(false),
            ["열 표시 설정을 다시 저장했습니다."]
        );
        column_events.send(PreferenceWriteEvent::Stopped)?;
        assert!(!persistence.finish_if_ready());
        assert!(!persistence.is_joined());
        appearance_events.send(PreferenceWriteEvent::Panicked)?;
        assert!(persistence.drain(true).is_empty());
        release_columns.send(())?;
        release_appearance.send(())?;
        assert!(persistence.finish_if_ready());
        assert!(persistence.is_joined());
        assert!(persistence.finish_if_ready());
        Ok(())
    }

    #[test]
    fn absent_or_failed_column_writer_does_not_skip_final_appearance_flush()
    -> Result<(), Box<dyn std::error::Error>> {
        for absent in [true, false] {
            let directory = tempfile::tempdir()?;
            let column_path = directory.path().join("ui-columns-v1");
            let appearance_path = directory.path().join("ui-appearance-v1");
            let columns = if absent {
                None
            } else {
                Some(PreferencesWriter::spawn_with(
                    column_path,
                    || {},
                    Arc::new(|_, _| {
                        Err(io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            "blocked columns",
                        ))
                    }),
                )?)
            };
            let appearance = AppearancePreferencesWriter::spawn(appearance_path.clone(), || {})?;
            let mut persistence = PreferencePersistence::new(columns, Some(appearance));
            assert_eq!(
                persistence.submit_columns(default_column_states()).is_err(),
                absent
            );
            persistence.submit_appearance(UiAppearance::default())?;
            let final_appearance = UiAppearance {
                theme: crate::AppThemeMode::Dark,
                ..UiAppearance::default()
            };
            assert!(
                persistence
                    .shutdown(default_column_states(), final_appearance)
                    .is_empty()
            );
            persistence.shutdown_and_join(default_column_states(), final_appearance);
            assert!(persistence.is_joined());
            assert_eq!(
                load_appearance_or_default(&appearance_path).appearance,
                final_appearance
            );
        }
        Ok(())
    }

    #[test]
    fn polling_without_wakes_drains_and_joins_final_snapshots()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let column_path = directory.path().join("ui-columns-v1");
        let appearance_path = directory.path().join("ui-appearance-v1");
        let columns = PreferencesWriter::spawn(column_path.clone(), || {})?;
        let appearance = AppearancePreferencesWriter::spawn(appearance_path.clone(), || {})?;
        let mut persistence = PreferencePersistence::new(Some(columns), Some(appearance));
        persistence.submit_columns(default_column_states())?;
        let mut final_columns = default_column_states();
        final_columns[5].set_visible(true);
        let final_appearance = UiAppearance {
            theme: crate::AppThemeMode::Dark,
            ..UiAppearance::default()
        };
        assert!(
            persistence
                .shutdown(final_columns, final_appearance)
                .is_empty()
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        while !persistence.finish_if_ready() {
            assert!(
                Instant::now() < deadline,
                "poll-only close did not become ready"
            );
            thread::sleep(Duration::from_millis(1));
        }
        assert!(persistence.is_joined());
        assert_eq!(
            load_or_default(&column_path, default_column_states()).columns,
            final_columns
        );
        assert_eq!(
            load_appearance_or_default(&appearance_path).appearance,
            final_appearance
        );
        Ok(())
    }

    #[test]
    fn shutdown_request_failure_does_not_skip_the_other_final_snapshot()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let mut columns = PreferencesWriter::spawn(directory.path().join("ui-columns-v1"), || {})?;
        columns
            .join()
            .map_err(|_| io::Error::other("column writer panicked"))?;
        let appearance_path = directory.path().join("ui-appearance-v1");
        let appearance = AppearancePreferencesWriter::spawn(appearance_path.clone(), || {})?;
        let mut persistence = PreferencePersistence::new(Some(columns), Some(appearance));
        let final_appearance = UiAppearance {
            theme: crate::AppThemeMode::Dark,
            ..UiAppearance::default()
        };
        assert_eq!(
            persistence.shutdown(default_column_states(), final_appearance),
            [
                "종료 전 열 표시 설정을 저장하도록 요청하지 못했습니다: column preference writer has stopped",
            ]
        );
        persistence.shutdown_and_join(default_column_states(), final_appearance);
        assert!(persistence.is_joined());
        assert_eq!(
            load_appearance_or_default(&appearance_path).appearance,
            final_appearance
        );
        Ok(())
    }

    #[test]
    fn terminal_before_thread_exit_is_ready_to_join_but_never_joined_early()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("ui-columns-v1");
        let wakes = Arc::new(AtomicUsize::new(0));
        let worker_wakes = Arc::clone(&wakes);
        let (terminal, observed_terminal) = mpsc::channel();
        let (release, wait) = mpsc::sync_channel(1);
        let wait = Mutex::new(wait);
        let columns = PreferencesWriter::spawn(path, move || {
            if worker_wakes.fetch_add(1, Ordering::AcqRel) == 1 {
                let _sent = terminal.send(());
                let _released = wait
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .recv_timeout(Duration::from_secs(5));
            }
        })?;
        let mut persistence = PreferencePersistence::new(Some(columns), None);
        assert!(
            persistence
                .shutdown(default_column_states(), UiAppearance::default())
                .is_empty()
        );
        observed_terminal.recv_timeout(Duration::from_secs(5))?;
        let (done, completed) = mpsc::channel();
        let (started, started_finishing) = mpsc::channel();
        let finisher = thread::spawn(move || {
            let _sent = started.send(());
            let ready = persistence.finish_if_ready();
            let _sent = done.send(ready);
            (persistence, ready)
        });
        started_finishing.recv_timeout(Duration::from_secs(5))?;
        assert!(matches!(
            completed.recv_timeout(Duration::from_millis(20)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        release.send(())?;
        let (persistence, ready) = finisher
            .join()
            .map_err(|_| io::Error::other("finisher panicked"))?;
        assert!(ready);
        assert!(persistence.is_joined());
        Ok(())
    }
}
