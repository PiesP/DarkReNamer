use crate::rename::ExistingJournalOpenError;
use crate::rename::FileJournal;
use crate::rename::JournalCleanupDecision;
use crate::rename::JournalOpenFailure;
use crate::rename::JournalRoot;
use crate::rename::RecoveryJournalEvidence;
use crate::rename::cleanup_decision;
use std::env;
use std::fs;
use std::io;
use std::path::Path;
use std::path::PathBuf;

use super::{ACTIVE_JOURNAL_LEAF, CANDIDATE_JOURNAL_LEAF};
use crate::i18n::runtime::{self as text, Text as RuntimeText};

pub(super) struct SafeRuntime {
    pub(super) root: JournalRoot,
    pub(super) active_journal: Option<FileJournal>,
    pub(super) staged_journal: Option<FileJournal>,
    pub(super) blocked_journals: Vec<StartupJournalBlock>,
    pub(super) collision_observed: bool,
    pub(super) recovery_locked: bool,
    pub(super) status: Option<String>,
    // Fields drop in declaration order. Keep the instance lock last so every
    // retained journal capability closes before another process can start.
    pub(super) runtime_lock: fs::File,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum JournalRole {
    Active,
    Candidate,
}

pub(super) struct JournalCleanup {
    pub(super) retained: Option<FileJournal>,
    pub(super) error: Option<io::Error>,
}

#[derive(Debug)]
pub(super) enum StartupJournalBlock {
    Evidence {
        role: JournalRole,
        evidence: RecoveryJournalEvidence,
    },
    Unavailable {
        role: JournalRole,
        path: PathBuf,
        failure: JournalOpenFailure,
    },
}

impl StartupJournalBlock {
    pub(super) fn from_open_error(
        role: JournalRole,
        error: ExistingJournalOpenError,
    ) -> Option<Self> {
        if error.is_not_found() {
            return None;
        }
        let path = error.path().to_path_buf();
        let failure = error.failure();
        Some(match error.into_evidence() {
            Some(evidence) => Self::Evidence { role, evidence },
            None => Self::Unavailable {
                role,
                path,
                failure,
            },
        })
    }

    pub(super) const fn role(&self) -> JournalRole {
        match self {
            Self::Evidence { role, .. } | Self::Unavailable { role, .. } => *role,
        }
    }

    pub(super) fn status_korean(&self) -> String {
        match self {
            Self::Evidence { role, evidence } => {
                let failure = evidence.failure();
                text::blocked_journal_evidence(
                    role,
                    &evidence.path().display(),
                    &failure.stage,
                    &failure.kind,
                    &failure.os_code,
                    &failure.codec_frame,
                    evidence.byte_len(),
                )
            }
            Self::Unavailable {
                role,
                path,
                failure,
            } => text::blocked_journal_unavailable(
                role,
                &path.display(),
                &failure.stage,
                &failure.kind,
                &failure.os_code,
            ),
        }
    }

    pub(super) fn evidence_mut(&mut self) -> Option<&mut RecoveryJournalEvidence> {
        match self {
            Self::Evidence { evidence, .. } => Some(evidence),
            Self::Unavailable { .. } => None,
        }
    }

    pub(super) fn evidence(&self) -> Option<&RecoveryJournalEvidence> {
        match self {
            Self::Evidence { evidence, .. } => Some(evidence),
            Self::Unavailable { .. } => None,
        }
    }
}

pub(super) fn initialize_safe_runtime() -> io::Result<SafeRuntime> {
    let local_app_data = env::var_os("LOCALAPPDATA")
        .ok_or_else(|| io::Error::other(RuntimeText::MissingLocalAppData.get()))?;
    initialize_safe_runtime_at(&PathBuf::from(local_app_data))
}

pub(super) fn initialize_safe_runtime_at(local_app_data: &Path) -> io::Result<SafeRuntime> {
    if !local_app_data.is_absolute() {
        return Err(io::Error::other(RuntimeText::JournalRootNotAbsolute.get()));
    }
    let root = JournalRoot::open_private(local_app_data).map_err(io::Error::other)?;
    let runtime_lock = root
        .acquire_runtime_lock("runtime.lock")
        .map_err(|error| io::Error::other(text::runtime_lock_failed(&error)))?;
    let mut blocked_journals = Vec::new();
    let active_journal = match FileJournal::open_existing_retained(&root, ACTIVE_JOURNAL_LEAF) {
        Ok(journal) => Some(journal),
        Err(error) => {
            if let Some(blocked) = StartupJournalBlock::from_open_error(JournalRole::Active, error)
            {
                blocked_journals.push(blocked);
            }
            None
        }
    };
    let mut staged_journal = match FileJournal::open_candidate_existing_retained(
        &root,
        CANDIDATE_JOURNAL_LEAF,
        ACTIVE_JOURNAL_LEAF,
    ) {
        Ok(journal) => Some(journal),
        Err(error) => {
            if let Some(blocked) =
                StartupJournalBlock::from_open_error(JournalRole::Candidate, error)
            {
                blocked_journals.push(blocked);
            }
            None
        }
    };
    let active_observed = active_journal.is_some()
        || blocked_journals
            .iter()
            .any(|blocked| blocked.role() == JournalRole::Active);
    let candidate_observed = staged_journal.is_some()
        || blocked_journals
            .iter()
            .any(|blocked| blocked.role() == JournalRole::Candidate);
    if active_observed && candidate_observed {
        let mut status = RuntimeText::ConflictingJournals.get().to_owned();
        if let Some(journal) = active_journal.as_ref() {
            status.push_str(&text::active_journal_detail(
                &journal.path().display(),
                journal.byte_len(),
            ));
        }
        append_blocked_status(&mut status, &blocked_journals);
        append_staged_status(&mut status, staged_journal.as_ref());
        return Ok(SafeRuntime {
            root,
            runtime_lock,
            active_journal,
            staged_journal,
            blocked_journals,
            collision_observed: true,
            recovery_locked: true,
            status: Some(status),
        });
    }
    if staged_journal
        .as_ref()
        .is_some_and(FileJournal::is_physically_empty_candidate)
    {
        let Some(mut empty) = staged_journal.take() else {
            return Err(io::Error::other(
                crate::i18n::runtime::Text::CandidateEmptyStateLost.get(),
            ));
        };
        if let Err(error) = empty.mark_delete_if_safe() {
            staged_journal = Some(empty);
            let status = text::empty_candidate_retained(&error);
            return Ok(SafeRuntime {
                root,
                runtime_lock,
                active_journal: None,
                staged_journal,
                blocked_journals,
                collision_observed: false,
                recovery_locked: true,
                status: Some(status),
            });
        }
        drop(empty);
    }
    if active_journal.is_none() {
        let has_staged = staged_journal.is_some();
        let status = startup_locked_status(staged_journal.as_ref(), &blocked_journals);
        let recovery_locked = has_staged || !blocked_journals.is_empty();
        return Ok(SafeRuntime {
            root,
            runtime_lock,
            active_journal: None,
            staged_journal,
            blocked_journals,
            collision_observed: false,
            recovery_locked,
            status,
        });
    }

    let Some(journal) = active_journal else {
        return Err(io::Error::other(
            crate::i18n::runtime::Text::ActiveStateLost.get(),
        ));
    };
    let mut status = text::active_journal_found(&journal.path().display(), journal.byte_len());
    append_staged_status(&mut status, staged_journal.as_ref());
    append_blocked_status(&mut status, &blocked_journals);
    Ok(SafeRuntime {
        root,
        runtime_lock,
        active_journal: Some(journal),
        staged_journal,
        blocked_journals,
        collision_observed: false,
        recovery_locked: true,
        status: Some(status),
    })
}

fn startup_locked_status(
    staged_journal: Option<&FileJournal>,
    blocked_journals: &[StartupJournalBlock],
) -> Option<String> {
    let mut parts = blocked_journals
        .iter()
        .map(StartupJournalBlock::status_korean)
        .collect::<Vec<_>>();
    if let Some(journal) = staged_journal {
        parts.push(text::staged_journal_found(&journal.path().display()));
    }
    (!parts.is_empty()).then(|| parts.join(" "))
}

fn append_staged_status(status: &mut String, staged_journal: Option<&FileJournal>) {
    if let Some(journal) = staged_journal {
        status.push_str(&text::staged_journal_also_retained(
            &journal.path().display(),
        ));
    }
}

fn append_blocked_status(status: &mut String, blocked_journals: &[StartupJournalBlock]) {
    for blocked in blocked_journals {
        status.push(' ');
        status.push_str(&blocked.status_korean());
    }
}

pub(super) fn cleanup_file_journal(mut journal: FileJournal) -> JournalCleanup {
    if cleanup_decision(journal.records()) == JournalCleanupDecision::Retain {
        return JournalCleanup {
            retained: Some(journal),
            error: None,
        };
    }
    match journal.mark_delete_if_safe() {
        Ok(()) => {
            drop(journal);
            JournalCleanup {
                retained: None,
                error: None,
            }
        }
        Err(error) => JournalCleanup {
            retained: Some(journal),
            error: Some(io::Error::other(error)),
        },
    }
}
