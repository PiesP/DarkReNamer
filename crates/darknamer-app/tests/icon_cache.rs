use std::collections::HashMap;

use darknamer_app::icon_cache::{
    IconCacheKey, MAX_ICON_CACHE_ENTRIES, cache_icon_index, icon_cache_key,
};
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

#[test]
fn unique_extension_churn_keeps_the_process_cache_bounded() {
    let mut cache = HashMap::new();
    for index in 0..(MAX_ICON_CACHE_ENTRIES * 3) {
        let key = icon_cache_key(&LegacyText::from(format!("file.ext{index}")), false);
        cache_icon_index(&mut cache, key, index as i32);
        assert!(cache.len() <= MAX_ICON_CACHE_ENTRIES);
    }
}

#[test]
fn updating_a_cached_extension_does_not_clear_other_entries() {
    let mut cache = HashMap::new();
    for index in 0..MAX_ICON_CACHE_ENTRIES {
        let key = icon_cache_key(&LegacyText::from(format!("file.ext{index}")), false);
        cache_icon_index(&mut cache, key, index as i32);
    }
    let first = icon_cache_key(&LegacyText::from("file.ext0"), false);

    cache_icon_index(&mut cache, first.clone(), -1);

    assert_eq!(cache.len(), MAX_ICON_CACHE_ENTRIES);
    assert_eq!(cache.get(&first), Some(&-1));
}
