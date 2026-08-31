//! Pure preview counts and diagnostics for the native workbench.

use std::collections::{BTreeMap, BTreeSet, btree_map::Entry};
use std::rc::Rc;

use darknamer_core::{LegacyText, WindowsLeafNameError};

use crate::rename::PathKey;

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

    /// Updates the changed count for one row without rescanning the model.
    ///
    /// Returns `false` without mutation when the cached total does not match
    /// the authoritative model length or the requested transition contradicts
    /// the cached count.
    pub(crate) fn refresh_one(
        &mut self,
        model_len: usize,
        previous_changed: bool,
        current_changed: bool,
    ) -> bool {
        if self.total != model_len {
            return false;
        }
        let next_changed = match (previous_changed, current_changed) {
            (false, true) => self.changed.checked_add(1),
            (true, false) => self.changed.checked_sub(1),
            (false, false) | (true, true) => Some(self.changed),
        };
        let Some(next_changed) = next_changed.filter(|changed| *changed <= self.total) else {
            return false;
        };
        self.changed = next_changed;
        true
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct CachedPreviewRow {
    destination_key: Rc<PathKey>,
    base_issue: PreviewRowIssue,
    issue: PreviewRowIssue,
    changed: bool,
}

/// Exact preview-cache effects of one proposed-name edit.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct PreviewIssueUpdate {
    pub(crate) affected_rows: Box<[usize]>,
    pub(crate) previous_changed: bool,
    pub(crate) current_changed: bool,
}

/// Cached preview-only diagnostics. These never authorize filesystem work.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct PreviewIssueCache {
    initialized: bool,
    rows: Vec<CachedPreviewRow>,
    destination_rows: BTreeMap<Rc<PathKey>, BTreeSet<usize>>,
    warning_rows: usize,
    invalid_name_rows: usize,
    duplicate_destination_rows: usize,
    blocker_rows: usize,
}

impl PreviewIssueCache {
    pub(crate) fn refresh_by<'a, F>(
        &mut self,
        rows: impl IntoIterator<Item = (&'a LegacyText, &'a LegacyText, &'a LegacyText, bool)>,
        mut destination_key: F,
    ) where
        F: FnMut(&LegacyText, &LegacyText) -> PathKey,
    {
        let mut next = Self {
            initialized: true,
            ..Self::default()
        };
        for (parent, current, proposed, is_directory) in rows {
            let row = next.rows.len();
            let changed = current != proposed;
            let base_issue = preview_base_issue(current, proposed, is_directory);
            let effective_name = if changed { proposed } else { current };
            let computed_key = Rc::new(destination_key(parent, effective_name));
            let destination_key = match next.destination_rows.entry(computed_key) {
                Entry::Occupied(mut entry) => {
                    let key = Rc::clone(entry.key());
                    entry.get_mut().insert(row);
                    key
                }
                Entry::Vacant(entry) => {
                    let key = Rc::clone(entry.key());
                    entry.insert(BTreeSet::from([row]));
                    key
                }
            };
            next.rows.push(CachedPreviewRow {
                destination_key,
                base_issue,
                issue: base_issue,
                changed,
            });
        }

        for group in next.destination_rows.values() {
            let colliding = group.len() > 1;
            for &row in group {
                let cached = &mut next.rows[row];
                cached.issue = resolved_preview_issue(cached.base_issue, cached.changed, colliding);
                match cached.issue {
                    PreviewRowIssue::None => {}
                    PreviewRowIssue::EmptyStem => next.warning_rows += 1,
                    PreviewRowIssue::InvalidName(_) => next.invalid_name_rows += 1,
                    PreviewRowIssue::DuplicateDestination => {
                        next.duplicate_destination_rows += 1;
                    }
                }
            }
        }
        next.blocker_rows = next
            .invalid_name_rows
            .saturating_add(next.duplicate_destination_rows);
        *self = next;
    }

    /// Incrementally refreshes one row after a proposed-name edit.
    ///
    /// The destination callback is invoked exactly once after the cache/model
    /// boundary has been validated. `None` requests a full-refresh fallback and
    /// leaves the cache unchanged.
    pub(crate) fn refresh_one_by<F>(
        &mut self,
        model_len: usize,
        row: usize,
        values: (&LegacyText, &LegacyText, &LegacyText, bool),
        mut destination_key: F,
    ) -> Option<PreviewIssueUpdate>
    where
        F: FnMut(&LegacyText, &LegacyText) -> PathKey,
    {
        if !self.initialized || self.rows.len() != model_len || row >= model_len {
            return None;
        }
        let (parent, current, proposed, is_directory) = values;
        let old_key = Rc::clone(&self.rows[row].destination_key);
        let old_group = self
            .destination_rows
            .get(&old_key)
            .filter(|group| group.contains(&row))?;
        let mut affected_rows = old_group.clone();
        let previous_changed = self.rows[row].changed;
        let current_changed = current != proposed;
        let base_issue = preview_base_issue(current, proposed, is_directory);
        let effective_name = if current_changed { proposed } else { current };
        let computed_key = destination_key(parent, effective_name);

        let canonical_key = if old_key.as_ref() == &computed_key {
            Rc::clone(&old_key)
        } else {
            match self.destination_rows.entry(Rc::clone(&old_key)) {
                Entry::Occupied(mut entry) => {
                    entry.get_mut().remove(&row);
                    if entry.get().is_empty() {
                        entry.remove();
                    }
                }
                Entry::Vacant(_) => return None,
            }
            let computed_key = Rc::new(computed_key);
            match self.destination_rows.entry(computed_key) {
                Entry::Occupied(mut entry) => {
                    let key = Rc::clone(entry.key());
                    entry.get_mut().insert(row);
                    key
                }
                Entry::Vacant(entry) => {
                    let key = Rc::clone(entry.key());
                    entry.insert(BTreeSet::from([row]));
                    key
                }
            }
        };
        if old_key.as_ref() == canonical_key.as_ref() {
            debug_assert!(
                self.destination_rows
                    .get(&canonical_key)
                    .is_some_and(|group| group.contains(&row))
            );
        } else if let Some(new_group) = self.destination_rows.get(&canonical_key) {
            affected_rows.extend(new_group.iter().copied());
        }

        self.rows[row].destination_key = canonical_key;
        self.rows[row].base_issue = base_issue;
        self.rows[row].changed = current_changed;
        for affected in affected_rows.iter().copied() {
            let cached = &self.rows[affected];
            let colliding = self
                .destination_rows
                .get(&cached.destination_key)
                .is_some_and(|group| group.len() > 1);
            let issue = resolved_preview_issue(cached.base_issue, cached.changed, colliding);
            self.replace_issue(affected, issue);
        }
        self.blocker_rows = self
            .invalid_name_rows
            .saturating_add(self.duplicate_destination_rows);

        Some(PreviewIssueUpdate {
            affected_rows: affected_rows
                .into_iter()
                .collect::<Vec<_>>()
                .into_boxed_slice(),
            previous_changed,
            current_changed,
        })
    }

    fn replace_issue(&mut self, row: usize, issue: PreviewRowIssue) {
        let previous = self.rows[row].issue;
        if previous == issue {
            return;
        }
        match previous {
            PreviewRowIssue::None => {}
            PreviewRowIssue::EmptyStem => {
                debug_assert!(self.warning_rows > 0);
                self.warning_rows = self.warning_rows.saturating_sub(1);
            }
            PreviewRowIssue::InvalidName(_) => {
                debug_assert!(self.invalid_name_rows > 0);
                self.invalid_name_rows = self.invalid_name_rows.saturating_sub(1);
            }
            PreviewRowIssue::DuplicateDestination => {
                debug_assert!(self.duplicate_destination_rows > 0);
                self.duplicate_destination_rows = self.duplicate_destination_rows.saturating_sub(1);
            }
        }
        match issue {
            PreviewRowIssue::None => {}
            PreviewRowIssue::EmptyStem => self.warning_rows += 1,
            PreviewRowIssue::InvalidName(_) => self.invalid_name_rows += 1,
            PreviewRowIssue::DuplicateDestination => self.duplicate_destination_rows += 1,
        }
        self.rows[row].issue = issue;
    }

    #[must_use]
    pub(crate) fn issue(&self, row: usize) -> PreviewRowIssue {
        self.rows
            .get(row)
            .map(|cached| cached.issue)
            .unwrap_or_default()
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
            .filter_map(|(row, cached)| {
                matches!(
                    cached.issue,
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

fn preview_base_issue(
    current: &LegacyText,
    proposed: &LegacyText,
    is_directory: bool,
) -> PreviewRowIssue {
    if current == proposed {
        return PreviewRowIssue::None;
    }
    match darknamer_core::validate_windows_leaf_name(proposed) {
        Err(error) => PreviewRowIssue::InvalidName(error),
        Ok(()) if preview_name_has_empty_stem(proposed, is_directory) => PreviewRowIssue::EmptyStem,
        Ok(()) => PreviewRowIssue::None,
    }
}

fn resolved_preview_issue(
    base_issue: PreviewRowIssue,
    changed: bool,
    colliding: bool,
) -> PreviewRowIssue {
    if matches!(base_issue, PreviewRowIssue::InvalidName(_)) {
        base_issue
    } else if changed && colliding {
        PreviewRowIssue::DuplicateDestination
    } else {
        base_issue
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

    #[test]
    fn preview_count_cache_updates_one_row_only_from_prior_and_current_state() {
        let mut cache = PreviewCountCache::default();
        cache.refresh(
            [(1, 1), (2, 3), (4, 4)]
                .iter()
                .map(|(current, proposed)| (current, proposed)),
        );

        assert!(cache.refresh_one(3, true, false));
        assert_eq!(cache.with_selected(0).changed, 0);
        assert!(cache.refresh_one(3, false, true));
        assert_eq!(cache.with_selected(0).changed, 1);
        assert!(cache.refresh_one(3, true, true));
        assert_eq!(cache.with_selected(0).changed, 1);
        let before = cache;
        assert!(!cache.refresh_one(4, false, true));
        assert_eq!(cache, before);
    }

    fn preview_test_destination_key(
        parent: &darknamer_core::LegacyText,
        leaf: &darknamer_core::LegacyText,
    ) -> crate::rename::PathKey {
        fn push_ascii_folded(output: &mut Vec<u16>, text: &darknamer_core::LegacyText) {
            output.extend(text.units().iter().map(|unit| {
                if (b'A' as u16..=b'Z' as u16).contains(unit) {
                    unit + u16::from(b'a' - b'A')
                } else {
                    *unit
                }
            }));
        }

        let mut path = Vec::with_capacity(parent.len() + 1 + leaf.len());
        push_ascii_folded(&mut path, parent);
        path.push(b'\\' as u16);
        push_ascii_folded(&mut path, leaf);
        crate::rename::PathKey::exact(&darknamer_core::LegacyText::from_units(path))
    }

    struct PreviewTestRow {
        parent: LegacyText,
        current: LegacyText,
        proposed: LegacyText,
        is_directory: bool,
    }

    fn refresh_test_rows(cache: &mut PreviewIssueCache, rows: &[PreviewTestRow]) {
        cache.refresh_by(
            rows.iter()
                .map(|row| (&row.parent, &row.current, &row.proposed, row.is_directory)),
            preview_test_destination_key,
        );
    }

    fn rendered_test_statuses(
        cache: &PreviewIssueCache,
        rows: &[PreviewTestRow],
    ) -> Vec<&'static str> {
        rows.iter()
            .enumerate()
            .map(|(row, item)| {
                preview_status_label(cache.issue(row), item.current != item.proposed)
            })
            .collect()
    }

    #[test]
    fn incremental_preview_matches_full_refresh_across_collision_boundaries() {
        use std::cell::Cell;

        let work = LegacyText::from(r"C:\work");
        let other = LegacyText::from(r"C:\other");
        let mut rows = vec![
            PreviewTestRow {
                parent: work.clone(),
                current: LegacyText::from("a.txt"),
                proposed: LegacyText::from("first.txt"),
                is_directory: false,
            },
            PreviewTestRow {
                parent: work.clone(),
                current: LegacyText::from("b.txt"),
                proposed: LegacyText::from("second.txt"),
                is_directory: false,
            },
            PreviewTestRow {
                parent: work.clone(),
                current: LegacyText::from("occupied.txt"),
                proposed: LegacyText::from("occupied.txt"),
                is_directory: false,
            },
            PreviewTestRow {
                parent: other,
                current: LegacyText::from("c.txt"),
                proposed: LegacyText::from("first.txt"),
                is_directory: false,
            },
            PreviewTestRow {
                parent: work.clone(),
                current: LegacyText::from("d.txt"),
                proposed: LegacyText::from("clean.txt"),
                is_directory: false,
            },
            PreviewTestRow {
                parent: work.clone(),
                current: LegacyText::from("e.jpg"),
                proposed: LegacyText::from(".txt"),
                is_directory: false,
            },
            PreviewTestRow {
                parent: work.clone(),
                current: LegacyText::from("f.jpg"),
                proposed: LegacyText::from("spare.txt"),
                is_directory: false,
            },
            PreviewTestRow {
                parent: work,
                current: LegacyText::from("bad?.txt"),
                proposed: LegacyText::from("bad?.txt"),
                is_directory: false,
            },
        ];
        let mut incremental = PreviewIssueCache::default();
        refresh_test_rows(&mut incremental, &rows);

        for (edited_row, proposal) in [
            (1, "FIRST.txt"),
            (0, "occupied.txt"),
            (1, "OCCUPIED.TXT"),
            (4, "bad?.txt"),
            (3, "occupied.txt"),
            (6, ".TXT"),
            (6, "spare.txt"),
            (0, "first.txt"),
            (0, "FIRST.TXT"),
        ] {
            let before_statuses = rendered_test_statuses(&incremental, &rows);
            let previous_changed = rows[edited_row].current != rows[edited_row].proposed;
            rows[edited_row].proposed = LegacyText::from(proposal);
            let current_changed = rows[edited_row].current != rows[edited_row].proposed;
            let calls = Cell::new(0_usize);
            let update = incremental.refresh_one_by(
                rows.len(),
                edited_row,
                (
                    &rows[edited_row].parent,
                    &rows[edited_row].current,
                    &rows[edited_row].proposed,
                    rows[edited_row].is_directory,
                ),
                |parent, leaf| {
                    calls.set(calls.get() + 1);
                    preview_test_destination_key(parent, leaf)
                },
            );
            assert!(
                update.is_some(),
                "incremental update rejected row {edited_row}"
            );
            let update = update.unwrap_or_default();
            assert_eq!(calls.get(), 1, "row {edited_row}");
            assert_eq!(update.previous_changed, previous_changed);
            assert_eq!(update.current_changed, current_changed);

            let mut full = PreviewIssueCache::default();
            refresh_test_rows(&mut full, &rows);
            let after_statuses = rendered_test_statuses(&full, &rows);
            let status_changes = before_statuses
                .iter()
                .zip(&after_statuses)
                .enumerate()
                .filter_map(|(row, (before, after))| (before != after).then_some(row))
                .collect::<Vec<_>>();
            assert!(
                status_changes
                    .iter()
                    .all(|row| update.affected_rows.contains(row)),
                "row {edited_row}: missing status rows {status_changes:?} from {:?}",
                update.affected_rows
            );
            assert_eq!(incremental, full, "row {edited_row}: {proposal}");
        }

        assert_eq!(
            incremental.issue(4),
            PreviewRowIssue::InvalidName(WindowsLeafNameError::InvalidCharacter)
        );
        assert_eq!(incremental.issue(5), PreviewRowIssue::EmptyStem);
        assert_eq!(incremental.issue(7), PreviewRowIssue::None);
    }

    #[test]
    fn incremental_preview_falls_back_without_mutating_an_invalid_cache_boundary() {
        use std::cell::Cell;

        let parent = LegacyText::from(r"C:\work");
        let current = LegacyText::from("a.txt");
        let proposed = LegacyText::from("b.txt");
        let calls = Cell::new(0_usize);
        let key = |parent: &LegacyText, leaf: &LegacyText| {
            calls.set(calls.get() + 1);
            preview_test_destination_key(parent, leaf)
        };
        let mut uninitialized = PreviewIssueCache::default();
        let before_uninitialized = uninitialized.clone();
        assert!(
            uninitialized
                .refresh_one_by(1, 0, (&parent, &current, &proposed, false), key)
                .is_none()
        );
        assert_eq!(uninitialized, before_uninitialized);
        assert_eq!(calls.get(), 0);

        let mut initialized = PreviewIssueCache::default();
        initialized.refresh_by(
            [(&parent, &current, &current, false)],
            preview_test_destination_key,
        );
        for (model_len, row) in [(2, 0), (1, 1)] {
            let before = initialized.clone();
            assert!(
                initialized
                    .refresh_one_by(model_len, row, (&parent, &current, &proposed, false), key,)
                    .is_none()
            );
            assert_eq!(initialized, before);
        }
        assert_eq!(calls.get(), 0);
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
        assert!(Rc::ptr_eq(
            &cache.rows[0].destination_key,
            &cache.rows[1].destination_key
        ));
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
