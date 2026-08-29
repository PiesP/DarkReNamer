use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

use dark_renamer_core::{
    CaseStyle, CaseTarget, Diagnostic, MAX_GENERATED_WIDTH, PlanningRequest, RenameRule, RowState,
    SequencePlacement, plan,
};

fn request(paths: &[&str], rules: Vec<RenameRule>) -> PlanningRequest {
    PlanningRequest::new(paths.iter().map(PathBuf::from)).with_rules(rules)
}

fn proposed(request: &PlanningRequest) -> Vec<OsString> {
    plan(request)
        .rows()
        .iter()
        .map(|row| row.proposed_name().to_os_string())
        .collect()
}

#[test]
fn applies_rules_in_order_without_implicitly_rewriting_the_extension() {
    let request = request(
        &["Report.TXT"],
        vec![
            RenameRule::LiteralReplace {
                from: "Report".into(),
                to: "Final".into(),
            },
            RenameRule::Prefix("draft-".into()),
            RenameRule::Suffix("-v2".into()),
            RenameRule::ReplaceExtension("md".into()),
            RenameRule::ConvertCase {
                style: CaseStyle::Lower,
                target: CaseTarget::Extension,
            },
        ],
    );

    assert_eq!(proposed(&request), [OsStr::new("draft-Final-v2.md")]);
}

#[test]
fn clear_stem_preserves_the_extension_and_remove_extension_preserves_the_stem() {
    let cleared = request(&["notes.txt"], vec![RenameRule::ClearStem]);
    let removed = request(&["notes.txt"], vec![RenameRule::RemoveExtension]);

    assert_eq!(proposed(&cleared), [OsStr::new(".txt")]);
    assert_eq!(proposed(&removed), [OsStr::new("notes")]);
}

#[test]
fn adding_an_extension_preserves_the_previous_extension_as_part_of_the_stem() {
    let request = request(
        &["archive.tar"],
        vec![RenameRule::AddExtension("bak".into())],
    );

    assert_eq!(proposed(&request), [OsStr::new("archive.tar.bak")]);
}

#[test]
fn removes_character_ranges_by_unicode_scalar_value_not_bytes() {
    let request = request(
        &["가😀나.txt"],
        vec![RenameRule::RemoveCharacterRange { start: 1, count: 1 }],
    );

    assert_eq!(proposed(&request), [OsStr::new("가나.txt")]);
}

#[test]
fn keeps_and_pads_ascii_digit_runs() {
    let request = request(
        &["ab7-c42.txt"],
        vec![
            RenameRule::KeepDigits,
            RenameRule::PadDigitRuns { width: 4 },
        ],
    );

    assert_eq!(proposed(&request), [OsStr::new("0742.txt")]);
}

#[test]
fn sequence_numbers_follow_input_order_and_requested_width() {
    let request = request(
        &["b.txt", "a.txt", "c.txt"],
        vec![RenameRule::Sequence {
            start: 8,
            step: 2,
            width: 3,
            separator: "-".into(),
            placement: SequencePlacement::Prefix,
        }],
    );

    assert_eq!(
        proposed(&request),
        [
            OsStr::new("008-b.txt"),
            OsStr::new("010-a.txt"),
            OsStr::new("012-c.txt"),
        ]
    );
}

#[test]
fn sequence_overflow_blocks_only_rows_that_cannot_be_numbered() {
    let request = request(
        &["a.txt", "b.txt"],
        vec![RenameRule::Sequence {
            start: u64::MAX,
            step: 1,
            width: 0,
            separator: "-".into(),
            placement: SequencePlacement::Prefix,
        }],
    );
    let plan = plan(&request);

    assert_eq!(plan.rows()[0].state(), RowState::Ready);
    assert!(matches!(
        plan.rows()[1].diagnostics(),
        [Diagnostic::SequenceOverflow { rule_index: 0 }]
    ));
}

#[test]
fn generated_width_is_bounded_before_allocation() {
    for rule in [
        RenameRule::PadDigitRuns { width: usize::MAX },
        RenameRule::Sequence {
            start: 1,
            step: 1,
            width: usize::MAX,
            separator: String::new(),
            placement: SequencePlacement::Suffix,
        },
    ] {
        let plan = plan(&request(&["a1.txt"], vec![rule]));
        assert!(matches!(
            plan.rows()[0].diagnostics(),
            [Diagnostic::GeneratedWidthTooLarge {
                width: usize::MAX,
                maximum: MAX_GENERATED_WIDTH,
                ..
            }]
        ));
    }
}

#[test]
fn case_conversion_is_unicode_aware_and_targeted() {
    let request = request(
        &["straße.TXT"],
        vec![RenameRule::ConvertCase {
            style: CaseStyle::Upper,
            target: CaseTarget::Stem,
        }],
    );

    assert_eq!(proposed(&request), [OsStr::new("STRASSE.TXT")]);
}

#[test]
fn blocks_windows_invalid_names_and_reserved_devices() {
    let cases = [
        ("ok.txt", RenameRule::ReplaceExtension("bad?".into())),
        (
            "ok.txt",
            RenameRule::LiteralReplace {
                from: "ok".into(),
                to: "CON".into(),
            },
        ),
        ("ok", RenameRule::Suffix(".".into())),
        ("x", RenameRule::ClearStem),
    ];

    for (path, rule) in cases {
        let plan = plan(&request(&[path], vec![rule]));
        assert_eq!(plan.rows()[0].state(), RowState::Blocked, "{path}");
        assert!(!plan.rows()[0].diagnostics().is_empty(), "{path}");
    }
}

#[test]
fn recognizes_the_complete_numbered_windows_device_name_families() {
    for device in [
        "con",
        "PRN.log",
        "aux ",
        "NUL.txt",
        "COM1",
        "com9.bin",
        "LPT1",
        "lpt9.data",
        "CONIN$",
        "conout$.txt",
        "COM¹.txt",
        "com²",
        "LPT³.data",
    ] {
        let plan = plan(&request(&[device], Vec::new()));
        assert!(
            plan.rows()[0]
                .diagnostics()
                .iter()
                .any(|diagnostic| matches!(diagnostic, Diagnostic::ReservedDeviceName { .. })),
            "{device}"
        );
    }

    for ordinary in ["COM0", "COM10", "LPT0", "LPT10", "console.txt"] {
        assert_eq!(
            plan(&request(&[ordinary], Vec::new())).rows()[0].state(),
            RowState::Unchanged,
            "{ordinary}"
        );
    }
}

#[test]
fn blocks_duplicate_targets_using_windows_case_insensitive_comparison() {
    let request = request(
        &["/work/a.txt", "/work/A.md"],
        vec![RenameRule::ReplaceExtension("txt".into())],
    );
    let plan = plan(&request);

    assert_eq!(plan.rows()[0].state(), RowState::Blocked);
    assert_eq!(plan.rows()[1].state(), RowState::Blocked);
    assert!(plan.rows().iter().all(|row| {
        row.diagnostics()
            .iter()
            .any(|diagnostic| matches!(diagnostic, Diagnostic::DuplicateTarget { .. }))
    }));
}

#[test]
fn windows_ordinal_uppercase_equivalents_collide() {
    let request = request(
        &["/work/Σ.md", "/work/ς.txt"],
        vec![RenameRule::ReplaceExtension("txt".into())],
    );
    let plan = plan(&request);

    assert!(
        plan.rows()
            .iter()
            .all(|row| row.state() == RowState::Blocked)
    );
}

#[test]
fn equal_filenames_in_distinct_directories_do_not_collide() {
    let plan = plan(&request(
        &["/one/report.txt", "/two/REPORT.txt"],
        Vec::new(),
    ));

    assert!(
        plan.rows()
            .iter()
            .all(|row| row.state() == RowState::Unchanged)
    );
}

#[test]
fn blocks_a_target_occupied_by_a_nonparticipant_sibling() {
    let request = request(
        &["/work/report.txt"],
        vec![RenameRule::ReplaceExtension("md".into())],
    )
    .with_occupied_paths([PathBuf::from("/work/REPORT.MD")]);
    let plan = plan(&request);

    assert_eq!(plan.rows()[0].state(), RowState::Blocked);
    assert!(matches!(
        plan.rows()[0].diagnostics(),
        [Diagnostic::OccupiedTarget { .. }]
    ));
}

#[test]
fn participant_swaps_are_eligible_for_later_staged_execution() {
    let request = request(
        &["/work/a.txt", "/work/b.txt"],
        vec![
            RenameRule::LiteralReplace {
                from: "a".into(),
                to: "__temporary__".into(),
            },
            RenameRule::LiteralReplace {
                from: "b".into(),
                to: "a".into(),
            },
            RenameRule::LiteralReplace {
                from: "__temporary__".into(),
                to: "b".into(),
            },
        ],
    )
    .with_occupied_paths([PathBuf::from("/work/a.txt"), PathBuf::from("/work/b.txt")]);
    let plan = plan(&request);

    assert!(plan.can_apply());
    assert_eq!(plan.changed_count(), 2);
    assert!(plan.rows().iter().all(|row| row.state() == RowState::Ready));
    assert_eq!(plan.rows()[0].target_path(), Path::new("/work/b.txt"));
    assert_eq!(plan.rows()[1].target_path(), Path::new("/work/a.txt"));
}

#[test]
fn an_empty_literal_search_is_a_structured_rule_diagnostic() {
    let plan = plan(&request(
        &["a.txt"],
        vec![RenameRule::LiteralReplace {
            from: String::new(),
            to: "x".into(),
        }],
    ));

    assert!(matches!(
        plan.rows()[0].diagnostics(),
        [Diagnostic::EmptyLiteralSearch { rule_index: 0 }]
    ));
}

#[cfg(unix)]
#[test]
fn preserves_non_unicode_os_names_and_blocks_text_transformation() {
    use std::os::unix::ffi::OsStringExt;

    let name = OsString::from_vec(vec![b'f', b'o', 0x80]);
    let source = PathBuf::from("/work").join(&name);
    let request =
        PlanningRequest::new([source.clone()]).with_rules([RenameRule::Prefix("new-".into())]);
    let plan = plan(&request);

    assert_eq!(plan.rows()[0].source_path(), source);
    assert_eq!(plan.rows()[0].original_name(), name);
    assert_eq!(plan.rows()[0].proposed_name(), name);
    assert!(matches!(
        plan.rows()[0].diagnostics(),
        [Diagnostic::NonUnicodeFileName]
    ));
}

#[cfg(unix)]
#[test]
fn compares_unicode_leaf_names_beneath_a_non_unicode_parent() {
    use std::os::unix::ffi::OsStringExt;

    let parent = PathBuf::from(OsString::from_vec(vec![b'w', 0x80]));
    let request = PlanningRequest::new([parent.join("a.md"), parent.join("A.txt")])
        .with_rules([RenameRule::ReplaceExtension("txt".into())]);
    let plan = plan(&request);

    assert!(
        plan.rows()
            .iter()
            .all(|row| row.state() == RowState::Blocked)
    );
}
