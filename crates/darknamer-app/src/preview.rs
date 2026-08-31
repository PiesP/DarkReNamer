//! Pure preview counts and diagnostics for the native workbench.

use darknamer_core::{LegacyText, WindowsLeafNameError};

/// Exact, non-authorizing counts shown by the native preview workbench.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct PreviewCounts {
    pub(crate) total: usize,
    pub(crate) changed: usize,
    pub(crate) selected: usize,
}

/// Cached model-only portion of preview counts.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct PreviewCountCache {
    total: usize,
    changed: usize,
}

impl PreviewCountCache {
    /// Replaces the cache from the authoritative model projection.
    pub(crate) fn refresh<'a, T: PartialEq + ?Sized + 'a>(
        &mut self,
        names: impl IntoIterator<Item = (&'a T, &'a T)>,
    ) {
        let mut total = 0_usize;
        let mut changed = 0_usize;
        for (current, proposed) in names {
            total = total.saturating_add(1);
            changed = changed.saturating_add(usize::from(current != proposed));
        }
        *self = Self { total, changed };
    }

    #[must_use]
    pub(crate) const fn with_selected(self, selected: usize) -> PreviewCounts {
        PreviewCounts {
            total: self.total,
            changed: self.changed,
            selected,
        }
    }
}

/// Model-only warning/blocker attached to one proposed-name row.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum PreviewRowIssue {
    #[default]
    None,
    EmptyStem,
    InvalidName(WindowsLeafNameError),
    DuplicateDestination,
}

/// Short, non-authorizing text rendered in the fixed native Status column.
#[must_use]
pub(crate) const fn preview_status_label(issue: PreviewRowIssue, changed: bool) -> &'static str {
    match issue {
        PreviewRowIssue::None if changed => "변경 예정",
        PreviewRowIssue::None => "",
        PreviewRowIssue::EmptyStem => "주의: 이름 본체",
        PreviewRowIssue::InvalidName(_) => "차단: 이름",
        PreviewRowIssue::DuplicateDestination => "차단: 충돌",
    }
}

/// Finds rows whose rendered Status cell differs from refreshed preview state.
#[must_use]
pub(crate) fn preview_status_delta_rows<'a>(
    previous: impl IntoIterator<Item = &'a LegacyText>,
    refreshed: impl IntoIterator<Item = (PreviewRowIssue, bool)>,
) -> Option<Box<[usize]>> {
    let mut previous = previous.into_iter();
    let mut refreshed = refreshed.into_iter();
    let mut changed_rows = Vec::new();
    let mut row = 0_usize;
    loop {
        match (previous.next(), refreshed.next()) {
            (Some(previous), Some((issue, changed))) => {
                let expected = preview_status_label(issue, changed);
                if !previous.units().iter().copied().eq(expected.encode_utf16()) {
                    changed_rows.push(row);
                }
                row = row.saturating_add(1);
            }
            (None, None) => return Some(changed_rows.into_boxed_slice()),
            (Some(_), None) | (None, Some(_)) => return None,
        }
    }
}

/// Cached preview-only diagnostics. These never authorize filesystem work.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct PreviewIssueCache {
    rows: Vec<PreviewRowIssue>,
    warning_rows: usize,
    invalid_name_rows: usize,
    duplicate_destination_rows: usize,
    blocker_rows: usize,
}

impl PreviewIssueCache {
    pub(crate) fn refresh_by<'a, F, K>(
        &mut self,
        rows: impl IntoIterator<Item = (&'a LegacyText, &'a LegacyText, &'a LegacyText, bool)>,
        mut destination_key: F,
    ) where
        F: FnMut(&LegacyText, &LegacyText) -> K,
        K: Ord,
    {
        let rows = rows.into_iter().collect::<Vec<_>>();
        self.rows.clear();
        self.rows.resize(rows.len(), PreviewRowIssue::None);
        let mut destinations = Vec::new();
        for (row, (parent, current, proposed, is_directory)) in rows.iter().copied().enumerate() {
            let changed = current != proposed;
            let valid = if changed {
                match darknamer_core::validate_windows_leaf_name(proposed) {
                    Ok(()) => true,
                    Err(error) => {
                        self.rows[row] = PreviewRowIssue::InvalidName(error);
                        false
                    }
                }
            } else {
                true
            };
            if changed && valid && preview_name_has_empty_stem(proposed, is_directory) {
                self.rows[row] = PreviewRowIssue::EmptyStem;
            }
            let effective_name = if changed { proposed } else { current };
            destinations.push((row, destination_key(parent, effective_name), changed, valid));
        }
        destinations.sort_by(|left, right| left.1.cmp(&right.1));
        let mut group_start = 0_usize;
        while group_start < destinations.len() {
            let mut group_end = group_start + 1;
            while group_end < destinations.len()
                && destinations[group_start].1 == destinations[group_end].1
            {
                group_end += 1;
            }
            if group_end - group_start > 1 {
                for destination in &destinations[group_start..group_end] {
                    if destination.2 && destination.3 {
                        self.rows[destination.0] = PreviewRowIssue::DuplicateDestination;
                    }
                }
            }
            group_start = group_end;
        }
        self.warning_rows = self
            .rows
            .iter()
            .filter(|issue| matches!(issue, PreviewRowIssue::EmptyStem))
            .count();
        self.invalid_name_rows = self
            .rows
            .iter()
            .filter(|issue| matches!(issue, PreviewRowIssue::InvalidName(_)))
            .count();
        self.duplicate_destination_rows = self
            .rows
            .iter()
            .filter(|issue| matches!(issue, PreviewRowIssue::DuplicateDestination))
            .count();
        self.blocker_rows = self
            .invalid_name_rows
            .saturating_add(self.duplicate_destination_rows);
    }

    #[must_use]
    pub(crate) fn issue(&self, row: usize) -> PreviewRowIssue {
        self.rows.get(row).copied().unwrap_or_default()
    }

    #[must_use]
    pub(crate) const fn has_blocker(&self) -> bool {
        self.blocker_rows != 0
    }

    #[must_use]
    pub(crate) fn blocker_rows(&self) -> Box<[usize]> {
        self.rows
            .iter()
            .enumerate()
            .filter_map(|(row, issue)| {
                matches!(
                    issue,
                    PreviewRowIssue::InvalidName(_) | PreviewRowIssue::DuplicateDestination
                )
                .then_some(row)
            })
            .collect::<Vec<_>>()
            .into_boxed_slice()
    }

    #[must_use]
    pub(crate) const fn blocker_explanation(&self) -> Option<&'static str> {
        match (
            self.invalid_name_rows != 0,
            self.duplicate_destination_rows != 0,
        ) {
            (true, true) => Some(
                "Windows에서 사용할 수 없는 대상 이름과 같은 폴더의 대상 이름 충돌이 있습니다. 표시된 행의 이름을 Windows 이름 규칙에 맞고 서로 다르게 수정해 주세요.",
            ),
            (true, false) => Some(
                "Windows에서 사용할 수 없는 대상 이름이 있습니다. 표시된 행의 이름을 Windows 이름 규칙에 맞게 수정해 주세요.",
            ),
            (false, true) => Some(
                "같은 폴더에서 둘 이상의 항목이 같은 대상 이름을 사용합니다. 표시된 행의 이름을 다르게 지정해 주세요.",
            ),
            (false, false) => None,
        }
    }

    #[must_use]
    pub(crate) fn notice(&self) -> Option<String> {
        let mut counts = Vec::new();
        if self.invalid_name_rows != 0 {
            counts.push(format!("잘못된 대상 이름 {}개", self.invalid_name_rows));
        }
        if self.duplicate_destination_rows != 0 {
            counts.push(format!(
                "대상 이름 충돌 {}개",
                self.duplicate_destination_rows
            ));
        }
        if self.warning_rows != 0 {
            counts.push(format!(
                "이름 본체가 비어 있는 항목 {}개",
                self.warning_rows
            ));
        }
        if counts.is_empty() {
            return None;
        }
        let action = if self.blocker_rows != 0 {
            "변경 적용이 차단되었습니다."
        } else {
            "변경 전에 확인하세요."
        };
        Some(format!("{} · {action}", counts.join(" · ")))
    }
}

#[must_use]
pub(crate) fn windows_leaf_name_error_korean(error: WindowsLeafNameError) -> &'static str {
    match error {
        WindowsLeafNameError::Empty => "이름이 비어 있음",
        WindowsLeafNameError::ContainsNul => "NUL 문자가 포함됨",
        WindowsLeafNameError::ContainsSeparator => "경로 구분자가 포함됨",
        WindowsLeafNameError::DotComponent => "점 경로 구성 요소(.) 또는 (..)임",
        WindowsLeafNameError::InvalidCharacter => "Windows에서 금지된 문자가 포함됨",
        WindowsLeafNameError::ReservedDeviceName => "Windows 예약 장치 이름임",
        WindowsLeafNameError::TrailingDotOrSpace => "점 또는 공백으로 끝남",
        WindowsLeafNameError::TooLong => "Windows 이름 길이 제한을 초과함",
        _ => "Windows 이름 규칙에 맞지 않음",
    }
}

fn preview_name_has_empty_stem(name: &LegacyText, is_directory: bool) -> bool {
    if is_directory {
        return name.is_empty();
    }
    name.units().iter().rposition(|unit| *unit == b'.' as u16) == Some(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_count_cache_updates_only_at_the_authoritative_refresh_boundary() {
        let mut names = [
            ("photo.jpg", "photo.jpg"),
            ("photo.jpg", "PHOTO.jpg"),
            ("한글.txt", "한글-01.txt"),
        ];
        let mut cache = PreviewCountCache::default();
        cache.refresh(names.iter().copied());

        assert_eq!(
            cache.with_selected(2),
            PreviewCounts {
                total: 3,
                changed: 2,
                selected: 2,
            }
        );

        names[1].1 = "photo.jpg";
        assert_eq!(cache.with_selected(1).changed, 2);
        cache.refresh(names.iter().copied());
        assert_eq!(
            cache.with_selected(1),
            PreviewCounts {
                total: 3,
                changed: 1,
                selected: 1,
            }
        );
    }

    fn preview_test_destination_key(
        parent: &darknamer_core::LegacyText,
        leaf: &darknamer_core::LegacyText,
    ) -> (Box<[u16]>, Box<[u16]>) {
        fn ascii_fold(text: &darknamer_core::LegacyText) -> Box<[u16]> {
            text.units()
                .iter()
                .map(|unit| {
                    if (b'A' as u16..=b'Z' as u16).contains(unit) {
                        unit + u16::from(b'a' - b'A')
                    } else {
                        *unit
                    }
                })
                .collect::<Vec<_>>()
                .into_boxed_slice()
        }

        (ascii_fold(parent), ascii_fold(leaf))
    }

    #[test]
    fn preview_issues_compute_each_final_destination_key_once() {
        use std::cell::Cell;

        use darknamer_core::LegacyText;

        let parent = LegacyText::from(r"C:\work");
        let current_a = LegacyText::from("a.txt");
        let current_b = LegacyText::from("b.txt");
        let proposed_b = LegacyText::from("b.txt");
        let calls = Cell::new(0_usize);
        let mut cache = PreviewIssueCache::default();

        cache.refresh_by(
            [
                (&parent, &current_a, &proposed_b, false),
                (&parent, &current_b, &current_b, false),
            ],
            |destination_parent, destination_leaf| {
                calls.set(calls.get().saturating_add(1));
                preview_test_destination_key(destination_parent, destination_leaf)
            },
        );

        assert_eq!(calls.get(), 2);
        assert_eq!(cache.issue(0), PreviewRowIssue::DuplicateDestination);
        assert_eq!(cache.issue(1), PreviewRowIssue::None);
    }

    #[test]
    fn native_preview_status_labels_are_short_korean_text_without_filename_prefixes() {
        use darknamer_core::WindowsLeafNameError;

        assert_eq!(preview_status_label(PreviewRowIssue::None, false), "");
        assert_eq!(
            preview_status_label(PreviewRowIssue::None, true),
            "변경 예정"
        );
        assert_eq!(
            preview_status_label(PreviewRowIssue::EmptyStem, true),
            "주의: 이름 본체"
        );
        assert_eq!(
            preview_status_label(
                PreviewRowIssue::InvalidName(WindowsLeafNameError::InvalidCharacter),
                true,
            ),
            "차단: 이름"
        );
        assert_eq!(
            preview_status_label(PreviewRowIssue::DuplicateDestination, true),
            "차단: 충돌"
        );
    }

    #[test]
    fn status_delta_includes_collision_peers_when_collision_appears_and_clears() {
        use darknamer_core::LegacyText;

        let parent = LegacyText::from(r"C:\work");
        let current_a = LegacyText::from("a.txt");
        let current_b = LegacyText::from("b.txt");
        let proposed_a = LegacyText::from("first.txt");
        let mut proposed_b = LegacyText::from("second.txt");
        let mut cache = PreviewIssueCache::default();
        cache.refresh_by(
            [
                (&parent, &current_a, &proposed_a, false),
                (&parent, &current_b, &proposed_b, false),
            ],
            preview_test_destination_key,
        );
        let ordinary =
            [0, 1].map(|row| LegacyText::from(preview_status_label(cache.issue(row), true)));

        proposed_b = proposed_a.clone();
        cache.refresh_by(
            [
                (&parent, &current_a, &proposed_a, false),
                (&parent, &current_b, &proposed_b, false),
            ],
            preview_test_destination_key,
        );
        let introduced =
            preview_status_delta_rows(ordinary.iter(), [0, 1].map(|row| (cache.issue(row), true)));
        assert_eq!(introduced.as_deref(), Some([0, 1].as_slice()));

        let collision =
            [0, 1].map(|row| LegacyText::from(preview_status_label(cache.issue(row), true)));
        proposed_b = LegacyText::from("second.txt");
        cache.refresh_by(
            [
                (&parent, &current_a, &proposed_a, false),
                (&parent, &current_b, &proposed_b, false),
            ],
            preview_test_destination_key,
        );
        let removed =
            preview_status_delta_rows(collision.iter(), [0, 1].map(|row| (cache.issue(row), true)));
        assert_eq!(removed.as_deref(), Some([0, 1].as_slice()));
    }

    #[test]
    fn ten_thousand_row_preview_validation_derives_one_key_per_row_and_exact_counts() {
        use std::cell::Cell;

        use darknamer_core::LegacyText;

        let parent = LegacyText::from(r"C:\work");
        let mut names = (0..9_996)
            .map(|row| {
                let name = LegacyText::from(format!("item-{row}.txt"));
                (name.clone(), name)
            })
            .collect::<Vec<_>>();
        names.extend([
            (LegacyText::from("a.txt"), LegacyText::from("collision.txt")),
            (LegacyText::from("b.txt"), LegacyText::from("collision.txt")),
            (LegacyText::from("c.txt"), LegacyText::from("bad?.txt")),
            (LegacyText::from("d.txt"), LegacyText::from(".txt")),
        ]);
        let calls = Cell::new(0_usize);
        let mut cache = PreviewIssueCache::default();

        cache.refresh_by(
            names
                .iter()
                .map(|(current, proposed)| (&parent, current, proposed, false)),
            |destination_parent, destination_leaf| {
                calls.set(calls.get().saturating_add(1));
                preview_test_destination_key(destination_parent, destination_leaf)
            },
        );

        assert_eq!(calls.get(), 10_000);
        assert_eq!(cache.rows.len(), 10_000);
        assert_eq!(cache.warning_rows, 1);
        assert_eq!(cache.invalid_name_rows, 1);
        assert_eq!(cache.duplicate_destination_rows, 2);
        assert_eq!(cache.blocker_rows, 3);
    }

    #[test]
    #[ignore = "manual release-mode measurement; reports duration without a CI threshold"]
    fn measure_ten_thousand_row_preview_validation_duration() {
        use darknamer_core::LegacyText;

        let parent = LegacyText::from(r"C:\work");
        let names = (0..10_000)
            .map(|row| {
                let name = LegacyText::from(format!("item-{row}.txt"));
                (name.clone(), name)
            })
            .collect::<Vec<_>>();
        let mut cache = PreviewIssueCache::default();
        let started = std::time::Instant::now();
        cache.refresh_by(
            names
                .iter()
                .map(|(current, proposed)| (&parent, current, proposed, false)),
            preview_test_destination_key,
        );
        let elapsed = started.elapsed();

        eprintln!("10,000-row preview validation: {elapsed:?}");
        assert_eq!(cache.rows.len(), 10_000);
    }

    #[test]
    fn preview_issues_block_a_changed_name_that_occupies_an_unchanged_destination() {
        use darknamer_core::LegacyText;

        let parent = LegacyText::from(r"C:\work");
        let current_a = LegacyText::from("a.txt");
        let current_b = LegacyText::from("b.txt");
        let proposed_b = LegacyText::from("b.txt");
        let mut cache = PreviewIssueCache::default();

        cache.refresh_by(
            [
                (&parent, &current_a, &proposed_b, false),
                (&parent, &current_b, &current_b, false),
            ],
            preview_test_destination_key,
        );

        assert_eq!(cache.issue(0), PreviewRowIssue::DuplicateDestination);
        assert_eq!(cache.issue(1), PreviewRowIssue::None);
        assert_eq!(cache.blocker_rows().as_ref(), &[0]);
        assert_eq!(
            cache.blocker_explanation(),
            Some(
                "같은 폴더에서 둘 이상의 항목이 같은 대상 이름을 사용합니다. 표시된 행의 이름을 다르게 지정해 주세요."
            )
        );
    }

    #[test]
    fn preview_issues_preserve_chains_swaps_cross_parent_names_and_case_only_renames() {
        use darknamer_core::LegacyText;

        let parent = LegacyText::from(r"C:\work");
        let other_parent = LegacyText::from(r"C:\other");
        let a = LegacyText::from("a.txt");
        let upper_a = LegacyText::from("A.txt");
        let b = LegacyText::from("b.txt");
        let c = LegacyText::from("c.txt");
        let d = LegacyText::from("d.txt");
        let same = LegacyText::from("same.txt");
        let mut cache = PreviewIssueCache::default();

        cache.refresh_by(
            [
                (&parent, &a, &b, false),
                (&parent, &b, &c, false),
                (&parent, &c, &d, false),
            ],
            preview_test_destination_key,
        );
        assert!(!cache.has_blocker(), "a rename chain remains schedulable");

        cache.refresh_by(
            [(&parent, &a, &b, false), (&parent, &b, &a, false)],
            preview_test_destination_key,
        );
        assert!(!cache.has_blocker(), "a swap remains schedulable");

        cache.refresh_by(
            [
                (&parent, &a, &same, false),
                (&other_parent, &b, &same, false),
            ],
            preview_test_destination_key,
        );
        assert!(
            !cache.has_blocker(),
            "same names in different parents are valid"
        );

        cache.refresh_by(
            [(&parent, &a, &upper_a, false)],
            preview_test_destination_key,
        );
        assert!(!cache.has_blocker(), "a case-only rename remains valid");
    }

    #[test]
    fn preview_issues_block_invalid_changed_windows_leaf_names() {
        use darknamer_core::{LegacyText, WindowsLeafNameError};

        let parent = LegacyText::from(r"C:\work");
        let current_a = LegacyText::from("a.txt");
        let current_b = LegacyText::from("b.txt");
        let current_c = LegacyText::from("c.txt");
        let empty = LegacyText::from("");
        let reserved = LegacyText::from("CON.txt");
        let forbidden = LegacyText::from("bad?.txt");
        let mut cache = PreviewIssueCache::default();

        cache.refresh_by(
            [
                (&parent, &current_a, &empty, false),
                (&parent, &current_b, &reserved, false),
                (&parent, &current_c, &forbidden, false),
            ],
            preview_test_destination_key,
        );

        assert_eq!(
            cache.issue(0),
            PreviewRowIssue::InvalidName(WindowsLeafNameError::Empty)
        );
        assert_eq!(
            cache.issue(1),
            PreviewRowIssue::InvalidName(WindowsLeafNameError::ReservedDeviceName)
        );
        assert_eq!(
            cache.issue(2),
            PreviewRowIssue::InvalidName(WindowsLeafNameError::InvalidCharacter)
        );
        assert_eq!(cache.blocker_rows().as_ref(), &[0, 1, 2]);
        assert_eq!(
            cache.notice().as_deref(),
            Some("잘못된 대상 이름 3개 · 변경 적용이 차단되었습니다.")
        );
        assert_eq!(
            cache.blocker_explanation(),
            Some(
                "Windows에서 사용할 수 없는 대상 이름이 있습니다. 표시된 행의 이름을 Windows 이름 규칙에 맞게 수정해 주세요."
            )
        );

        let trailing = LegacyText::from("trailing.");
        cache.refresh_by(
            [(&parent, &current_a, &trailing, false)],
            preview_test_destination_key,
        );
        assert_eq!(
            cache.issue(0),
            PreviewRowIssue::InvalidName(WindowsLeafNameError::TrailingDotOrSpace)
        );
        assert_eq!(
            windows_leaf_name_error_korean(WindowsLeafNameError::TrailingDotOrSpace),
            "점 또는 공백으로 끝남"
        );
    }

    #[test]
    fn preview_issues_keep_valid_dotfile_boundaries_as_warnings_or_collisions() {
        use darknamer_core::LegacyText;

        let parent = LegacyText::from(r"C:\work");
        let current_a = LegacyText::from("a.jpg");
        let current_b = LegacyText::from("b.jpg");
        let dot_jpg = LegacyText::from(".jpg");
        let dot_env = LegacyText::from(".env");
        let mut cache = PreviewIssueCache::default();

        cache.refresh_by(
            [(&parent, &current_a, &dot_jpg, false)],
            preview_test_destination_key,
        );
        assert_eq!(cache.issue(0), PreviewRowIssue::EmptyStem);
        assert!(!cache.has_blocker());

        cache.refresh_by(
            [
                (&parent, &current_a, &dot_jpg, false),
                (&parent, &current_b, &dot_jpg, false),
            ],
            preview_test_destination_key,
        );
        assert_eq!(cache.issue(0), PreviewRowIssue::DuplicateDestination);
        assert_eq!(cache.issue(1), PreviewRowIssue::DuplicateDestination);

        cache.refresh_by(
            [(&parent, &dot_env, &dot_env, false)],
            preview_test_destination_key,
        );
        assert_eq!(cache.issue(0), PreviewRowIssue::None);
        assert_eq!(cache.notice(), None);
    }

    #[test]
    fn preview_issues_aggregate_invalid_duplicate_and_warning_counts_in_priority_order() {
        use darknamer_core::LegacyText;

        let parent = LegacyText::from(r"C:\work");
        let invalid_current = LegacyText::from("invalid.txt");
        let duplicate_current_a = LegacyText::from("a.txt");
        let duplicate_current_b = LegacyText::from("b.txt");
        let warning_current = LegacyText::from("photo.png");
        let empty = LegacyText::from("");
        let duplicate = LegacyText::from("same.txt");
        let warning = LegacyText::from(".png");
        let mut cache = PreviewIssueCache::default();

        cache.refresh_by(
            [
                (&parent, &invalid_current, &empty, false),
                (&parent, &duplicate_current_a, &duplicate, false),
                (&parent, &duplicate_current_b, &duplicate, false),
                (&parent, &warning_current, &warning, false),
            ],
            preview_test_destination_key,
        );

        assert_eq!(cache.blocker_rows().as_ref(), &[0, 1, 2]);
        assert_eq!(
            cache.notice().as_deref(),
            Some(
                "잘못된 대상 이름 1개 · 대상 이름 충돌 2개 · 이름 본체가 비어 있는 항목 1개 · 변경 적용이 차단되었습니다."
            )
        );
        assert_eq!(
            cache.blocker_explanation(),
            Some(
                "Windows에서 사용할 수 없는 대상 이름과 같은 폴더의 대상 이름 충돌이 있습니다. 표시된 행의 이름을 Windows 이름 규칙에 맞고 서로 다르게 수정해 주세요."
            )
        );
    }
}
