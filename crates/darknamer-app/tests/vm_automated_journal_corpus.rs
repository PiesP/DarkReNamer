use std::fmt::Write as _;

use darknamer_app::rename::{
    EntryId, EntryIdentity, EntryKind, JournalDirection, JournalRecord, JournalStep,
    JournalTerminal, MoveScope, PlanId, TemporaryPhase, decode_journal_records,
    encode_journal_records,
};
use darknamer_core::LegacyText;

const CORPUS_PREFIX: &str = "DARKRENAMER_VM_JOURNAL_CORPUS";

struct StepSpec {
    entry: u32,
    source: Vec<u16>,
    destination: Vec<u16>,
    identity: EntryIdentity,
    source_parent: EntryIdentity,
    destination_parent: EntryIdentity,
    kind: EntryKind,
    scope: MoveScope,
    phase: TemporaryPhase,
}

fn step(spec: StepSpec) -> JournalStep {
    JournalStep::new(
        EntryId::new(spec.entry),
        LegacyText::from_units(spec.source),
        LegacyText::from_units(spec.destination),
        spec.identity,
        spec.source_parent,
        spec.destination_parent,
        spec.phase,
    )
    .with_move_authorization(spec.kind, spec.scope)
}

fn direct_step(entry: u32) -> JournalStep {
    step(StepSpec {
        entry,
        source: format!(r"C:\fixture\source-{entry}.txt")
            .encode_utf16()
            .collect(),
        destination: format!(r"C:\fixture\destination-{entry}.txt")
            .encode_utf16()
            .collect(),
        identity: EntryIdentity::new(0x0123_4567_89ab_cdef, u128::from(entry) + 0x100),
        source_parent: EntryIdentity::new(0x0123_4567_89ab_cdef, 0x10),
        destination_parent: EntryIdentity::new(0x0123_4567_89ab_cdef, 0x10),
        kind: EntryKind::File,
        scope: MoveScope::SameParent,
        phase: TemporaryPhase::None,
    })
}

fn emit_case(name: &str, records: &[JournalRecord]) -> Result<(), Box<dyn std::error::Error>> {
    let encoded = encode_journal_records(records)?;
    assert_eq!(decode_journal_records(&encoded)?, records);
    let mut hex = String::with_capacity(encoded.len() * 2);
    for byte in encoded {
        write!(&mut hex, "{byte:02x}")?;
    }
    println!("{CORPUS_PREFIX}\t{name}\t{hex}");
    Ok(())
}

#[test]
fn emit_python_oracle_corpus() -> Result<(), Box<dyn std::error::Error>> {
    let extreme_intent = JournalRecord::Intent {
        plan: PlanId::from_fingerprint(u64::MAX),
        steps: vec![
            step(StepSpec {
                entry: 0,
                source: vec![0, 0xd800, 0x0061, 0xdc00, 0xffff],
                destination: vec![0xd83d, 0xde00, 0xac00, 0x0062],
                identity: EntryIdentity::new(u64::MAX, u128::MAX),
                source_parent: EntryIdentity::new(7, 1),
                destination_parent: EntryIdentity::new(7, 1),
                kind: EntryKind::File,
                scope: MoveScope::SameParent,
                phase: TemporaryPhase::None,
            }),
            step(StepSpec {
                entry: u32::MAX,
                source: r"C:\source\directory".encode_utf16().collect(),
                destination: r"C:\target\directory".encode_utf16().collect(),
                identity: EntryIdentity::new(9, 1 << 127),
                source_parent: EntryIdentity::new(9, 0x11),
                destination_parent: EntryIdentity::new(9, 0x22),
                kind: EntryKind::Directory,
                scope: MoveScope::SameVolumeFilesOnly,
                phase: TemporaryPhase::FromTemporary,
            }),
        ]
        .into_boxed_slice(),
    };
    emit_case("intent-extremes", std::slice::from_ref(&extreme_intent))?;

    let prepared = vec![
        JournalRecord::Intent {
            plan: PlanId::from_fingerprint(0x1111),
            steps: vec![direct_step(0), direct_step(1), direct_step(2)].into_boxed_slice(),
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
        JournalRecord::Completed {
            step: 1,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Prepared {
            step: 2,
            direction: JournalDirection::Forward,
        },
    ];
    emit_case("prepared-prefix", &prepared)?;

    let rollback_prepared = vec![
        JournalRecord::Intent {
            plan: PlanId::from_fingerprint(0x1212),
            steps: vec![direct_step(0), direct_step(1), direct_step(2)].into_boxed_slice(),
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
        JournalRecord::Completed {
            step: 1,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Prepared {
            step: 2,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Completed {
            step: 2,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Prepared {
            step: 2,
            direction: JournalDirection::Rollback,
        },
        JournalRecord::Completed {
            step: 2,
            direction: JournalDirection::Rollback,
        },
        JournalRecord::Prepared {
            step: 1,
            direction: JournalDirection::Rollback,
        },
    ];
    emit_case("rollback-prepared", &rollback_prepared)?;

    let committed = vec![
        JournalRecord::Intent {
            plan: PlanId::from_fingerprint(0x2222),
            steps: vec![direct_step(0), direct_step(1)].into_boxed_slice(),
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
        JournalRecord::Completed {
            step: 1,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Terminal(JournalTerminal::Committed),
    ];
    emit_case("committed", &committed)?;

    let rollback_retry = vec![
        JournalRecord::Intent {
            plan: PlanId::from_fingerprint(0x3333),
            steps: vec![direct_step(0), direct_step(1)].into_boxed_slice(),
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
        JournalRecord::Completed {
            step: 1,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Prepared {
            step: 1,
            direction: JournalDirection::Rollback,
        },
        JournalRecord::NotApplied {
            step: 1,
            direction: JournalDirection::Rollback,
        },
        JournalRecord::Prepared {
            step: 1,
            direction: JournalDirection::Rollback,
        },
        JournalRecord::Completed {
            step: 1,
            direction: JournalDirection::Rollback,
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
    ];
    emit_case("rollback-retry", &rollback_retry)?;
    Ok(())
}
