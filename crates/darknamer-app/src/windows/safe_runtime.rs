use super::*;

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
                format!(
                    "{:?} 저널을 복구용으로 해석하지 못해 원본 핸들을 보존했습니다: {} (단계 {:?}, 오류 {:?}, OS {:?}, frame {:?}, {} bytes). 자동 삭제하지 않았으며 새 적용은 잠겼습니다.",
                    role,
                    evidence.path().display(),
                    failure.stage,
                    failure.kind,
                    failure.os_code,
                    failure.codec_frame,
                    evidence.byte_len(),
                )
            }
            Self::Unavailable {
                role,
                path,
                failure,
            } => format!(
                "{role:?} 저널을 열 수 없어 원본 핸들을 보존하지 못했습니다: {} (단계 {:?}, 오류 {:?}, OS {:?}). 경로를 다시 열어 복사하지 않으며 새 적용은 잠겼습니다.",
                path.display(),
                failure.stage,
                failure.kind,
                failure.os_code,
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
        .ok_or_else(|| io::Error::other("LOCALAPPDATA 환경 변수를 찾을 수 없습니다"))?;
    initialize_safe_runtime_at(&PathBuf::from(local_app_data))
}

pub(super) fn initialize_safe_runtime_at(local_app_data: &Path) -> io::Result<SafeRuntime> {
    if !local_app_data.is_absolute() {
        return Err(io::Error::other("저널 경로가 절대 경로가 아닙니다"));
    }
    drop(JournalRoot::open(local_app_data).map_err(io::Error::other)?);
    let app_root = local_app_data.join("DarkReNamer");
    if !app_root.exists() {
        fs::create_dir(&app_root)?;
    }
    drop(JournalRoot::open(&app_root).map_err(io::Error::other)?);
    let root_path = app_root.join("journal");
    if !root_path.exists() {
        fs::create_dir(&root_path)?;
    }
    let root = JournalRoot::open(&root_path).map_err(io::Error::other)?;
    let runtime_lock = root.acquire_runtime_lock("runtime.lock").map_err(|error| {
        io::Error::other(format!(
            "다른 DarkReNamer 인스턴스가 실행 중이거나 runtime lock을 확보할 수 없습니다: {error}"
        ))
    })?;
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
        let mut status = "active 저널과 candidate 저널을 동시에 발견했습니다. 자동 복구와 폐기를 중단하고 두 상태를 보존합니다.".to_owned();
        if let Some(journal) = active_journal.as_ref() {
            status.push_str(&format!(
                " Active 저널: {} ({} bytes).",
                journal.path().display(),
                journal.byte_len()
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
            return Err(io::Error::other("empty candidate state was lost"));
        };
        if let Err(error) = empty.mark_delete_if_safe() {
            staged_journal = Some(empty);
            let status = format!(
                "빈 candidate 저널을 정리하지 못해 보존했습니다: {error}. 새 적용은 잠겼습니다."
            );
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

    let Some(mut journal) = active_journal else {
        return Err(io::Error::other("active journal state was lost"));
    };
    let mut backend = WindowsRenameBackend;
    let outcome = RenameRecovery::new(&mut backend, &mut journal).rollback();
    match outcome {
        RecoveryOutcome::Recovered { .. } | RecoveryOutcome::NotRequired => {
            let cleanup = cleanup_file_journal(journal);
            let cleanup_failed = cleanup.error.is_some();
            let mut status = if matches!(outcome, RecoveryOutcome::Recovered { .. }) {
                "이전 변경을 안전하게 복구했습니다.".to_owned()
            } else {
                "저널 상태를 확인했습니다.".to_owned()
            };
            if let Some(error) = cleanup.error {
                status.push_str(&format!(" 저널 삭제 실패: {error}"));
            }
            append_staged_status(&mut status, staged_journal.as_ref());
            append_blocked_status(&mut status, &blocked_journals);
            Ok(SafeRuntime {
                root,
                runtime_lock,
                recovery_locked: cleanup_failed
                    || cleanup.retained.is_some()
                    || staged_journal.is_some()
                    || !blocked_journals.is_empty(),
                active_journal: cleanup.retained,
                staged_journal,
                blocked_journals,
                collision_observed: false,
                status: Some(status),
            })
        }
        RecoveryOutcome::Blocked { reason, .. } => {
            let status = status_with_staged_journal(
                format!("복구가 차단되었습니다: {reason:?}"),
                staged_journal.as_ref(),
            );
            let status = status_with_blocked_journals(status, &blocked_journals);
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
        RecoveryOutcome::RecoveryRequired { reason, .. } => {
            let status = status_with_staged_journal(
                format!("복구가 필요합니다: {reason:?}"),
                staged_journal.as_ref(),
            );
            let status = status_with_blocked_journals(status, &blocked_journals);
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
    }
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
        parts.push(format!(
            "활성화 전 저널을 보존했습니다: {}. 파일 변경은 시작되지 않았으며 새 적용은 잠겼습니다.",
            journal.path().display()
        ));
    }
    (!parts.is_empty()).then(|| parts.join(" "))
}

fn status_with_staged_journal(mut status: String, staged_journal: Option<&FileJournal>) -> String {
    append_staged_status(&mut status, staged_journal);
    status
}

fn append_staged_status(status: &mut String, staged_journal: Option<&FileJournal>) {
    if let Some(journal) = staged_journal {
        status.push_str(&format!(
            " 활성화 전 저널도 보존했습니다: {}. 새 적용은 잠겼습니다.",
            journal.path().display()
        ));
    }
}

fn status_with_blocked_journals(
    mut status: String,
    blocked_journals: &[StartupJournalBlock],
) -> String {
    append_blocked_status(&mut status, blocked_journals);
    status
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
