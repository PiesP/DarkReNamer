#![forbid(unsafe_code)]

/// Major focus regions in the native workbench.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum FocusChild {
    #[default]
    List,
    LeftRail,
    RightRail,
}

/// Borrow-free focus action selected by the platform-neutral state machine.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum FocusAction {
    List,
    LeftRail(usize),
    RightRail(usize),
}

/// Platform-neutral state for roving focus within the two command rails.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct FocusState {
    pub(crate) last_child: FocusChild,
    pub(crate) left_rail_index: usize,
    pub(crate) right_rail_index: usize,
}

#[cfg(any(windows, test))]
impl FocusState {
    pub(crate) const fn action(self) -> FocusAction {
        match self.last_child {
            FocusChild::List => FocusAction::List,
            FocusChild::LeftRail => FocusAction::LeftRail(self.left_rail_index),
            FocusChild::RightRail => FocusAction::RightRail(self.right_rail_index),
        }
    }

    pub(crate) fn record(&mut self, child: FocusChild, rail_index: Option<usize>) {
        self.last_child = child;
        match (child, rail_index) {
            (FocusChild::LeftRail, Some(index)) => self.left_rail_index = index,
            (FocusChild::RightRail, Some(index)) => self.right_rail_index = index,
            _ => {}
        }
    }

    pub(crate) fn repair(
        &mut self,
        left_enabled: &[bool],
        right_enabled: &[bool],
        rails_visible: bool,
    ) {
        let left = rails_visible
            .then(|| repair_focus_index(self.left_rail_index, left_enabled))
            .flatten();
        let right = rails_visible
            .then(|| repair_focus_index(self.right_rail_index, right_enabled))
            .flatten();
        if let Some(index) = left {
            self.left_rail_index = index;
        }
        if let Some(index) = right {
            self.right_rail_index = index;
        }
        if matches!(self.last_child, FocusChild::LeftRail) && left.is_none()
            || matches!(self.last_child, FocusChild::RightRail) && right.is_none()
        {
            self.last_child = FocusChild::List;
        }
    }

    pub(crate) fn cycle_major(
        &mut self,
        left_enabled: &[bool],
        right_enabled: &[bool],
        rails_visible: bool,
    ) -> FocusChild {
        self.repair(left_enabled, right_enabled, rails_visible);
        let available = |child| match child {
            FocusChild::List => true,
            FocusChild::LeftRail => rails_visible && left_enabled.iter().any(|enabled| *enabled),
            FocusChild::RightRail => rails_visible && right_enabled.iter().any(|enabled| *enabled),
        };
        let regions = [
            FocusChild::List,
            FocusChild::LeftRail,
            FocusChild::RightRail,
        ];
        let start = regions
            .iter()
            .position(|child| *child == self.last_child)
            .unwrap_or_default();
        for offset in 1..=regions.len() {
            let child = regions[(start + offset) % regions.len()];
            if available(child) {
                self.last_child = child;
                return child;
            }
        }
        self.last_child = FocusChild::List;
        FocusChild::List
    }

    pub(crate) fn move_within_rail(
        &mut self,
        forward: bool,
        left_enabled: &[bool],
        right_enabled: &[bool],
        rails_visible: bool,
    ) -> Option<(FocusChild, usize)> {
        self.repair(left_enabled, right_enabled, rails_visible);
        let (enabled, current) = match self.last_child {
            FocusChild::List => return None,
            FocusChild::LeftRail => (left_enabled, &mut self.left_rail_index),
            FocusChild::RightRail => (right_enabled, &mut self.right_rail_index),
        };
        let next = adjacent_enabled_index(*current, enabled, forward)?;
        *current = next;
        Some((self.last_child, next))
    }

    pub(crate) fn active_index(
        self,
        child: FocusChild,
        enabled: &[bool],
        rails_visible: bool,
    ) -> Option<usize> {
        if !rails_visible {
            return None;
        }
        let index = match child {
            FocusChild::List => return None,
            FocusChild::LeftRail => self.left_rail_index,
            FocusChild::RightRail => self.right_rail_index,
        };
        enabled
            .get(index)
            .copied()
            .unwrap_or(false)
            .then_some(index)
    }
}

#[cfg(any(windows, test))]
fn repair_focus_index(current: usize, enabled: &[bool]) -> Option<usize> {
    enabled
        .get(current)
        .copied()
        .unwrap_or(false)
        .then_some(current)
        .or_else(|| enabled.iter().position(|enabled| *enabled))
}

#[cfg(any(windows, test))]
fn adjacent_enabled_index(current: usize, enabled: &[bool], forward: bool) -> Option<usize> {
    if enabled.is_empty() || !enabled.iter().any(|enabled| *enabled) {
        return None;
    }
    for offset in 1..=enabled.len() {
        let index = if forward {
            current.wrapping_add(offset) % enabled.len()
        } else {
            current.wrapping_add(enabled.len()).wrapping_sub(offset) % enabled.len()
        };
        if enabled[index] {
            return Some(index);
        }
    }
    None
}
