use darknamer_core::{LegacyList, LegacyListItem, LegacySortMode};

#[test]
fn legacy_constructor_preserves_legacy_and_actual_size() {
    let item = LegacyListItem::new("C:\\a.bin", false, u32::MAX, 1, 2);
    assert_eq!(item.size(), u32::MAX);
    assert_eq!(item.actual_size(), u64::from(u32::MAX));
}

#[test]
fn actual_size_is_display_metadata_while_sort_remains_legacy_compatible() {
    let mut list = LegacyList::new();
    assert!(list.append(LegacyListItem::new_with_actual_size(
        "C:\\large.bin",
        false,
        1,
        u64::from(u32::MAX) + 2,
        1,
        2,
    )));
    assert!(list.append(LegacyListItem::new_with_actual_size(
        "C:\\small.bin",
        false,
        2,
        2,
        1,
        2,
    )));

    list.sort(LegacySortMode::SizeAscending);

    assert_eq!(
        list.items()[0].current_name().to_string_lossy(),
        "large.bin"
    );
    assert_eq!(list.items()[0].actual_size(), u64::from(u32::MAX) + 2);
}
