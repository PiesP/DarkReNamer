use darknamer_app::rename::{
    EntryId, EntryIdentity, EntryKind, JournalDirection, JournalRecord, JournalStep,
    JournalTerminal, MoveScope, PlanId, TemporaryPhase, decode_journal_records,
    encode_journal_records, inspect_journal_records,
};
use darknamer_core::LegacyText;

// A bounded corpus of legal histories, independent of the replay implementation.
// Every primitive count includes commit, cancellation at each completed prefix,
// failed forward operations, and a failed rollback followed by a successful retry.
fn histories() -> Vec<Vec<JournalRecord>> {
    let mut corpus = Vec::new();
    for count in 0_u32..=4 {
        let steps = (0..count)
            .map(|entry| {
                let cross_parent = entry % 2 != 0;
                let phase = match entry % 3 {
                    0 => TemporaryPhase::None,
                    1 => TemporaryPhase::IntoTemporary,
                    _ => TemporaryPhase::FromTemporary,
                };
                JournalStep::new(
                    EntryId::new(entry),
                    LegacyText::from_units(vec![0, 0xd800, 0x0061, 0xdc00, 0xffff]),
                    LegacyText::from_units(vec![0xd83d, 0xde00, 0xac00, 0x0062]),
                    EntryIdentity::new(7, u128::MAX - u128::from(entry)),
                    EntryIdentity::new(7, 1),
                    EntryIdentity::new(7, if cross_parent { 2 } else { 1 }),
                    phase,
                )
                .with_move_authorization(
                    EntryKind::File,
                    if cross_parent {
                        MoveScope::SameVolumeFilesOnly
                    } else {
                        MoveScope::SameParent
                    },
                )
            })
            .collect::<Vec<_>>();
        let intent = JournalRecord::Intent {
            plan: PlanId::from_fingerprint(u64::MAX - u64::from(count)),
            steps: steps.into_boxed_slice(),
        };
        let mut committed = vec![intent.clone()];
        for step in 0..count as usize {
            completed_step(&mut committed, step, JournalDirection::Forward);
        }
        committed.push(JournalRecord::Terminal(JournalTerminal::Committed));
        corpus.push(committed);

        for completed in 0..=count as usize {
            for failed_forward in [false, true] {
                if failed_forward && completed == count as usize {
                    continue;
                }
                for retry in [false, true] {
                    let mut rollback = vec![intent.clone()];
                    for step in 0..completed {
                        completed_step(&mut rollback, step, JournalDirection::Forward);
                    }
                    if failed_forward {
                        rollback.push(JournalRecord::Prepared {
                            step: completed,
                            direction: JournalDirection::Forward,
                        });
                        rollback.push(JournalRecord::NotApplied {
                            step: completed,
                            direction: JournalDirection::Forward,
                        });
                    }
                    for step in (0..completed).rev() {
                        if retry {
                            rollback.push(JournalRecord::Prepared {
                                step,
                                direction: JournalDirection::Rollback,
                            });
                            rollback.push(JournalRecord::NotApplied {
                                step,
                                direction: JournalDirection::Rollback,
                            });
                        }
                        completed_step(&mut rollback, step, JournalDirection::Rollback);
                    }
                    rollback.push(JournalRecord::Terminal(JournalTerminal::RolledBack));
                    corpus.push(rollback);
                }
            }
        }
    }
    corpus
}

fn completed_step(records: &mut Vec<JournalRecord>, step: usize, direction: JournalDirection) {
    records.push(JournalRecord::Prepared { step, direction });
    records.push(JournalRecord::Completed { step, direction });
}

#[test]
fn generated_histories_preserve_exact_records_and_every_torn_prefix()
-> Result<(), Box<dyn std::error::Error>> {
    for (case, records) in histories().iter().enumerate() {
        let encoded = encode_journal_records(records)?;
        assert_eq!(decode_journal_records(&encoded)?, *records, "case {case}");
        let boundaries = (0..=records.len())
            .map(|length| encode_journal_records(&records[..length]).map(|bytes| bytes.len()))
            .collect::<Result<Vec<_>, _>>()?;
        for cut in 0..=encoded.len() {
            let complete = boundaries.partition_point(|boundary| *boundary <= cut) - 1;
            let on_boundary = boundaries[complete] == cut;
            let prefix = &encoded[..cut];
            if complete == 0 && !on_boundary {
                assert!(
                    inspect_journal_records(prefix).is_err(),
                    "case {case}, cut {cut}"
                );
            } else {
                let inspection = inspect_journal_records(prefix)?;
                assert_eq!(
                    inspection.records(),
                    &records[..complete],
                    "case {case}, cut {cut}"
                );
                assert_eq!(inspection.valid_bytes(), boundaries[complete]);
                assert_eq!(inspection.issue().is_none(), on_boundary);
            }
            if on_boundary {
                assert_eq!(decode_journal_records(prefix)?, records[..complete]);
            } else {
                assert!(
                    decode_journal_records(prefix).is_err(),
                    "case {case}, cut {cut}"
                );
            }
        }
    }
    Ok(())
}

#[test]
fn generated_histories_reject_each_single_bit_corruption() -> Result<(), Box<dyn std::error::Error>>
{
    for (case, records) in histories().iter().enumerate() {
        let mut bytes = encode_journal_records(records)?;
        for offset in 0..bytes.len() {
            for bit in 0..8 {
                bytes[offset] ^= 1 << bit;
                assert!(
                    decode_journal_records(&bytes).is_err(),
                    "case {case}, offset {offset}, bit {bit} accepted corrupted authority"
                );
                bytes[offset] ^= 1 << bit;
            }
        }
    }
    Ok(())
}

#[test]
fn generated_histories_reject_duplicate_records_even_with_valid_checksums()
-> Result<(), Box<dyn std::error::Error>> {
    for (case, records) in histories().iter().enumerate() {
        for index in 0..records.len() {
            let mut duplicate = records.clone();
            duplicate.insert(index, records[index].clone());
            let encoded = encode_journal_records(&duplicate)?;
            assert!(
                inspect_journal_records(&encoded).is_err(),
                "case {case}, duplicate record {index} accepted invalid journal order"
            );
        }
    }
    Ok(())
}
