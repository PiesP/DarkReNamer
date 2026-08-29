use std::fs;

use darknamer_app::rename::{
    EntryId, EntryIdentity, FileJournal, JournalCodecErrorKind, JournalDirection, JournalRecord,
    JournalStep, JournalStore, JournalTerminal, MAX_JOURNAL_FRAME_BYTES, MAX_JOURNAL_STEPS,
    MAX_PATH_UNITS, PlanId, TemporaryPhase, decode_journal_records, encode_journal_records,
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
    let records = complete_records();
    let JournalRecord::Intent { plan, steps } = &records[0] else {
        return Err(std::io::Error::other("fixture intent missing").into());
    };
    {
        let mut journal = FileJournal::create_new(&path)?;
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
    let resumed = FileJournal::open_existing(&path)?;
    assert_eq!(resumed.records(), records);
    assert_eq!(decode_journal_records(&fs::read(path)?)?, records);
    Ok(())
}

#[cfg(unix)]
#[test]
fn retained_linux_validation_handle_is_not_substituted_by_path_replacement()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let path = directory.path().join("transaction.drj");
    let moved = directory.path().join("retained.drj");
    let records = complete_records();
    let JournalRecord::Intent { plan, steps } = &records[0] else {
        return Err(std::io::Error::other("fixture intent missing").into());
    };
    let mut journal = FileJournal::create_new(&path)?;
    journal.begin(*plan, steps)?;
    fs::rename(&path, &moved)?;
    fs::write(&path, [])?;

    journal.prepared(0, JournalDirection::Forward)?;

    assert_eq!(decode_journal_records(&fs::read(moved)?)?.len(), 2);
    assert!(fs::read(path)?.is_empty());
    Ok(())
}
