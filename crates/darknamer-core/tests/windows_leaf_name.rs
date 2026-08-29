use darknamer_core::{LegacyText, WindowsLeafNameError, validate_windows_leaf_name};

#[test]
fn accepts_legacy_utf16_leaf_names_without_normalizing_them() {
    let decomposed = LegacyText::from("한글.txt");
    assert_eq!(validate_windows_leaf_name(&decomposed), Ok(()));
}

#[test]
fn rejects_windows_leaf_name_hazards() {
    let cases = [
        (
            LegacyText::from_units(vec![b'a' as u16, 0, b'b' as u16]),
            WindowsLeafNameError::ContainsNul,
        ),
        (
            LegacyText::from("a/b"),
            WindowsLeafNameError::ContainsSeparator,
        ),
        (
            LegacyText::from("a\\b"),
            WindowsLeafNameError::ContainsSeparator,
        ),
        (LegacyText::from(".."), WindowsLeafNameError::DotComponent),
        (
            LegacyText::from("CON.txt"),
            WindowsLeafNameError::ReservedDeviceName,
        ),
        (
            LegacyText::from("name."),
            WindowsLeafNameError::TrailingDotOrSpace,
        ),
        (
            LegacyText::from("name "),
            WindowsLeafNameError::TrailingDotOrSpace,
        ),
        (
            LegacyText::from("a".repeat(256)),
            WindowsLeafNameError::TooLong,
        ),
    ];

    for (name, expected) in cases {
        assert_eq!(validate_windows_leaf_name(&name), Err(expected));
    }
}
