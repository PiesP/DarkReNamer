#![forbid(unsafe_code)]

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct HorizontalWindowPlacement {
    pub(crate) x: i32,
    pub(crate) width: i32,
}

/// Effective top-level minimum size after applying the nearest monitor bounds.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct WindowTrackSize {
    pub(crate) width: i32,
    pub(crate) height: i32,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct WindowOrigin {
    pub(crate) x: i32,
    pub(crate) y: i32,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct WorkAreaBounds {
    pub(crate) left: i32,
    pub(crate) top: i32,
    pub(crate) right: i32,
    pub(crate) bottom: i32,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct WindowPlacement {
    pub(crate) x: i32,
    pub(crate) y: i32,
    pub(crate) width: i32,
    pub(crate) height: i32,
}

/// Fits a requested top-level window within a positive monitor work area.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn fit_window_to_work_area(
    origin: WindowOrigin,
    requested: WindowTrackSize,
    work: WorkAreaBounds,
) -> Option<WindowPlacement> {
    let work_width = work.right.checked_sub(work.left)?;
    let work_height = work.bottom.checked_sub(work.top)?;
    if requested.width <= 0 || requested.height <= 0 || work_width <= 0 || work_height <= 0 {
        return None;
    }
    let width = requested.width.min(work_width);
    let height = requested.height.min(work_height);
    let latest_x = work.right - width;
    let latest_y = work.bottom - height;
    Some(WindowPlacement {
        x: origin.x.clamp(work.left, latest_x),
        y: origin.y.clamp(work.top, latest_y),
        width,
        height,
    })
}

/// Constrains a requested top-level minimum size to a positive monitor work area.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn constrain_minimum_track_size_to_work_area(
    minimum_width: i32,
    minimum_height: i32,
    work_width: i32,
    work_height: i32,
) -> Option<WindowTrackSize> {
    if minimum_width <= 0 || minimum_height <= 0 || work_width <= 0 || work_height <= 0 {
        return None;
    }
    Some(WindowTrackSize {
        width: minimum_width.min(work_width),
        height: minimum_height.min(work_height),
    })
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn fit_widened_window_to_work_area(
    current_x: i32,
    work_left: i32,
    work_right: i32,
    minimum_width: i32,
) -> Option<HorizontalWindowPlacement> {
    let work_width = work_right.checked_sub(work_left)?;
    if work_width <= 0 || minimum_width <= 0 {
        return None;
    }
    let width = minimum_width.min(work_width);
    let latest_x = work_right - width;
    Some(HorizontalWindowPlacement {
        x: current_x.clamp(work_left, latest_x),
        width,
    })
}
