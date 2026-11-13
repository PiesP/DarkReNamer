use darknamer_core::{LegacyList, LegacyListItem, LegacySortMode, LegacyText, SortSemantics};

#[test]
fn legacy_constructor_preserves_legacy_and_actual_size() {
    let item = LegacyListItem::new("C:\\a.bin", false, u32::MAX, 1, 2);
    assert_eq!(item.size(), u32::MAX);
    assert_eq!(item.actual_size(), u64::from(u32::MAX));
}

#[test]
fn safe_size_policy_orders_by_full_actual_size() {
    let mut list = LegacyList::new();
    assert_eq!(
        list.append(LegacyListItem::new_with_actual_size(
            "C:\\large.bin",
            false,
            1,
            u64::from(u32::MAX) + 2,
            1,
            2,
        )),
        Ok(true)
    );
    assert_eq!(
        list.append(LegacyListItem::new_with_actual_size(
            "C:\\small.bin",
            false,
            2,
            2,
            1,
            2,
        )),
        Ok(true)
    );

    list.sort_by_with_semantics(
        LegacySortMode::SizeAscending,
        SortSemantics::SafeActualSize,
        LegacyText::case_insensitive_cmp,
    );

    assert_eq!(
        list.items()[0].current_name().to_string_lossy(),
        "small.bin"
    );
}

#[test]
fn actual_size_is_display_metadata_while_sort_remains_legacy_compatible() {
    let mut list = LegacyList::new();
    assert_eq!(
        list.append(LegacyListItem::new_with_actual_size(
            "C:\\large.bin",
            false,
            1,
            u64::from(u32::MAX) + 2,
            1,
            2,
        )),
        Ok(true)
    );
    assert_eq!(
        list.append(LegacyListItem::new_with_actual_size(
            "C:\\small.bin",
            false,
            2,
            2,
            1,
            2,
        )),
        Ok(true)
    );

    list.sort(LegacySortMode::SizeAscending);

    assert_eq!(
        list.items()[0].current_name().to_string_lossy(),
        "large.bin"
    );
    assert_eq!(list.items()[0].actual_size(), u64::from(u32::MAX) + 2);
}

#[test]
fn legacy_low_word_order_is_stable_at_boundaries_in_both_directions() {
    for mode in [
        LegacySortMode::SizeAscending,
        LegacySortMode::SizeDescending,
    ] {
        let mut list = LegacyList::new();
        for (name, size, actual) in [
            ("max.bin", u32::MAX, u64::MAX),
            ("half-first.bin", 0x8000_0000, 0x8000_0000),
            ("zero.bin", 0, 1_u64 << 32),
            ("half-second.bin", 0x8000_0000, 3_u64 << 32),
        ] {
            assert_eq!(
                list.append(LegacyListItem::new_with_actual_size(
                    format!(r"C:\{name}"),
                    false,
                    size,
                    actual,
                    1,
                    2,
                )),
                Ok(true)
            );
        }
        assert!(list.sort_by_changed(mode, LegacyText::case_insensitive_cmp));
        let names = list
            .items()
            .iter()
            .map(|row| row.current_name().to_string_lossy())
            .collect::<Vec<_>>();
        let expected = if mode == LegacySortMode::SizeAscending {
            ["zero.bin", "half-first.bin", "half-second.bin", "max.bin"]
        } else {
            ["max.bin", "half-first.bin", "half-second.bin", "zero.bin"]
        };
        assert_eq!(names, expected);
        assert!(!list.sort_by_changed(mode, LegacyText::case_insensitive_cmp));
        assert_eq!(
            list.items()
                .iter()
                .find(|row| row.size() == 0)
                .map(LegacyListItem::actual_size),
            Some(1_u64 << 32)
        );
    }
}
