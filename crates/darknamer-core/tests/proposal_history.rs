use darknamer_core::{
    LegacyList, LegacyListItem, LegacySortMode, LegacyText, MAX_PROPOSAL_HISTORY_BYTES,
    ProposalHistory, ProposalSnapshotError,
};

fn list(paths: &[&str]) -> LegacyList {
    let mut result = LegacyList::new();
    for path in paths {
        assert_eq!(
            result.append(LegacyListItem::new(*path, false, 0, 0, 0)),
            Ok(true)
        );
    }
    result
}

fn record_name_change(
    model: &mut LegacyList,
    history: &mut ProposalHistory,
    row: usize,
    value: LegacyText,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut before = history.prepare_edit(model)?;
    assert_eq!(model.manual_change_changed(row, value), Ok(true));
    model.reserve_proposals_after_mutation(&mut before)?;
    history.record_edit(model, before);
    Ok(())
}

#[test]
fn exact_utf16_and_destination_changes_round_trip_in_order()
-> Result<(), Box<dyn std::error::Error>> {
    let mut model = list(&[r"C:\src\b.txt", r"C:\src\a.txt"]);
    let mut history = ProposalHistory::new();
    let raw = LegacyText::from_units(vec![
        0xD800,
        b'.' as u16,
        b't' as u16,
        b'x' as u16,
        b't' as u16,
    ]);
    record_name_change(&mut model, &mut history, 0, raw.clone())?;
    let mut before = history.prepare_edit(&model)?;
    assert_eq!(
        model.unify_destination_parent_changed(&LegacyText::from(r"C:\dest")),
        Ok(vec![0, 1].into_boxed_slice())
    );
    model.reserve_proposals_after_mutation(&mut before)?;
    history.record_edit(&model, before);
    assert_eq!(model.items()[0].proposed_name(), &raw);
    assert_eq!(
        model.items()[1].destination_parent(),
        &LegacyText::from(r"C:\dest")
    );

    let (rows, parent_changed) = history.undo(&mut model)?.ok_or("missing Undo step")?;
    assert_eq!(&*rows, &[0, 1]);
    assert!(parent_changed);
    assert_eq!(
        model.items()[0].destination_parent(),
        &LegacyText::from(r"C:\src")
    );
    assert_eq!(model.items()[0].proposed_name(), &raw);
    let (rows, parent_changed) = history.undo(&mut model)?.ok_or("missing Undo step")?;
    assert_eq!(&*rows, &[0]);
    assert!(!parent_changed);
    assert_eq!(model.items()[0].proposed_name(), &LegacyText::from("b.txt"));
    assert_eq!(
        model.proposed_name_utf16_units(),
        "b.txt".len() + "a.txt".len()
    );
    assert!(history.redo(&mut model)?.is_some());
    assert!(history.redo(&mut model)?.is_some());
    assert_eq!(model.items()[0].proposed_name(), &raw);
    assert_eq!(
        model.items()[1].destination_parent(),
        &LegacyText::from(r"C:\dest")
    );
    assert!(history.redo(&mut model)?.is_none());
    Ok(())
}

#[test]
fn new_edit_retires_redo_and_rejected_edit_keeps_history() -> Result<(), Box<dyn std::error::Error>>
{
    let mut model = list(&[r"C:\src\a.txt"]);
    let mut history = ProposalHistory::new();
    record_name_change(&mut model, &mut history, 0, LegacyText::from("first.txt"))?;
    record_name_change(&mut model, &mut history, 0, LegacyText::from("second.txt"))?;
    assert!(history.undo(&mut model)?.is_some());
    assert!(history.can_redo(&model));
    let before = history.prepare_edit(&model)?;
    let oversized = LegacyText::from_units(vec![b'x' as u16; 256]);
    assert!(model.manual_change_changed(0, oversized).is_err());
    drop(before);
    assert_eq!(
        model.items()[0].proposed_name(),
        &LegacyText::from("first.txt")
    );
    assert!(history.can_redo(&model));
    record_name_change(&mut model, &mut history, 0, LegacyText::from("third.txt"))?;
    assert!(!history.can_redo(&model));
    assert!(history.undo(&mut model)?.is_some());
    assert_eq!(
        model.items()[0].proposed_name(),
        &LegacyText::from("first.txt")
    );
    Ok(())
}

#[test]
fn source_change_and_reordering_invalidate_old_rows() -> Result<(), Box<dyn std::error::Error>> {
    let mut model = list(&[r"C:\src\b.txt", r"C:\src\a.txt"]);
    let mut history = ProposalHistory::new();
    record_name_change(&mut model, &mut history, 0, LegacyText::from("edited.txt"))?;
    assert!(model.sort_by_with_semantics_changed(
        LegacySortMode::NameAscending,
        darknamer_core::SortSemantics::LegacyDarkNamer080210,
        LegacyText::case_insensitive_cmp,
    ));
    assert!(!history.can_undo(&model));
    assert!(matches!(
        history.undo(&mut model),
        Err(ProposalSnapshotError::StaleSources)
    ));
    assert_eq!(
        model.items()[1].proposed_name(),
        &LegacyText::from("edited.txt")
    );
    record_name_change(&mut model, &mut history, 0, LegacyText::from("new.txt"))?;
    assert!(model.move_rows_later_changed(&[0]).changed());
    assert!(!history.can_undo(&model));
    history.discard_if_stale(&model);
    assert_eq!(history.reserved_bytes(), 0);
    record_name_change(&mut model, &mut history, 0, LegacyText::from("newer.txt"))?;
    assert_eq!(model.remove_rows(&[0]), 1);
    assert!(!history.can_undo(&model));
    Ok(())
}

#[test]
fn bounded_count_and_bytes_retire_oldest_edits() -> Result<(), Box<dyn std::error::Error>> {
    let mut model = list(&[r"C:\src\a.txt"]);
    let mut history = ProposalHistory::new();
    for number in 0..20 {
        record_name_change(
            &mut model,
            &mut history,
            0,
            LegacyText::from(format!("{number:02}.txt")),
        )?;
        assert!(history.reserved_bytes() <= MAX_PROPOSAL_HISTORY_BYTES);
    }
    for _ in 0..16 {
        assert!(history.undo(&mut model)?.is_some());
    }
    assert!(history.undo(&mut model)?.is_none());
    assert_eq!(
        model.items()[0].proposed_name(),
        &LegacyText::from("03.txt")
    );
    Ok(())
}

#[test]
fn byte_budget_retires_oldest_large_proposal_snapshots() -> Result<(), Box<dyn std::error::Error>> {
    let mut model = LegacyList::new();
    let long = "x".repeat(170);
    let rows = (0..4_000)
        .map(|row| LegacyListItem::new(format!(r"C:\s\{row:04}_{long}.txt"), false, 0, 0, 0));
    assert_eq!(model.append_batch(rows), Ok(4_000));
    let mut history = ProposalHistory::new();
    for step in 0..6 {
        record_name_change(
            &mut model,
            &mut history,
            0,
            LegacyText::from(format!("edited_{step:02}.txt")),
        )?;
        assert!(history.reserved_bytes() <= MAX_PROPOSAL_HISTORY_BYTES);
    }
    let mut steps = 0;
    while history.undo(&mut model)?.is_some() {
        steps += 1;
    }
    assert!(
        steps > 0 && steps < 6,
        "byte budget must retire some old edits"
    );
    Ok(())
}

#[test]
fn sequence_batch_restores_ordered_names_and_cached_path_totals()
-> Result<(), Box<dyn std::error::Error>> {
    let mut model = list(&[r"C:\src\a.txt", r"C:\src\b.txt", r"C:\src\c.txt"]);
    let originals = model
        .items()
        .iter()
        .map(|item| item.proposed_name().clone())
        .collect::<Vec<_>>();
    let original_planned = model.planned_path_utf16_units();
    let mut history = ProposalHistory::new();
    let mut before = history.prepare_edit(&model)?;
    assert_eq!(
        model
            .add_sequence_changed(3, 7, darknamer_core::LegacySequenceMode::Append)?
            .len(),
        3
    );
    model.reserve_proposals_after_mutation(&mut before)?;
    history.record_edit(&model, before);
    let numbered = model
        .items()
        .iter()
        .map(|item| item.proposed_name().clone())
        .collect::<Vec<_>>();
    let numbered_planned = model.planned_path_utf16_units();
    assert_ne!(numbered, originals);
    assert_ne!(numbered[0], numbered[1]);
    assert_eq!(
        history
            .undo(&mut model)?
            .ok_or("missing Undo step")?
            .0
            .len(),
        3
    );
    assert_eq!(
        model
            .items()
            .iter()
            .map(|item| item.proposed_name().clone())
            .collect::<Vec<_>>(),
        originals
    );
    assert_eq!(model.planned_path_utf16_units(), original_planned);
    assert_eq!(
        history
            .redo(&mut model)?
            .ok_or("missing Redo step")?
            .0
            .len(),
        3
    );
    assert_eq!(
        model
            .items()
            .iter()
            .map(|item| item.proposed_name().clone())
            .collect::<Vec<_>>(),
        numbered
    );
    assert_eq!(model.planned_path_utf16_units(), numbered_planned);
    Ok(())
}
