use darknamer_app::icon_cache::{IconCacheKey, icon_cache_key};
use darknamer_core::LegacyText;

#[test]
fn icon_keys_share_directory_and_case_folded_extension_classes() {
    assert_eq!(
        icon_cache_key(&LegacyText::from("anything"), true),
        IconCacheKey::Directory
    );
    assert_eq!(
        icon_cache_key(&LegacyText::from("one.TXT"), false),
        icon_cache_key(&LegacyText::from("two.txt"), false)
    );
    assert_eq!(
        icon_cache_key(&LegacyText::from("one.ÄBC"), false),
        icon_cache_key(&LegacyText::from("two.äbc"), false)
    );
    assert_eq!(
        icon_cache_key(&LegacyText::from("README"), false),
        IconCacheKey::FileWithoutExtension
    );
    assert_eq!(
        icon_cache_key(&LegacyText::from("trailing."), false),
        IconCacheKey::FileWithoutExtension
    );
}

#[test]
fn extension_key_builds_one_shell_lookup_name() {
    let key = icon_cache_key(&LegacyText::from("archive.ZIP"), false);
    assert_eq!(key.lookup_text().to_string_lossy(), "file.zip");
}
