//! Golden behavior from `DarkNamerDlg.cpp`: `FileListAdd`, `InitList`,
//! `NameReplace`, `NameAddFront`, `NameAddRear`, `NameNumberOnly`, `NameDigit`,
//! `NameAddNum`, `NameEmpty`, `NameDelPos`, `NameDelToken`, the `Ext*` commands,
//! `NameAddPath*`, `NameSamePath`, `SortList`/`Compare`, and import/export.

use dark_renamer_legacy::{
    LegacyInputError, LegacyList, LegacyListItem, LegacySequenceMode, LegacySortMode, LegacyText,
    parse_import_lines,
};

fn item(path: &str, is_directory: bool) -> LegacyListItem {
    LegacyListItem::new(path, is_directory, 0, 0, 0)
}

fn item_with_metadata(path: &str, size: u32, created: u64, modified: u64) -> LegacyListItem {
    LegacyListItem::new(path, false, size, created, modified)
}

fn list(paths: &[(&str, bool)]) -> LegacyList {
    let mut list = LegacyList::new();
    for (path, is_directory) in paths {
        assert!(list.append(item(path, *is_directory)));
    }
    list
}

fn proposed(list: &LegacyList) -> Vec<String> {
    list.items()
        .iter()
        .map(|item| item.proposed_name().to_string_lossy())
        .collect()
}

fn current(list: &LegacyList) -> Vec<String> {
    list.items()
        .iter()
        .map(|item| item.current_name().to_string_lossy())
        .collect()
}

#[test]
fn file_list_add_skips_existing_duplicates_but_keeps_same_batch_duplicates() {
    let mut list = LegacyList::new();
    assert!(list.append(item(r"C:\Alpha\a.txt", false)));
    assert_eq!(
        list.append_batch([
            item(r"c:\alpha\A.TXT", false),
            item(r"C:\Zeta\b.txt", false),
            item(r"c:\zeta\B.TXT", false),
        ]),
        2
    );

    assert_eq!(current(&list), ["a.txt", "B.TXT", "b.txt"]);
    assert_eq!(list.items()[0].root_path().to_string_lossy(), r"C:\Alpha");
    assert_eq!(
        list.items()[1].source_path().to_string_lossy(),
        r"c:\zeta\B.TXT"
    );
}

#[test]
fn stem_commands_discard_manual_path_prefix_like_get_name() {
    let mut list = list(&[(r"C:\root\source.txt", false)]);
    assert!(list.manual_change(0, r"subdir\manual.name.txt"));
    list.suffix_before_extension(&LegacyText::from("-tail"));
    assert_eq!(proposed(&list), ["manual.name-tail.txt"]);

    assert!(list.manual_change(0, r"subdir\manual.name.txt"));
    list.clear_name();
    assert_eq!(proposed(&list), [".txt"]);

    assert!(list.manual_change(0, r"subdir\manual.name.txt"));
    list.replace_extension(&LegacyText::from("new"));
    assert_eq!(proposed(&list), ["manual.name.new"]);
}

#[test]
fn complete_replace_prefix_and_pre_extension_suffix_match_name_commands() {
    let mut list = list(&[
        (r"C:\root\archive.tar.gz", false),
        (r"C:\root\.env", false),
        (r"C:\root\README", false),
        (r"C:\root\folder.name", true),
    ]);

    list.replace_complete(&LegacyText::from("."), &LegacyText::from("_"));
    list.prefix_complete(&LegacyText::from("pre-"));
    assert_eq!(
        proposed(&list),
        [
            "pre-archive_tar_gz",
            "pre-_env",
            "pre-README",
            "pre-folder_name",
        ]
    );

    list.reset_proposals();
    list.suffix_before_extension(&LegacyText::from("-tail"));
    assert_eq!(
        proposed(&list),
        [
            "archive.tar-tail.gz",
            "-tail.env",
            "README-tail",
            "folder.name-tail",
        ]
    );
}

#[test]
fn name_empty_and_position_delete_preserve_last_dot_extension_rules() {
    let mut list = list(&[
        (r"C:\root\archive.tar.gz", false),
        (r"C:\root\.env", false),
        (r"C:\root\README", false),
        (r"C:\root\folder.name", true),
    ]);

    list.clear_name();
    assert_eq!(proposed(&list), [".gz", ".env", "", ""]);

    list.reset_proposals();
    assert_eq!(list.delete_front_range(2, 4), Ok(()));
    assert_eq!(proposed(&list), ["aive.tar.gz", ".env", "RME", "fer.name"]);

    list.reset_proposals();
    list.delete_last(3);
    assert_eq!(proposed(&list), ["archive..gz", ".env", "REA", "folder.n"]);
    let before = proposed(&list);
    assert_eq!(list.delete_front_range(0, 0), Ok(()));
    assert_eq!(proposed(&list), before);
    assert_eq!(
        list.delete_front_range(4, 2),
        Err(LegacyInputError::ReversedPositionRange)
    );
}

#[test]
fn cstring_position_deletion_can_split_a_non_bmp_surrogate_pair() {
    let mut list = list(&[(r"C:\root\unicode.txt", false)]);
    assert!(list.manual_change(0, LegacyText::from("A😀BC.txt")));

    assert_eq!(list.delete_front_range(2, 2), Ok(()));

    let expected = [
        b'A' as u16,
        0xDE00,
        b'B' as u16,
        b'C' as u16,
        b'.' as u16,
        b't' as u16,
        b'x' as u16,
        b't' as u16,
    ];
    assert_eq!(list.items()[0].proposed_name().units(), expected);
}

#[test]
fn name_del_token_removes_only_the_first_inclusive_pair() {
    let mut list = list(&[(r"C:\root\a[first]b[second]c.txt", false)]);

    assert_eq!(
        list.delete_first_delimited(&LegacyText::from("[ignored"), &LegacyText::from("]ignored")),
        Ok(())
    );

    assert_eq!(proposed(&list), ["ab[second]c.txt"]);
    assert_eq!(
        list.delete_first_delimited(&LegacyText::default(), &LegacyText::from("]")),
        Err(LegacyInputError::EmptyDelimiter)
    );
}

#[test]
fn number_only_and_first_last_digit_padding_preserve_source_scan_quirks() {
    let mut digits_only = list(&[(r"C:\root\a1b23c.txt", false), (r"C:\root\.123", false)]);
    digits_only.keep_ascii_digits();
    assert_eq!(proposed(&digits_only), ["123.txt", ".123"]);

    let mut last = list(&[(r"C:\root\a1b23c.txt", false), (r"C:\root\123.txt", false)]);
    assert_eq!(last.pad_last_digit_run(4), Ok(()));
    assert_eq!(proposed(&last), ["a1b0023c.txt", "0123.txt"]);

    let mut first = list(&[
        (r"C:\root\a1b23c.txt", false),
        (r"C:\root\a1b23.txt", false),
        (r"C:\root\123.txt", false),
    ]);
    assert_eq!(first.pad_first_digit_run(3), Ok(()));
    assert_eq!(proposed(&first), ["a001b23c.txt", "a001b23.txt", "123.txt"]);
    assert_eq!(
        first.pad_first_digit_run(0),
        Err(LegacyInputError::NonPositiveWidth)
    );
}

#[test]
fn all_four_sequence_modes_use_no_separator_and_folder_modes_restart() {
    let paths = [
        (r"C:\one\a.txt", false),
        (r"c:\ONE\b.txt", false),
        (r"C:\two\c.txt", false),
    ];

    let mut append = list(&paths);
    assert_eq!(
        append.add_sequence(2, 1, LegacySequenceMode::Append),
        Ok(())
    );
    assert_eq!(proposed(&append), ["a01.txt", "b02.txt", "c03.txt"]);

    let mut prepend = list(&paths);
    assert_eq!(
        prepend.add_sequence(2, 1, LegacySequenceMode::Prepend),
        Ok(())
    );
    assert_eq!(proposed(&prepend), ["01a.txt", "02b.txt", "03c.txt"]);

    let mut append_folder = list(&paths);
    assert_eq!(
        append_folder.add_sequence(2, 1, LegacySequenceMode::AppendRestartPerFolder),
        Ok(())
    );
    assert_eq!(proposed(&append_folder), ["a01.txt", "b02.txt", "c01.txt"]);

    let mut prepend_folder = list(&paths);
    assert_eq!(
        prepend_folder.add_sequence(2, -5, LegacySequenceMode::PrependRestartPerFolder),
        Ok(())
    );
    assert_eq!(proposed(&prepend_folder), ["00a.txt", "01b.txt", "00c.txt"]);
}

#[test]
fn extension_commands_reproduce_dotfile_directory_and_dot_normalization_rules() {
    let paths = [
        (r"C:\root\archive.tar.gz", false),
        (r"C:\root\.env", false),
        (r"C:\root\README", false),
        (r"C:\root\folder.name", true),
    ];

    let mut deleted = list(&paths);
    deleted.delete_extension();
    assert_eq!(
        proposed(&deleted),
        ["archive.tar", "", "README", "folder.name"]
    );

    let mut added = list(&paths);
    added.add_extension(&LegacyText::from("bak"));
    assert_eq!(
        proposed(&added),
        [
            "archive.tar.gz.bak",
            ".env.bak",
            "README.bak",
            "folder.name.bak"
        ]
    );

    let mut replaced = list(&paths);
    replaced.replace_extension(&LegacyText::from(".new"));
    assert_eq!(
        proposed(&replaced),
        ["archive.tar.new", ".new", "README.new", "folder.name.new"]
    );
}

#[test]
fn parent_folder_commands_and_root_unification_match_root_column_behavior() {
    let mut prefixed = list(&[
        (r"C:\parent\file.ext", false),
        (r"C:\drive-root.txt", false),
        (r"C:\parent\folder.name", true),
    ]);
    prefixed.prefix_parent_folder();
    assert_eq!(
        proposed(&prefixed),
        ["parent_file.ext", "drive-root.txt", "parent_folder.name"]
    );

    prefixed.reset_proposals();
    prefixed.suffix_parent_folder();
    assert_eq!(
        proposed(&prefixed),
        ["file_parent.ext", "drive-root.txt", "folder.name_parent"]
    );

    prefixed.unify_root_path(&LegacyText::from(r"D:\target\"));
    assert!(
        prefixed
            .items()
            .iter()
            .all(|item| item.root_path() == &LegacyText::from(r"D:\target"))
    );
}

#[test]
fn selected_row_movement_remove_manual_change_and_ctrl_z_are_list_state_only() {
    let mut list = list(&[
        (r"C:\root\a.txt", false),
        (r"C:\root\b.txt", false),
        (r"C:\root\c.txt", false),
        (r"C:\root\d.txt", false),
    ]);

    assert_eq!(&*list.move_rows_earlier(&[1, 2]), [0, 1]);
    assert_eq!(current(&list), ["b.txt", "c.txt", "a.txt", "d.txt"]);
    assert_eq!(&*list.move_rows_later(&[0, 1]), [1, 2]);
    assert_eq!(current(&list), ["a.txt", "b.txt", "c.txt", "d.txt"]);

    let before = current(&list);
    assert_eq!(&*list.move_rows_earlier(&[0, 2]), [0, 2]);
    assert_eq!(current(&list), before);
    assert_eq!(&*list.move_rows_later(&[1, 3]), [1, 3]);
    assert_eq!(current(&list), before);

    assert!(list.manual_change(1, "manual.name"));
    assert!(!list.manual_change(99, "ignored"));
    list.prefix_complete(&LegacyText::from("x-"));
    list.reset_proposals();
    assert_eq!(proposed(&list), current(&list));

    assert_eq!(list.remove_rows(&[1, 3, 3, 99]), 2);
    assert_eq!(current(&list), ["a.txt", "c.txt"]);
}

#[test]
fn successful_move_record_updates_only_that_row_for_partial_success() {
    let mut list = list(&[(r"C:\one\a.txt", false), (r"C:\two\b.txt", false)]);
    list.prefix_complete(&LegacyText::from("new-"));
    assert!(list.record_move_success(0));

    assert_eq!(
        list.items()[0].source_path(),
        &LegacyText::from(r"C:\one\new-a.txt")
    );
    assert_eq!(
        list.items()[0].current_name(),
        &LegacyText::from("new-a.txt")
    );
    assert_eq!(
        list.items()[0].proposed_name(),
        &LegacyText::from("new-a.txt")
    );
    assert_eq!(list.items()[0].root_path(), &LegacyText::from(r"C:\one"));
    assert_eq!(list.items()[1].current_name(), &LegacyText::from("b.txt"));
    assert_eq!(
        list.items()[1].proposed_name(),
        &LegacyText::from("new-b.txt")
    );
    assert_eq!(
        list.items()[1].planned_path(),
        LegacyText::from(r"C:\two\new-b.txt")
    );
    assert!(!list.record_move_success(99));
}

#[test]
fn all_ten_sort_modes_use_original_metadata_not_proposals() {
    let make_list = || {
        let mut list = LegacyList::new();
        assert!(list.append(item_with_metadata(r"C:\root\b.txt", 20, 3, 2)));
        assert!(list.append(item_with_metadata(r"C:\root\a.txt", 30, 1, 3)));
        assert!(list.append(item_with_metadata(r"C:\root\c.txt", 10, 2, 1)));
        list
    };
    let cases = [
        (LegacySortMode::NameAscending, ["a.txt", "b.txt", "c.txt"]),
        (LegacySortMode::NameDescending, ["c.txt", "b.txt", "a.txt"]),
        (
            LegacySortMode::FullPathAscending,
            ["a.txt", "b.txt", "c.txt"],
        ),
        (
            LegacySortMode::FullPathDescending,
            ["c.txt", "b.txt", "a.txt"],
        ),
        (LegacySortMode::SizeAscending, ["c.txt", "b.txt", "a.txt"]),
        (LegacySortMode::SizeDescending, ["a.txt", "b.txt", "c.txt"]),
        (
            LegacySortMode::ModifiedAscending,
            ["c.txt", "b.txt", "a.txt"],
        ),
        (
            LegacySortMode::ModifiedDescending,
            ["a.txt", "b.txt", "c.txt"],
        ),
        (
            LegacySortMode::CreatedAscending,
            ["a.txt", "c.txt", "b.txt"],
        ),
        (
            LegacySortMode::CreatedDescending,
            ["b.txt", "c.txt", "a.txt"],
        ),
    ];

    for (mode, expected) in cases {
        let mut list = make_list();
        assert!(list.manual_change(0, "000.txt"));
        list.sort(mode);
        assert_eq!(current(&list), expected, "mode: {mode:?}");
    }
}

#[test]
fn export_and_blank_line_import_preserve_order_crlf_and_utf16_text() {
    let mut list = list(&[
        (r"C:\root\one.txt", false),
        (r"C:\root\two.txt", false),
        (r"C:\root\three.txt", false),
    ]);
    assert!(list.manual_change(0, "first"));
    assert!(list.manual_change(1, "second"));
    assert_eq!(
        list.export_names(),
        LegacyText::from("first\r\nsecond\r\nthree.txt\r\n")
    );
    assert_eq!(
        list.export_paths(),
        LegacyText::from("C:\\root\\one.txt\r\nC:\\root\\two.txt\r\nC:\\root\\three.txt\r\n")
    );

    let imported = LegacyText::from("  alpha  \r\n\r\n beta\n \t\r\n😀gamma \r\nignored\n");
    assert_eq!(list.import_names(&imported), 3);
    assert_eq!(proposed(&list), ["alpha", "beta", "😀gamma"]);
    assert_eq!(
        parse_import_lines(&LegacyText::from(" C:\\a \r\n\n C:\\b\r\n")),
        [LegacyText::from(r"C:\a"), LegacyText::from(r"C:\b")]
    );
}
