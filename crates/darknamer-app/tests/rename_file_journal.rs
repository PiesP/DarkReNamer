use std::fs;

use darknamer_app::rename::{
    AppendCertainty, EntryId, EntryIdentity, EntryKind, FileJournal, FileJournalErrorKind,
    JournalCodecErrorKind, JournalDirection, JournalOpenStage, JournalRecord, JournalRoot,
    JournalStep, JournalStore, JournalTailIssue, JournalTerminal, MAX_JOURNAL_FRAME_BYTES,
    MAX_JOURNAL_STEPS, MAX_PATH_UNITS, MemoryBackend, MemoryJournal, ModelRevision, PlanId,
    PlanRequest, RecoveryOutcome, RenameExecutor, RenameIntent, RenamePlanner, RenameRecovery,
    TemporaryPhase, decode_journal_records, encode_journal_records, inspect_journal_records,
};
use darknamer_core::LegacyText;

fn step(entry: u32, source: LegacyText, destination: LegacyText) -> JournalStep {
    step_with_phase(entry, source, destination, TemporaryPhase::None)
}

fn step_with_phase(
    entry: u32,
    source: LegacyText,
    destination: LegacyText,
    phase: TemporaryPhase,
) -> JournalStep {
    JournalStep::new(
        EntryId::new(entry),
        source,
        destination,
        EntryIdentity::new(7, u128::from(entry) + 10),
        EntryIdentity::new(7, 1),
        EntryIdentity::new(7, 1),
        phase,
    )
}

fn complete_records() -> Vec<JournalRecord> {
    vec![
        JournalRecord::Intent {
            plan: PlanId::from_fingerprint(42),
            steps: vec![
                step(
                    0,
                    LegacyText::from_units(vec![b'C' as u16, b':' as u16, b'\\' as u16, 0xD800]),
                    LegacyText::from("C:\\work\\b.txt"),
                ),
                step_with_phase(
                    1,
                    LegacyText::from("C:\\work\\c.txt"),
                    LegacyText::from("C:\\work\\d.txt"),
                    TemporaryPhase::IntoTemporary,
                ),
                step_with_phase(
                    2,
                    LegacyText::from("C:\\work\\temp.tmp"),
                    LegacyText::from("C:\\work\\e.txt"),
                    TemporaryPhase::FromTemporary,
                ),
            ]
            .into_boxed_slice(),
        },
        JournalRecord::Prepared {
            step: 0,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Completed {
            step: 0,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Prepared {
            step: 1,
            direction: JournalDirection::Forward,
        },
        JournalRecord::NotApplied {
            step: 1,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Prepared {
            step: 0,
            direction: JournalDirection::Rollback,
        },
        JournalRecord::Completed {
            step: 0,
            direction: JournalDirection::Rollback,
        },
        JournalRecord::Terminal(JournalTerminal::RolledBack),
    ]
}

fn prepared_fixture() -> Result<Vec<JournalRecord>, Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![RenameIntent::new(
            EntryId::new(0),
            "C:\\work\\a.txt",
            "C:\\work",
            "b.txt",
            EntryKind::File,
        )],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    backend.fail_ambiguous_move_on(1, 995);
    let mut journal = MemoryJournal::new();
    let _ = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    Ok(journal.records().to_vec())
}

fn supported_journal_root(
    path: &std::path::Path,
) -> Result<Option<JournalRoot>, Box<dyn std::error::Error>> {
    match JournalRoot::open(path) {
        Ok(root) => Ok(Some(root)),
        #[cfg(windows)]
        Err(error) if matches!(error.os_code, Some(87 | 120)) => Ok(None),
        Err(error) => Err(error.into()),
    }
}

#[test]
fn every_record_round_trips_exact_utf16_and_manifest_identities()
-> Result<(), Box<dyn std::error::Error>> {
    let records = complete_records();
    let encoded = encode_journal_records(&records)?;
    let decoded = decode_journal_records(&encoded)?;
    assert_eq!(decoded, records);
    Ok(())
}

#[test]
fn decoder_rejects_torn_checksum_version_sequence_and_unknown_kind()
-> Result<(), Box<dyn std::error::Error>> {
    let encoded = encode_journal_records(&complete_records())?;

    let mut torn = encoded.clone();
    torn.pop();
    assert_eq!(
        decode_journal_records(&torn).err().map(|error| error.kind),
        Some(JournalCodecErrorKind::TruncatedFrame)
    );

    let mut checksum = encoded.clone();
    let last = checksum.len() - 1;
    checksum[last] ^= 0x80;
    assert_eq!(
        decode_journal_records(&checksum)
            .err()
            .map(|error| error.kind),
        Some(JournalCodecErrorKind::ChecksumMismatch)
    );

    let mut version = encoded.clone();
    version[4..6].copy_from_slice(&99_u16.to_le_bytes());
    assert_eq!(
        decode_journal_records(&version)
            .err()
            .map(|error| error.kind),
        Some(JournalCodecErrorKind::UnsupportedVersion)
    );

    let mut sequence = encoded.clone();
    sequence[8..16].copy_from_slice(&9_u64.to_le_bytes());
    assert_eq!(
        decode_journal_records(&sequence)
            .err()
            .map(|error| error.kind),
        Some(JournalCodecErrorKind::SequenceMismatch)
    );

    let mut kind = encoded;
    kind[6] = 0xff;
    assert_eq!(
        decode_journal_records(&kind).err().map(|error| error.kind),
        Some(JournalCodecErrorKind::UnknownRecordKind)
    );
    Ok(())
}

#[test]
fn corrupt_existing_journal_retains_exact_handle_for_bounded_copy()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let path = directory.path().join("active.drj");
    let copied = directory.path().join("diagnostic-copy.drj");
    let mut corrupt = encode_journal_records(&complete_records())?;
    let last = corrupt.len() - 1;
    corrupt[last] ^= 0x80;
    fs::write(&path, &corrupt)?;

    let error = FileJournal::open_existing_retained(&root, "active.drj")
        .err()
        .ok_or_else(|| std::io::Error::other("corrupt journal decoded"))?;
    assert_eq!(error.failure().stage, JournalOpenStage::Decode);
    assert_eq!(
        error.failure().kind,
        FileJournalErrorKind::Codec(JournalCodecErrorKind::ChecksumMismatch)
    );
    assert!(error.failure().codec_frame.is_some());
    let mut evidence = error
        .into_evidence()
        .ok_or_else(|| std::io::Error::other("corrupt file handle was dropped"))?;

    #[cfg(unix)]
    {
        let moved = directory.path().join("retained-corrupt.drj");
        fs::rename(&path, &moved)?;
        fs::write(&path, b"substituted path")?;
    }
    evidence.copy_exact_to_new(&copied)?;

    assert_eq!(fs::read(copied)?, corrupt);
    assert_eq!(evidence.byte_len(), corrupt.len() as u64);
    assert!(evidence.copy_exact_to_new(&path).is_err());
    Ok(())
}

#[test]
fn valid_file_journal_exports_exact_bytes_and_restores_append_cursor()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let source = directory.path().join("active.drj");
    let copied = directory.path().join("active.drj.retained");
    let plan = PlanId::from_fingerprint(91);
    let steps = vec![step(
        0,
        LegacyText::from("C:\\work\\a.txt"),
        LegacyText::from("C:\\work\\b.txt"),
    )];
    let mut journal = FileJournal::create_new(&root, "active.drj")?;
    journal.begin(plan, &steps)?;
    let expected = fs::read(&source)?;

    assert_eq!(journal.copy_exact_to_new(&copied)?, expected.len() as u64);
    assert_eq!(fs::read(&copied)?, expected);

    journal.prepared(0, JournalDirection::Forward)?;
    let records = decode_journal_records(&fs::read(source)?)?;
    assert!(matches!(
        records.as_slice(),
        [
            JournalRecord::Intent { .. },
            JournalRecord::Prepared { step: 0, .. }
        ]
    ));
    Ok(())
}

#[test]
fn torn_candidates_are_neither_physically_empty_nor_complete_intent()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let intent = JournalRecord::Intent {
        plan: PlanId::from_fingerprint(92),
        steps: vec![step(
            0,
            LegacyText::from("C:\\work\\a.txt"),
            LegacyText::from("C:\\work\\b.txt"),
        )]
        .into_boxed_slice(),
    };
    let intent_bytes = encode_journal_records(std::slice::from_ref(&intent))?;
    let candidate = directory.path().join("candidate.drj");

    fs::write(&candidate, &intent_bytes[..8])?;
    let partial_intent =
        FileJournal::open_candidate_existing_retained(&root, "candidate.drj", "active.drj")
            .err()
            .ok_or_else(|| std::io::Error::other("partial Intent candidate was accepted"))?;
    assert_eq!(
        partial_intent.failure().kind,
        FileJournalErrorKind::Codec(JournalCodecErrorKind::TruncatedFrame)
    );
    assert!(partial_intent.into_evidence().is_some());

    fs::remove_file(&candidate)?;
    let records = vec![
        intent,
        JournalRecord::Prepared {
            step: 0,
            direction: JournalDirection::Forward,
        },
    ];
    let intent_and_prepared = encode_journal_records(&records)?;
    fs::write(
        &candidate,
        &intent_and_prepared[..intent_bytes.len().saturating_add(8)],
    )?;
    let mut partial_prepared =
        FileJournal::open_candidate_existing(&root, "candidate.drj", "active.drj")?;
    assert!(matches!(
        partial_prepared.records(),
        [JournalRecord::Intent { .. }]
    ));
    assert!(partial_prepared.tail_issue().is_some());
    assert!(!partial_prepared.is_physically_empty_candidate());
    assert!(!partial_prepared.is_complete_intent_candidate());
    assert!(matches!(
        partial_prepared.mark_delete_if_safe(),
        Err(error) if error.kind == FileJournalErrorKind::UnsafeCleanupState
    ));
    Ok(())
}

#[cfg(windows)]
#[test]
fn intent_candidate_discard_requires_active_absence_and_deletes_by_retained_handle()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let root = JournalRoot::open(directory.path())?;
    let intent = JournalRecord::Intent {
        plan: PlanId::from_fingerprint(93),
        steps: vec![step(
            0,
            LegacyText::from("C:\\work\\a.txt"),
            LegacyText::from("C:\\work\\b.txt"),
        )]
        .into_boxed_slice(),
    };
    let bytes = encode_journal_records(&[intent])?;
    let candidate_path = directory.path().join("candidate.drj");
    fs::write(&candidate_path, &bytes)?;
    let mut candidate = FileJournal::open_candidate_existing(&root, "candidate.drj", "active.drj")?;
    let mut active = FileJournal::create_new(&root, "active.drj")?;

    let blocked = candidate.mark_unactivated_intent_delete();
    assert!(matches!(
        blocked,
        Err(error) if error.kind == FileJournalErrorKind::UnsafeCleanupState
    ));
    active.mark_delete_if_safe()?;
    drop(active);

    candidate.mark_unactivated_intent_delete()?;
    drop(candidate);
    assert!(!candidate_path.exists());
    Ok(())
}

#[test]
fn decoder_rejects_invalid_record_order() -> Result<(), Box<dyn std::error::Error>> {
    let records = vec![
        JournalRecord::Intent {
            plan: PlanId::from_fingerprint(3),
            steps: vec![step(
                0,
                LegacyText::from("C:\\a"),
                LegacyText::from("C:\\b"),
            )]
            .into_boxed_slice(),
        },
        JournalRecord::Completed {
            step: 0,
            direction: JournalDirection::Forward,
        },
    ];
    let encoded = encode_journal_records(&records)?;
    assert_eq!(
        decode_journal_records(&encoded)
            .err()
            .map(|error| error.kind),
        Some(JournalCodecErrorKind::InvalidTransitions)
    );
    Ok(())
}

#[test]
fn codec_rejects_oversized_step_path_and_declared_frame() -> Result<(), Box<dyn std::error::Error>>
{
    let too_many = JournalRecord::Intent {
        plan: PlanId::from_fingerprint(1),
        steps: (0..=MAX_JOURNAL_STEPS)
            .map(|index| {
                step(
                    index as u32,
                    LegacyText::from("C:\\a"),
                    LegacyText::from("C:\\b"),
                )
            })
            .collect::<Vec<_>>()
            .into_boxed_slice(),
    };
    assert_eq!(
        encode_journal_records(&[too_many])
            .err()
            .map(|error| error.kind),
        Some(JournalCodecErrorKind::TooManySteps)
    );

    let oversized_path = JournalRecord::Intent {
        plan: PlanId::from_fingerprint(2),
        steps: vec![step(
            0,
            LegacyText::from_units(vec![b'a' as u16; MAX_PATH_UNITS + 1]),
            LegacyText::from("C:\\b"),
        )]
        .into_boxed_slice(),
    };
    assert_eq!(
        encode_journal_records(&[oversized_path])
            .err()
            .map(|error| error.kind),
        Some(JournalCodecErrorKind::PathTooLong)
    );

    let maximum_path = LegacyText::from_units(vec![b'a' as u16; MAX_PATH_UNITS]);
    let oversized_manifest = JournalRecord::Intent {
        plan: PlanId::from_fingerprint(3),
        steps: (0..128)
            .map(|index| step(index, maximum_path.clone(), maximum_path.clone()))
            .collect::<Vec<_>>()
            .into_boxed_slice(),
    };
    assert_eq!(
        encode_journal_records(&[oversized_manifest])
            .err()
            .map(|error| error.kind),
        Some(JournalCodecErrorKind::FrameTooLarge)
    );

    let mut oversized_frame = encode_journal_records(&complete_records())?;
    oversized_frame[16..20].copy_from_slice(&((MAX_JOURNAL_FRAME_BYTES + 1) as u32).to_le_bytes());
    assert_eq!(
        decode_journal_records(&oversized_frame)
            .err()
            .map(|error| error.kind),
        Some(JournalCodecErrorKind::FrameTooLarge)
    );
    Ok(())
}

#[test]
fn file_journal_create_append_sync_resume_and_never_auto_delete()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let path = directory.path().join("transaction.drj");
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let records = complete_records();
    let JournalRecord::Intent { plan, steps } = &records[0] else {
        return Err(std::io::Error::other("fixture intent missing").into());
    };
    {
        let mut journal = FileJournal::create_new(&root, "transaction.drj")?;
        journal.begin(*plan, steps)?;
        for record in &records[1..] {
            match record {
                JournalRecord::Prepared { step, direction } => {
                    journal.prepared(*step, *direction)?;
                }
                JournalRecord::Completed { step, direction } => {
                    journal.completed(*step, *direction)?;
                }
                JournalRecord::NotApplied { step, direction } => {
                    journal.not_applied(*step, *direction)?;
                }
                JournalRecord::Terminal(terminal) => journal.terminal(*terminal)?,
                JournalRecord::Intent { .. } => {
                    return Err(std::io::Error::other("duplicate fixture intent").into());
                }
            }
        }
        assert_eq!(journal.records(), records);
    }
    assert!(path.exists());
    let resumed = FileJournal::open_existing(&root, "transaction.drj")?;
    assert_eq!(resumed.records(), records);
    drop(resumed);
    assert_eq!(decode_journal_records(&fs::read(path)?)?, records);
    Ok(())
}

#[cfg(windows)]
#[test]
fn candidate_intent_is_durable_before_no_replace_active_promotion()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let records = complete_records();
    let JournalRecord::Intent { plan, steps } = &records[0] else {
        return Err(std::io::Error::other("fixture intent missing").into());
    };
    let candidate_path = directory.path().join("candidate.drj");
    let active_path = directory.path().join("active.drj");
    let mut journal = FileJournal::create_candidate(&root, "candidate.drj", "active.drj")?;

    journal.begin(*plan, steps)?;

    assert!(!journal.is_candidate());
    assert_eq!(journal.path(), active_path);
    assert!(!candidate_path.exists());
    assert!(active_path.exists());
    let expected_records = journal.records().to_vec();
    drop(journal);

    assert_eq!(
        decode_journal_records(&fs::read(&active_path)?)?,
        expected_records
    );
    let resumed = FileJournal::open_existing(&root, "active.drj")?;
    assert_eq!(resumed.records(), expected_records);
    Ok(())
}

#[test]
fn active_collision_preserves_both_files_and_poisons_candidate()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let active_path = directory.path().join("active.drj");
    let candidate_path = directory.path().join("candidate.drj");
    fs::write(&active_path, b"external active evidence")?;
    let records = complete_records();
    let JournalRecord::Intent { plan, steps } = &records[0] else {
        return Err(std::io::Error::other("fixture intent missing").into());
    };
    let mut journal = FileJournal::create_candidate(&root, "candidate.drj", "active.drj")?;

    let promotion = journal
        .begin(*plan, steps)
        .err()
        .ok_or_else(|| std::io::Error::other("active collision was replaced"))?;
    let follow_up = journal
        .prepared(0, JournalDirection::Forward)
        .err()
        .ok_or_else(|| std::io::Error::other("poisoned candidate accepted a record"))?;
    let retry = journal
        .begin(*plan, steps)
        .err()
        .ok_or_else(|| std::io::Error::other("uncertain promotion was retried"))?;

    assert_eq!(promotion.certainty, AppendCertainty::MayHaveAppended);
    assert_eq!(follow_up.certainty, AppendCertainty::MayHaveAppended);
    assert_eq!(retry.certainty, AppendCertainty::MayHaveAppended);
    assert_eq!(fs::read(active_path)?, b"external active evidence");
    assert!(candidate_path.exists());
    assert!(matches!(
        journal.mark_delete_if_safe(),
        Err(error) if error.kind == FileJournalErrorKind::UnsafeCleanupState
    ));
    Ok(())
}

#[cfg(not(windows))]
#[test]
fn non_windows_candidate_promotion_fails_closed_without_path_mutation()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let records = complete_records();
    let JournalRecord::Intent { plan, steps } = &records[0] else {
        return Err(std::io::Error::other("fixture intent missing").into());
    };
    let candidate_path = directory.path().join("candidate.drj");
    let active_path = directory.path().join("active.drj");
    let mut journal = FileJournal::create_candidate(&root, "candidate.drj", "active.drj")?;

    let error = journal
        .begin(*plan, steps)
        .err()
        .ok_or_else(|| std::io::Error::other("non-Windows promotion unexpectedly succeeded"))?;

    assert_eq!(error.certainty, AppendCertainty::MayHaveAppended);
    assert!(candidate_path.exists());
    assert!(!active_path.exists());
    assert_eq!(journal.path(), candidate_path);
    Ok(())
}

#[test]
fn abandoned_intent_candidate_reopens_without_becoming_active()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let records = complete_records();
    fs::write(
        directory.path().join("candidate.drj"),
        encode_journal_records(&records[..1])?,
    )?;

    let mut candidate = FileJournal::open_candidate_existing(&root, "candidate.drj", "active.drj")?;
    let transition = candidate
        .prepared(0, JournalDirection::Forward)
        .err()
        .ok_or_else(|| std::io::Error::other("candidate accepted an execution transition"))?;

    assert!(candidate.is_candidate());
    assert_eq!(transition.certainty, AppendCertainty::NotAppended);
    assert_eq!(candidate.records(), &records[..1]);
    assert_eq!(candidate.path(), directory.path().join("candidate.drj"));
    assert!(!directory.path().join("active.drj").exists());
    Ok(())
}

#[test]
fn candidate_with_execution_records_is_rejected_as_invalid_state()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    fs::write(
        directory.path().join("candidate.drj"),
        encode_journal_records(&complete_records())?,
    )?;

    let error = FileJournal::open_candidate_existing(&root, "candidate.drj", "active.drj")
        .err()
        .ok_or_else(|| std::io::Error::other("executing candidate was trusted"))?;

    assert_eq!(error.kind, FileJournalErrorKind::InvalidCandidateState);
    assert!(directory.path().join("candidate.drj").exists());
    Ok(())
}

#[cfg(unix)]
#[test]
fn retained_linux_validation_handle_is_not_substituted_by_path_replacement()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let path = directory.path().join("transaction.drj");
    let moved = directory.path().join("retained.drj");
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let records = complete_records();
    let JournalRecord::Intent { plan, steps } = &records[0] else {
        return Err(std::io::Error::other("fixture intent missing").into());
    };
    let mut journal = FileJournal::create_new(&root, "transaction.drj")?;
    journal.begin(*plan, steps)?;
    fs::rename(&path, &moved)?;
    fs::write(&path, [])?;

    journal.prepared(0, JournalDirection::Forward)?;

    assert_eq!(decode_journal_records(&fs::read(moved)?)?.len(), 2);
    assert!(fs::read(path)?.is_empty());
    Ok(())
}

#[test]
fn final_torn_prepared_frame_retains_prefix_then_truncates_on_authorized_recovery()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let path = directory.path().join("prepared-torn.drj");
    let records = prepared_fixture()?;
    let mut bytes = encode_journal_records(&records)?;
    let intent_bytes = encode_journal_records(&records[..1])?.len();
    bytes.truncate(intent_bytes + 8);
    fs::write(&path, &bytes)?;
    let inspection = inspect_journal_records(&bytes)?;
    assert_eq!(inspection.records().len(), 1);
    assert_eq!(inspection.issue(), Some(JournalTailIssue::TruncatedHeader));

    let mut journal = FileJournal::open_existing(&root, "prepared-torn.drj")?;
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    assert_eq!(
        journal.tail_issue(),
        Some(JournalTailIssue::TruncatedHeader)
    );
    let outcome = RenameRecovery::new(&mut backend, &mut journal).rollback();

    assert!(matches!(
        outcome,
        RecoveryOutcome::Recovered {
            restored_steps: 0,
            ..
        }
    ));
    assert_eq!(journal.tail_issue(), None);
    drop(journal);
    assert!(decode_journal_records(&fs::read(path)?).is_ok());
    Ok(())
}

#[test]
fn final_torn_completed_frame_reconciles_prepared_identity_before_rollback()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    let path = directory.path().join("completed-torn.drj");
    let mut records = prepared_fixture()?;
    records.push(JournalRecord::Completed {
        step: 0,
        direction: JournalDirection::Forward,
    });
    let mut bytes = encode_journal_records(&records)?;
    bytes.truncate(bytes.len() - 2);
    fs::write(&path, bytes)?;

    let mut journal = FileJournal::open_existing(&root, "completed-torn.drj")?;
    let mut backend = MemoryBackend::new().with_file("C:\\work\\b.txt", 1);
    let outcome = RenameRecovery::new(&mut backend, &mut journal).rollback();

    assert!(matches!(
        outcome,
        RecoveryOutcome::Recovered {
            restored_steps: 1,
            ..
        }
    ));
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    assert_eq!(backend.file_id("C:\\work\\b.txt"), None);
    drop(journal);
    assert!(decode_journal_records(&fs::read(path)?).is_ok());
    Ok(())
}

#[test]
fn journal_root_and_leaf_reject_relative_or_invalid_authority()
-> Result<(), Box<dyn std::error::Error>> {
    assert_eq!(
        JournalRoot::open("relative-root")
            .err()
            .map(|error| error.kind),
        Some(FileJournalErrorKind::RelativeRoot)
    );
    let directory = tempfile::tempdir()?;
    let Some(root) = supported_journal_root(directory.path())? else {
        return Ok(());
    };
    assert_eq!(
        FileJournal::create_new(&root, "../escape.drj")
            .err()
            .map(|error| error.kind),
        Some(FileJournalErrorKind::InvalidLeaf)
    );
    assert_eq!(
        FileJournal::create_new(&root, "nested\\escape.drj")
            .err()
            .map(|error| error.kind),
        Some(FileJournalErrorKind::InvalidLeaf)
    );
    Ok(())
}

#[cfg(unix)]
#[test]
fn journal_root_rejects_symlinked_root_intermediate_and_final_leaf()
-> Result<(), Box<dyn std::error::Error>> {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir()?;
    let target = directory.path().join("target");
    fs::create_dir(&target)?;
    let root_link = directory.path().join("root-link");
    symlink(&target, &root_link)?;
    assert_eq!(
        JournalRoot::open(&root_link).err().map(|error| error.kind),
        Some(FileJournalErrorKind::InvalidRoot)
    );

    let child = target.join("child");
    fs::create_dir(&child)?;
    assert_eq!(
        JournalRoot::open(root_link.join("child"))
            .err()
            .map(|error| error.kind),
        Some(FileJournalErrorKind::InvalidRoot)
    );

    let root = JournalRoot::open(&target)?;
    let actual = target.join("actual.drj");
    fs::write(&actual, [])?;
    symlink(&actual, target.join("linked.drj"))?;
    assert_eq!(
        FileJournal::open_existing(&root, "linked.drj")
            .err()
            .map(|error| error.kind),
        Some(FileJournalErrorKind::InvalidFileType)
    );
    Ok(())
}
