use super::*;

pub(super) fn admit_drop(owner: HWND, state: &mut AppState, drop: HDROP) {
    // SAFETY: drop is the live WM_DROPFILES HDROP; any output pointer has exactly the capacity passed.
    let reported = unsafe { DragQueryFileW(drop, u32::MAX, null_mut(), 0) } as usize;
    let remaining = MAX_ADMITTED_SOURCES.saturating_sub(state.model.len());
    let bounded = bounded_selection(reported, remaining);
    let mut paths = Vec::with_capacity(bounded.take);
    for index in 0..bounded.take {
        let index = u32::try_from(index).unwrap_or(u32::MAX);
        // SAFETY: drop is the live WM_DROPFILES HDROP; any output pointer has exactly the capacity passed.
        let length = unsafe { DragQueryFileW(drop, index, null_mut(), 0) };
        let mut buffer = vec![0; length as usize + 1];
        // SAFETY: drop is the live WM_DROPFILES HDROP; any output pointer has exactly the capacity passed.
        unsafe { DragQueryFileW(drop, index, buffer.as_mut_ptr(), buffer.len() as u32) };
        buffer.truncate(length as usize);
        paths.push(PathBuf::from(std::ffi::OsString::from_wide(&buffer)));
    }
    // SAFETY: drop is the owned WM_DROPFILES HDROP and is released exactly once after extraction.
    unsafe { DragFinish(drop) };
    if bounded.truncated {
        message(
            owner,
            "선택 항목이 남은 10,000개 한도를 초과해 제한된 수만 처리합니다.",
            "DarkReNamer - 추가 한도",
        );
    }
    admit_paths(owner, state, paths);
}
