use std::mem::size_of;
use std::ptr::{NonNull, null_mut};

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    ClientToScreen, CreatePen, CreateSolidBrush, DeleteObject, FillRect, GetDC, HDC, HGDIOBJ,
    PS_SOLID, Polygon, ReleaseDC, RestoreDC, SaveDC, ScreenToClient, SelectObject,
};
use windows_sys::Win32::UI::Shell::{
    DefSubclassProc, GetWindowSubclass, RemoveWindowSubclass, SetWindowSubclass,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    EnumThreadWindows, GetClassNameW, GetClientRect, GetMenu, GetMenuItemCount, GetMenuItemInfoW,
    GetMenuItemRect, GetSubMenu, GetWindowRect, GetWindowThreadProcessId, HMENU, IsMenu,
    IsWindowVisible, MENUITEMINFOW, MFS_DISABLED, MFS_HILITE, MIIM_STATE, MIIM_SUBMENU,
    WM_NCDESTROY, WM_PAINT,
};

use super::{SemanticPalette, scale_dip};

const POPUP_CLASS: &[u16] = &[
    b'#' as u16,
    b'3' as u16,
    b'2' as u16,
    b'7' as u16,
    b'6' as u16,
    b'8' as u16,
    0,
];
const POPUP_SUBCLASS_ID: usize = 0xD4B5;
const MAX_MENU_DEPTH: usize = 8;
const MAX_MENU_NODES: usize = 64;
const MAX_MENU_ITEMS: usize = 512;
const MAX_POPUP_CANDIDATES: usize = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct PopupMenuPalette {
    background: u32,
    selected_background: u32,
    disabled_selected_background: u32,
    foreground: u32,
    disabled_foreground: u32,
}

impl PopupMenuPalette {
    pub(super) const fn from_semantic(palette: SemanticPalette) -> Self {
        Self {
            background: palette.surface_window,
            selected_background: palette.control_hover,
            disabled_selected_background: palette.control_disabled,
            foreground: palette.text_primary,
            disabled_foreground: palette.text_disabled,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum PopupMenuUpdate {
    Installed,
    Refreshed,
    Retry,
    Rejected,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct PopupMenuRequest {
    root: HMENU,
    target: HMENU,
    attempts: u8,
    required: bool,
}

impl PopupMenuRequest {
    pub(super) const fn new(root: HMENU, target: HMENU, required: bool) -> Self {
        Self {
            root,
            target,
            attempts: 0,
            required,
        }
    }

    pub(super) const fn root(self) -> HMENU {
        self.root
    }

    pub(super) const fn target(self) -> HMENU {
        self.target
    }

    pub(super) const fn required(self) -> bool {
        self.required
    }

    pub(super) fn retry(mut self) -> Option<Self> {
        self.attempts = self.attempts.checked_add(1)?;
        (self.attempts <= 3).then_some(self)
    }
}

#[derive(Default)]
pub(super) struct PendingPopupMenuRequests {
    requests: Vec<PopupMenuRequest>,
}

impl PendingPopupMenuRequests {
    const MAX_REQUESTS: usize = 8;

    pub(super) fn push(&mut self, request: PopupMenuRequest) -> bool {
        if request.root.is_null()
            || request.target.is_null()
            || self
                .requests
                .iter()
                .any(|queued| queued.root == request.root && queued.target == request.target)
        {
            return false;
        }
        if self.requests.len() >= Self::MAX_REQUESTS {
            return false;
        }
        self.requests.push(request);
        true
    }

    pub(super) fn take(&mut self) -> Vec<PopupMenuRequest> {
        std::mem::take(&mut self.requests)
    }

    pub(super) fn clear(&mut self) {
        self.requests.clear();
    }

    #[cfg(test)]
    pub(super) fn len(&self) -> usize {
        self.requests.len()
    }
}

#[derive(Clone, Copy)]
struct PopupCandidate {
    window: HWND,
    thread_id: u32,
    process_id: u32,
    visible: bool,
    popup_class: bool,
    window_bounds: RECT,
    client_bounds: RECT,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CandidateResolution {
    Unique(HWND),
    None,
    Ambiguous,
}

fn rect_has_area(rect: RECT) -> bool {
    rect.left < rect.right && rect.top < rect.bottom
}

fn rect_contains(outer: RECT, inner: RECT) -> bool {
    rect_has_area(outer)
        && rect_has_area(inner)
        && outer.left <= inner.left
        && outer.top <= inner.top
        && outer.right >= inner.right
        && outer.bottom >= inner.bottom
}

fn rects_overlap(left: RECT, right: RECT) -> bool {
    rect_has_area(left)
        && rect_has_area(right)
        && left.left < right.right
        && left.top < right.bottom
        && left.right > right.left
        && left.bottom > right.top
}

fn resolve_candidate(
    thread_id: u32,
    process_id: u32,
    marker_rects: &[RECT],
    candidates: &[PopupCandidate],
) -> CandidateResolution {
    let mut matched = candidates.iter().filter(|candidate| {
        candidate.thread_id == thread_id
            && candidate.process_id == process_id
            && candidate.visible
            && candidate.popup_class
            && marker_rects.iter().any(|marker| {
                rect_contains(candidate.window_bounds, *marker)
                    // Menu item rectangles may include a one-pixel native edge
                    // outside #32768's client rectangle. Require client overlap
                    // here, then clip the actual paint slot to GetClientRect.
                    && rects_overlap(candidate.client_bounds, *marker)
            })
    });
    let Some(first) = matched.next() else {
        return CandidateResolution::None;
    };
    if matched.next().is_some() {
        CandidateResolution::Ambiguous
    } else {
        CandidateResolution::Unique(first.window)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MenuScope {
    Contains,
    DoesNotContain,
    Invalid,
    BoundsExceeded,
}

pub(super) fn menu_belongs_to_root(root: HMENU, target: HMENU) -> bool {
    matches!(menu_scope(root, target), MenuScope::Contains)
}

fn menu_scope(root: HMENU, target: HMENU) -> MenuScope {
    if root.is_null() || target.is_null() {
        return MenuScope::Invalid;
    }
    // SAFETY: only handle validity is queried; invalid or stale values are
    // rejected before any menu item traversal.
    if unsafe { IsMenu(root) } == 0 || unsafe { IsMenu(target) } == 0 {
        return MenuScope::Invalid;
    }
    let mut pending = Vec::with_capacity(MAX_MENU_NODES);
    pending.push((root, 0_usize));
    let mut visited = Vec::with_capacity(MAX_MENU_NODES);
    let mut inspected_items = 0_usize;
    while let Some((menu, depth)) = pending.pop() {
        if visited.contains(&menu) {
            continue;
        }
        if visited.len() >= MAX_MENU_NODES || depth > MAX_MENU_DEPTH {
            return MenuScope::BoundsExceeded;
        }
        visited.push(menu);
        if menu == target {
            return MenuScope::Contains;
        }
        // SAFETY: menu was reached from a validated live root. A concurrent
        // stale transition is reported as invalid rather than traversed.
        let count = unsafe { GetMenuItemCount(menu) };
        if count < 0 {
            return MenuScope::Invalid;
        }
        let Ok(count) = usize::try_from(count) else {
            return MenuScope::BoundsExceeded;
        };
        inspected_items = match inspected_items.checked_add(count) {
            Some(total) if total <= MAX_MENU_ITEMS => total,
            _ => return MenuScope::BoundsExceeded,
        };
        if depth == MAX_MENU_DEPTH && count != 0 {
            return MenuScope::BoundsExceeded;
        }
        for position in 0..count {
            // SAFETY: position is bounded by the current live menu count and
            // GetSubMenu returns only a borrowed child handle.
            let child = unsafe { GetSubMenu(menu, i32::try_from(position).unwrap_or(i32::MAX)) };
            if !child.is_null() {
                if pending.len() >= MAX_MENU_NODES {
                    return MenuScope::BoundsExceeded;
                }
                pending.push((child, depth + 1));
            }
        }
    }
    MenuScope::DoesNotContain
}

fn popup_menu_marker_rects(menu: HMENU) -> Option<Vec<RECT>> {
    // SAFETY: menu validity was established by the current-root traversal.
    let count = unsafe { GetMenuItemCount(menu) };
    if count <= 0 || usize::try_from(count).ok()? > MAX_MENU_ITEMS {
        return None;
    }
    let mut markers = Vec::new();
    for position in 0..u32::try_from(count).ok()? {
        let mut info = MENUITEMINFOW {
            cbSize: size_of::<MENUITEMINFOW>() as u32,
            fMask: MIIM_SUBMENU,
            ..MENUITEMINFOW::default()
        };
        // SAFETY: position is bounded by the live menu count and info is exact
        // writable ABI storage.
        if unsafe { GetMenuItemInfoW(menu, position, 1, &mut info) } == 0 {
            return None;
        }
        if info.hSubMenu.is_null() {
            continue;
        }
        let mut item = RECT::default();
        // SAFETY: null HWND is the documented popup-menu form; menu and
        // position are live and bounded, and item is writable storage.
        if unsafe { GetMenuItemRect(null_mut(), menu, position, &mut item) } == 0
            || !rect_has_area(item)
        {
            return None;
        }
        markers.push(item);
    }
    Some(markers)
}

struct CandidateCollector {
    thread_id: u32,
    process_id: u32,
    candidates: Vec<PopupCandidate>,
    overflowed: bool,
}

unsafe extern "system" fn collect_popup_candidate(window: HWND, lparam: LPARAM) -> i32 {
    let Some(mut collector) = NonNull::new(lparam as *mut CandidateCollector) else {
        return 0;
    };
    // SAFETY: EnumThreadWindows synchronously retains the stack-owned collector
    // for this callback only, on the same UI thread.
    let collector = unsafe { collector.as_mut() };
    if collector.candidates.len() >= MAX_POPUP_CANDIDATES {
        collector.overflowed = true;
        return 0;
    }
    let mut process_id = 0_u32;
    // SAFETY: window is supplied by EnumThreadWindows and process_id is live
    // writable scalar storage.
    let thread_id = unsafe { GetWindowThreadProcessId(window, &mut process_id) };
    let mut class_name = [0_u16; 16];
    // SAFETY: window is system-enumerated and class_name is writable storage.
    let class_length = unsafe {
        GetClassNameW(
            window,
            class_name.as_mut_ptr(),
            i32::try_from(class_name.len()).unwrap_or(i32::MAX),
        )
    };
    let popup_class = usize::try_from(class_length)
        .ok()
        .and_then(|length| class_name.get(..length))
        == Some(&POPUP_CLASS[..POPUP_CLASS.len() - 1]);
    let mut bounds = RECT::default();
    // SAFETY: both queries inspect only the system-enumerated window.
    let visible = unsafe { IsWindowVisible(window) } != 0;
    // SAFETY: bounds is exact writable RECT storage for the query.
    let got_bounds = unsafe { GetWindowRect(window, &mut bounds) } != 0;
    let mut client = RECT::default();
    // SAFETY: client is writable and window is system-enumerated.
    let got_client = unsafe { GetClientRect(window, &mut client) } != 0;
    let mut client_top_left = POINT {
        x: client.left,
        y: client.top,
    };
    let mut client_bottom_right = POINT {
        x: client.right,
        y: client.bottom,
    };
    // SAFETY: points are writable and window is system-enumerated.
    let converted_top_left = unsafe { ClientToScreen(window, &mut client_top_left) } != 0;
    // SAFETY: same exact window and writable coordinate storage.
    let converted_bottom_right = unsafe { ClientToScreen(window, &mut client_bottom_right) } != 0;
    let client_bounds = RECT {
        left: client_top_left.x,
        top: client_top_left.y,
        right: client_bottom_right.x,
        bottom: client_bottom_right.y,
    };
    if thread_id == collector.thread_id
        && process_id == collector.process_id
        && visible
        && popup_class
        && got_bounds
        && got_client
        && converted_top_left
        && converted_bottom_right
        && rect_has_area(client_bounds)
    {
        collector.candidates.push(PopupCandidate {
            window,
            thread_id,
            process_id,
            visible,
            popup_class,
            window_bounds: bounds,
            client_bounds,
        });
    }
    1
}

fn resolve_popup_window(owner: HWND, menu: HMENU, marker_rects: &[RECT]) -> CandidateResolution {
    let mut process_id = 0_u32;
    // SAFETY: owner is the current application window and process_id is live
    // writable scalar storage.
    let thread_id = unsafe { GetWindowThreadProcessId(owner, &mut process_id) };
    if thread_id == 0 || process_id == 0 {
        return CandidateResolution::None;
    }
    let mut collector = CandidateCollector {
        thread_id,
        process_id,
        candidates: Vec::new(),
        overflowed: false,
    };
    // SAFETY: enumeration is synchronous on the owner's exact UI thread; the
    // stack collector remains live for every callback.
    unsafe {
        EnumThreadWindows(
            thread_id,
            Some(collect_popup_candidate),
            (&mut collector as *mut CandidateCollector) as LPARAM,
        )
    };
    if collector.overflowed {
        return CandidateResolution::Ambiguous;
    }
    let result = resolve_candidate(thread_id, process_id, marker_rects, &collector.candidates);
    if let CandidateResolution::Unique(window) = result {
        // Keep the target menu part of the decision: a stale menu may retain
        // old coordinates briefly, but cannot be accepted as a live HMENU.
        // SAFETY: this scalar query does not dereference application storage.
        if unsafe { IsMenu(menu) } == 0 {
            return CandidateResolution::None;
        }
        return CandidateResolution::Unique(window);
    }
    result
}

#[derive(Clone, Copy)]
struct PopupSubclassContext {
    owner: HWND,
    popup: HWND,
    root: HMENU,
    menu: HMENU,
    palette: PopupMenuPalette,
    dpi: u32,
    generation: usize,
    callback_active: bool,
    painting: bool,
}

struct OwnedGdiObject(HGDIOBJ);

impl OwnedGdiObject {
    fn brush(color: u32) -> Option<Self> {
        // SAFETY: COLORREF is a scalar and ownership of the returned brush is
        // transferred to this wrapper.
        NonNull::new(unsafe { CreateSolidBrush(color) }).map(|brush| Self(brush.as_ptr()))
    }

    fn pen(color: u32) -> Option<Self> {
        // SAFETY: the solid one-pixel pen has no caller-owned backing storage.
        NonNull::new(unsafe { CreatePen(PS_SOLID, 1, color) }).map(|pen| Self(pen.as_ptr()))
    }

    const fn as_raw(&self) -> HGDIOBJ {
        self.0
    }
}

impl Drop for OwnedGdiObject {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: the paint DC is restored before these objects drop, so
            // this wrapper still owns an unselected GDI object.
            unsafe { DeleteObject(self.0) };
            self.0 = null_mut();
        }
    }
}

struct PopupDc {
    window: HWND,
    dc: HDC,
}

impl PopupDc {
    fn acquire(window: HWND) -> Option<Self> {
        // SAFETY: window was uniquely resolved as the live popup HWND. The DC
        // is paired with ReleaseDC on every path.
        let dc = unsafe { GetDC(window) };
        (!dc.is_null()).then_some(Self { window, dc })
    }
}

impl Drop for PopupDc {
    fn drop(&mut self) {
        if !self.dc.is_null() {
            // SAFETY: this is the exact DC acquired for the exact popup HWND.
            unsafe { ReleaseDC(self.window, self.dc) };
            self.dc = null_mut();
        }
    }
}

struct SavedPopupDc {
    dc: HDC,
    state: i32,
}

impl SavedPopupDc {
    fn save(dc: HDC) -> Option<Self> {
        // SAFETY: dc is the live popup client DC; SaveDC snapshots every
        // mutable GDI attribute before local objects are selected.
        let state = unsafe { SaveDC(dc) };
        (state != 0).then_some(Self { dc, state })
    }
}

impl Drop for SavedPopupDc {
    fn drop(&mut self) {
        // SAFETY: this exact state belongs to the same still-live popup DC.
        unsafe { RestoreDC(self.dc, self.state) };
    }
}

fn intersect_rect(left: RECT, right: RECT) -> Option<RECT> {
    let intersection = RECT {
        left: left.left.max(right.left),
        top: left.top.max(right.top),
        right: left.right.min(right.right),
        bottom: left.bottom.min(right.bottom),
    };
    rect_has_area(intersection).then_some(intersection)
}

fn marker_slot(item: RECT, client: RECT) -> Option<RECT> {
    let height = item.bottom.checked_sub(item.top)?.max(1);
    let slot = RECT {
        left: item.right.saturating_sub(height).max(item.left),
        top: item.top,
        right: item.right,
        bottom: item.bottom,
    };
    intersect_rect(slot, client)
}

fn marker_triangle(slot: RECT, dpi: u32) -> Option<[POINT; 3]> {
    if !rect_has_area(slot) {
        return None;
    }
    let center_x = slot.left.checked_add((slot.right - slot.left) / 2)?;
    let center_y = slot.top.checked_add((slot.bottom - slot.top) / 2)?;
    let half_height = scale_dip(4, dpi.max(96))
        .max(2)
        .min((slot.bottom - slot.top).saturating_sub(2) / 2);
    let width = scale_dip(4, dpi.max(96))
        .max(2)
        .min((slot.right - slot.left).saturating_sub(2));
    (half_height >= 1 && width >= 1).then_some([
        POINT {
            x: center_x.saturating_sub(width / 2),
            y: center_y.saturating_sub(half_height),
        },
        POINT {
            x: center_x.saturating_add(width.saturating_sub(width / 2)),
            y: center_y,
        },
        POINT {
            x: center_x.saturating_sub(width / 2),
            y: center_y.saturating_add(half_height),
        },
    ])
}

fn paint_popup_markers(context: PopupSubclassContext) -> bool {
    // SAFETY: copied handles are revalidated against the owner's currently
    // attached tree before any item or drawing query.
    if unsafe { GetMenu(context.owner) } != context.root
        || !menu_belongs_to_root(context.root, context.menu)
    {
        return false;
    }
    // SAFETY: context stores only copied scalar handles. Every stale handle
    // makes the corresponding public query fail closed.
    let count = unsafe { GetMenuItemCount(context.menu) };
    if count < 0 || usize::try_from(count).map_or(true, |count| count > MAX_MENU_ITEMS) {
        return false;
    }
    let background = match OwnedGdiObject::brush(context.palette.background) {
        Some(brush) => brush,
        None => return false,
    };
    let selected = match OwnedGdiObject::brush(context.palette.selected_background) {
        Some(brush) => brush,
        None => return false,
    };
    let disabled_selected =
        match OwnedGdiObject::brush(context.palette.disabled_selected_background) {
            Some(brush) => brush,
            None => return false,
        };
    let foreground = match OwnedGdiObject::brush(context.palette.foreground) {
        Some(brush) => brush,
        None => return false,
    };
    let disabled_foreground = match OwnedGdiObject::brush(context.palette.disabled_foreground) {
        Some(brush) => brush,
        None => return false,
    };
    let foreground_pen = match OwnedGdiObject::pen(context.palette.foreground) {
        Some(pen) => pen,
        None => return false,
    };
    let disabled_pen = match OwnedGdiObject::pen(context.palette.disabled_foreground) {
        Some(pen) => pen,
        None => return false,
    };
    let Some(dc) = PopupDc::acquire(context.popup) else {
        return false;
    };
    let Some(_saved) = SavedPopupDc::save(dc.dc) else {
        return false;
    };
    let mut client = RECT::default();
    // SAFETY: context.popup is the resolved popup and client is writable.
    if unsafe { GetClientRect(context.popup, &mut client) } == 0 {
        return false;
    }
    for position in 0..u32::try_from(count).unwrap_or_default() {
        let mut info = MENUITEMINFOW {
            cbSize: size_of::<MENUITEMINFOW>() as u32,
            fMask: MIIM_STATE | MIIM_SUBMENU,
            ..MENUITEMINFOW::default()
        };
        // SAFETY: position is bounded by the live menu item count and info is
        // exact writable ABI storage.
        if unsafe { GetMenuItemInfoW(context.menu, position, 1, &mut info) } == 0 {
            return false;
        }
        if info.hSubMenu.is_null() {
            continue;
        }
        let mut item = RECT::default();
        // SAFETY: null HWND requests screen coordinates for this live popup.
        if unsafe { GetMenuItemRect(null_mut(), context.menu, position, &mut item) } == 0 {
            return false;
        }
        let mut top_left = POINT {
            x: item.left,
            y: item.top,
        };
        let mut bottom_right = POINT {
            x: item.right,
            y: item.bottom,
        };
        // SAFETY: bottom_right is writable and context.popup is the exact
        // window matched to this menu's screen-coordinate item bounds.
        let converted_bottom_right = unsafe { ScreenToClient(context.popup, &mut bottom_right) };
        // SAFETY: same exact popup and writable top_left storage.
        let converted_top_left = unsafe { ScreenToClient(context.popup, &mut top_left) };
        if converted_top_left == 0 || converted_bottom_right == 0 {
            return false;
        }
        let item = RECT {
            left: top_left.x,
            top: top_left.y,
            right: bottom_right.x,
            bottom: bottom_right.y,
        };
        let Some(slot) = marker_slot(item, client) else {
            // A scrollable menu may report valid rows outside its current
            // viewport. They have no visible marker slot to repaint.
            continue;
        };
        let disabled = info.fState & MFS_DISABLED != 0;
        let highlighted = info.fState & MFS_HILITE != 0;
        let fill = if highlighted && disabled {
            disabled_selected.as_raw()
        } else if highlighted {
            selected.as_raw()
        } else {
            background.as_raw()
        };
        // SAFETY: slot is clipped to the popup client and the local brush stays
        // live until after SavedPopupDc restores the DC.
        unsafe { FillRect(dc.dc, &slot, fill) };
        let Some(points) = marker_triangle(slot, context.dpi) else {
            return false;
        };
        let (brush, pen) = if disabled {
            (disabled_foreground.as_raw(), disabled_pen.as_raw())
        } else {
            (foreground.as_raw(), foreground_pen.as_raw())
        };
        // SAFETY: selected objects remain local and live; SavedPopupDc restores
        // both before any resource deletion or ReleaseDC.
        unsafe {
            SelectObject(dc.dc, brush);
            SelectObject(dc.dc, pen);
            if Polygon(
                dc.dc,
                points.as_ptr(),
                i32::try_from(points.len()).unwrap_or(i32::MAX),
            ) == 0
            {
                return false;
            }
        }
    }
    #[cfg(test)]
    TEST_SUCCESSFUL_PAINTS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    true
}

fn current_subclass_context(window: HWND) -> Option<NonNull<PopupSubclassContext>> {
    let mut ref_data = 0_usize;
    // SAFETY: this only queries the exact proc/id installed by this module and
    // writes one scalar refdata value.
    if unsafe {
        GetWindowSubclass(
            window,
            Some(popup_subclass_proc),
            POPUP_SUBCLASS_ID,
            &mut ref_data,
        )
    } == 0
    {
        return None;
    }
    NonNull::new(ref_data as *mut PopupSubclassContext)
}

fn context_is_current(window: HWND, generation: usize, ref_data: usize) -> bool {
    let mut current = 0_usize;
    // SAFETY: the query writes only current and retains no caller storage.
    let installed = unsafe {
        GetWindowSubclass(
            window,
            Some(popup_subclass_proc),
            POPUP_SUBCLASS_ID,
            &mut current,
        ) != 0
    };
    if !installed || current != ref_data || current == 0 {
        return false;
    }
    // SAFETY: the exact proc/id still publishes the same refdata on this UI
    // thread, and no reentrant call occurs between that query and this scalar
    // generation read.
    (unsafe { std::ptr::addr_of!((*(current as *const PopupSubclassContext)).generation).read() })
        == generation
}

unsafe extern "system" fn popup_subclass_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    subclass_id: usize,
    ref_data: usize,
) -> LRESULT {
    if subclass_id != POPUP_SUBCLASS_ID || ref_data == 0 {
        // SAFETY: unchanged values continue through the system-owned chain.
        return unsafe { DefSubclassProc(window, message, wparam, lparam) };
    }
    let context_ptr = ref_data as *mut PopupSubclassContext;
    // SAFETY: the exact installed refdata remains Box-owned until this proc's
    // WM_NCDESTROY path. Copying ends the temporary reference before any
    // system call can reenter destruction.
    let context = unsafe { *context_ptr };
    if message == WM_NCDESTROY {
        // SAFETY: this removes only this proc/id from the exact live popup.
        let removed = unsafe {
            RemoveWindowSubclass(window, Some(popup_subclass_proc), POPUP_SUBCLASS_ID) != 0
        };
        // SAFETY: no Rust reference is held across default processing; the Box
        // remains allocated for any synchronous nested entry.
        let result = unsafe { DefSubclassProc(window, message, wparam, lparam) };
        if removed {
            // SAFETY: WM_NCDESTROY is the unique terminal callback for this
            // installation and successful removal detached every future
            // callback reference before forwarding.
            unsafe { drop(Box::from_raw(context_ptr)) };
            #[cfg(test)]
            {
                TEST_LIVE_CONTEXTS.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                TEST_DESTROYED_CONTEXTS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
        }
        return result;
    }
    if context.callback_active {
        // A nested notification cannot mutate or retire the outer callback's
        // context. The outer frame performs the final generation check.
        // SAFETY: unchanged arguments continue through the system chain.
        return unsafe { DefSubclassProc(window, message, wparam, lparam) };
    }
    // SAFETY: the exact context is installed and no callback frame is active.
    unsafe { std::ptr::addr_of_mut!((*context_ptr).callback_active).write(true) };
    if message != WM_PAINT || context.painting {
        // SAFETY: copied context values are unused and unchanged callback
        // arguments continue through the system-owned chain.
        let result = unsafe { DefSubclassProc(window, message, wparam, lparam) };
        if context_is_current(window, context.generation, ref_data) {
            // SAFETY: the same generation remains installed after forwarding.
            unsafe { std::ptr::addr_of_mut!((*context_ptr).callback_active).write(false) };
        }
        return result;
    }
    // SAFETY: this exact context is still installed at callback entry and the
    // field is changed without creating a reference that crosses reentry.
    unsafe { std::ptr::addr_of_mut!((*context_ptr).painting).write(true) };
    // SAFETY: default painting must complete first so the native cascade marker
    // is present before the reserved slot is repainted.
    let result = unsafe { DefSubclassProc(window, message, wparam, lparam) };
    if !context_is_current(window, context.generation, ref_data) {
        return result;
    }
    // A post-install GDI failure cannot broaden the target or mutate AppState;
    // a later native WM_PAINT retries the same bounded path.
    let _painted = paint_popup_markers(context);
    // Re-check after GDI calls because they can dispatch destruction. Never
    // dereference stale refdata after a failed exact generation query.
    if context_is_current(window, context.generation, ref_data) {
        // SAFETY: the exact refdata/generation remains installed on this HWND.
        unsafe {
            std::ptr::addr_of_mut!((*context_ptr).painting).write(false);
            std::ptr::addr_of_mut!((*context_ptr).callback_active).write(false);
        }
    }
    result
}

fn install_or_refresh_subclass(
    owner: HWND,
    popup: HWND,
    root: HMENU,
    menu: HMENU,
    palette: PopupMenuPalette,
    dpi: u32,
) -> PopupMenuUpdate {
    if let Some(existing) = current_subclass_context(popup) {
        // SAFETY: GetWindowSubclass proved this exact module-owned Box is still
        // installed on the same thread. Copy before any removal call.
        let existing_value = unsafe { *existing.as_ptr() };
        if existing_value.owner != owner
            || existing_value.popup != popup
            || existing_value.root != root
            || existing_value.menu != menu
        {
            return PopupMenuUpdate::Failed;
        }
        if existing_value.callback_active || existing_value.painting {
            return PopupMenuUpdate::Retry;
        }
        if existing_value.palette != palette || existing_value.dpi != dpi {
            // SAFETY: the exact context remains installed on this UI thread,
            // and callback_active proves no frame can retain the old scalars.
            unsafe {
                std::ptr::addr_of_mut!((*existing.as_ptr()).palette).write(palette);
                std::ptr::addr_of_mut!((*existing.as_ptr()).dpi).write(dpi);
            }
        }
        // SAFETY: the exact context remains installed, inactive, and confined
        // to this UI thread after the scalar updates above.
        let refreshed = unsafe { *existing.as_ptr() };
        // Selection and palette refresh work runs only from the owner's posted
        // pointer-free callback, after native popup processing has completed.
        let _painted = paint_popup_markers(refreshed);
        return PopupMenuUpdate::Refreshed;
    }
    let generation = next_generation();
    let context = Box::new(PopupSubclassContext {
        owner,
        popup,
        root,
        menu,
        palette,
        dpi,
        generation,
        callback_active: false,
        painting: false,
    });
    let context = Box::into_raw(context);
    // SAFETY: popup was uniquely scoped to owner/menu. Successful installation
    // transfers the Box to popup_subclass_proc until WM_NCDESTROY. An existing
    // installation is refreshed in place and never replaced while callbacks
    // might retain its refdata.
    if unsafe {
        SetWindowSubclass(
            popup,
            Some(popup_subclass_proc),
            POPUP_SUBCLASS_ID,
            context as usize,
        )
    } == 0
    {
        // SAFETY: failed installation retained no refdata pointer.
        unsafe { drop(Box::from_raw(context)) };
        return PopupMenuUpdate::Failed;
    }
    #[cfg(test)]
    {
        TEST_LIVE_CONTEXTS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        TEST_INSTALLED_CONTEXTS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }
    // The owner reached this installer through a deferred callback after the
    // native popup became visible, so direct painting follows native handling
    // without sending application-private messages to the system class.
    // SAFETY: installation still owns this exact live context on this thread.
    let installed = unsafe { *context };
    let _painted = paint_popup_markers(installed);
    PopupMenuUpdate::Installed
}

fn next_generation() -> usize {
    use std::sync::atomic::{AtomicUsize, Ordering};

    static GENERATION: AtomicUsize = AtomicUsize::new(1);
    let generation = GENERATION.fetch_add(1, Ordering::Relaxed);
    if generation == 0 {
        GENERATION.store(2, Ordering::Relaxed);
        1
    } else {
        generation
    }
}

pub(super) fn update_popup_menu(
    owner: HWND,
    root: HMENU,
    target: HMENU,
    palette: PopupMenuPalette,
    dpi: u32,
) -> PopupMenuUpdate {
    if owner.is_null() || root.is_null() || target.is_null() {
        return PopupMenuUpdate::Rejected;
    }
    // SAFETY: owner is the application top-level window. A stale root cannot
    // match the menu currently attached to that exact owner.
    if unsafe { GetMenu(owner) } != root || !menu_belongs_to_root(root, target) {
        return PopupMenuUpdate::Rejected;
    }
    let Some(marker_rects) = popup_menu_marker_rects(target) else {
        return PopupMenuUpdate::Retry;
    };
    if marker_rects.is_empty() {
        return PopupMenuUpdate::Rejected;
    }
    match resolve_popup_window(owner, target, &marker_rects) {
        CandidateResolution::Unique(popup) => {
            install_or_refresh_subclass(owner, popup, root, target, palette, dpi.max(96))
        }
        CandidateResolution::None => PopupMenuUpdate::Retry,
        CandidateResolution::Ambiguous => PopupMenuUpdate::Failed,
    }
}

pub(super) fn refresh_installed_popup_menus(
    owner: HWND,
    root: HMENU,
    palette: PopupMenuPalette,
    dpi: u32,
) -> bool {
    if owner.is_null() || root.is_null() {
        return false;
    }
    // SAFETY: a stale root cannot match the current attached tree.
    if unsafe { GetMenu(owner) } != root {
        return false;
    }
    let mut process_id = 0_u32;
    // SAFETY: owner is live and process_id is writable scalar storage.
    let thread_id = unsafe { GetWindowThreadProcessId(owner, &mut process_id) };
    if thread_id == 0 || process_id == 0 {
        return false;
    }
    let mut collector = CandidateCollector {
        thread_id,
        process_id,
        candidates: Vec::new(),
        overflowed: false,
    };
    // SAFETY: synchronous enumeration retains the stack collector only for
    // callbacks on this exact UI thread.
    unsafe {
        EnumThreadWindows(
            thread_id,
            Some(collect_popup_candidate),
            (&mut collector as *mut CandidateCollector) as LPARAM,
        )
    };
    if collector.overflowed {
        return false;
    }
    for candidate in collector.candidates {
        let Some(context) = current_subclass_context(candidate.window) else {
            continue;
        };
        // SAFETY: the exact proc/id query proved this module-owned context is
        // installed. Copy it before any subclass or paint call.
        let context = unsafe { *context.as_ptr() };
        if context.owner != owner || context.root != root {
            continue;
        }
        if !menu_belongs_to_root(root, context.menu)
            || matches!(
                install_or_refresh_subclass(
                    owner,
                    candidate.window,
                    root,
                    context.menu,
                    palette,
                    dpi.max(96),
                ),
                PopupMenuUpdate::Failed
            )
        {
            return false;
        }
    }
    true
}

#[cfg(test)]
static TEST_LIVE_CONTEXTS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
#[cfg(test)]
static TEST_INSTALLED_CONTEXTS: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(0);
#[cfg(test)]
static TEST_DESTROYED_CONTEXTS: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(0);
#[cfg(test)]
static TEST_SUCCESSFUL_PAINTS: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(0);
#[cfg(test)]
static TEST_ACCEPTED_NOTIFICATIONS: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(0);

#[cfg(test)]
pub(super) fn record_popup_menu_notification() {
    TEST_ACCEPTED_NOTIFICATIONS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
}

#[cfg(test)]
pub(super) fn reset_popup_menu_test_counters() {
    use std::sync::atomic::Ordering;

    TEST_LIVE_CONTEXTS.store(0, Ordering::SeqCst);
    TEST_INSTALLED_CONTEXTS.store(0, Ordering::SeqCst);
    TEST_DESTROYED_CONTEXTS.store(0, Ordering::SeqCst);
    TEST_SUCCESSFUL_PAINTS.store(0, Ordering::SeqCst);
    TEST_ACCEPTED_NOTIFICATIONS.store(0, Ordering::SeqCst);
}

#[cfg(test)]
pub(super) fn popup_menu_test_counters() -> (usize, usize, usize, usize, usize) {
    use std::sync::atomic::Ordering;

    (
        TEST_LIVE_CONTEXTS.load(Ordering::SeqCst),
        TEST_INSTALLED_CONTEXTS.load(Ordering::SeqCst),
        TEST_DESTROYED_CONTEXTS.load(Ordering::SeqCst),
        TEST_SUCCESSFUL_PAINTS.load(Ordering::SeqCst),
        TEST_ACCEPTED_NOTIFICATIONS.load(Ordering::SeqCst),
    )
}

#[cfg(test)]
mod tests {
    use std::io;
    use std::sync::Mutex;
    use std::sync::atomic::Ordering;

    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CreateMenu, CreatePopupMenu, CreateWindowExW, DestroyMenu, DestroyWindow, WS_POPUP,
    };

    use super::*;

    static SUBCLASS_TEST_SERIAL: Mutex<()> = Mutex::new(());

    fn candidate(window: usize, bounds: RECT) -> PopupCandidate {
        PopupCandidate {
            window: window as HWND,
            thread_id: 41,
            process_id: 73,
            visible: true,
            popup_class: true,
            window_bounds: bounds,
            client_bounds: bounds,
        }
    }

    #[test]
    fn popup_candidate_requires_one_scoped_geometry_match_with_negative_coordinates() {
        let menu = RECT {
            left: -3_700,
            top: 120,
            right: -3_120,
            bottom: 940,
        };
        let mut exact = candidate(
            1,
            RECT {
                left: -3_704,
                top: 116,
                right: -3_116,
                bottom: 944,
            },
        );
        exact.client_bounds = RECT {
            left: -3_699,
            top: 121,
            right: -3_121,
            bottom: 939,
        };
        let wrong_monitor = candidate(
            2,
            RECT {
                left: 120,
                top: 120,
                right: 700,
                bottom: 940,
            },
        );
        assert_eq!(
            resolve_candidate(41, 73, &[menu], &[wrong_monitor, exact]),
            CandidateResolution::Unique(1_usize as HWND)
        );

        let duplicate = candidate(
            3,
            RECT {
                left: -3_710,
                top: 110,
                right: -3_110,
                bottom: 950,
            },
        );
        assert_eq!(
            resolve_candidate(41, 73, &[menu], &[exact, duplicate]),
            CandidateResolution::Ambiguous
        );

        let mut foreign = exact;
        foreign.process_id = 74;
        assert_eq!(
            resolve_candidate(41, 73, &[menu], &[foreign]),
            CandidateResolution::None
        );
    }

    #[test]
    fn marker_geometry_stays_inside_the_reserved_trailing_slot()
    -> Result<(), Box<dyn std::error::Error>> {
        let client = RECT {
            left: 0,
            top: 0,
            right: 320,
            bottom: 240,
        };
        let item = RECT {
            left: 4,
            top: 24,
            right: 316,
            bottom: 56,
        };
        let slot = marker_slot(item, client)
            .ok_or_else(|| io::Error::other("valid trailing slot was rejected"))?;
        assert_eq!(
            (slot.left, slot.top, slot.right, slot.bottom),
            (284, 24, 316, 56)
        );
        for dpi in [96, 120, 144, 192, 240, 288] {
            let triangle = marker_triangle(slot, dpi)
                .ok_or_else(|| io::Error::other("visible marker was rejected"))?;
            assert!(triangle.iter().all(|point| {
                point.x >= slot.left
                    && point.x < slot.right
                    && point.y >= slot.top
                    && point.y < slot.bottom
            }));
        }
        Ok(())
    }

    #[test]
    fn current_root_scope_rejects_foreign_and_stale_menus() {
        // SAFETY: these test-owned menu handles are destroyed exactly once.
        let root = unsafe { CreateMenu() };
        // SAFETY: second test-owned popup is transferred to root below.
        let child = unsafe { CreatePopupMenu() };
        // SAFETY: foreign remains independently owned until explicit destroy.
        let foreign = unsafe { CreatePopupMenu() };
        assert!(!root.is_null() && !child.is_null() && !foreign.is_null());
        // SAFETY: success transfers child destruction to root.
        assert_ne!(
            // SAFETY: success transfers child destruction to root.
            unsafe {
                windows_sys::Win32::UI::WindowsAndMessaging::AppendMenuW(
                    root,
                    windows_sys::Win32::UI::WindowsAndMessaging::MF_POPUP,
                    child as usize,
                    null_mut(),
                )
            },
            0
        );
        assert!(menu_belongs_to_root(root, child));
        assert!(!menu_belongs_to_root(root, foreign));
        // SAFETY: foreign is not attached; root recursively destroys child.
        unsafe {
            DestroyMenu(foreign);
            DestroyMenu(root);
        }
        assert!(!menu_belongs_to_root(root, child));
    }

    #[test]
    fn popup_subclass_context_updates_in_place_and_is_released_on_destroy()
    -> Result<(), Box<dyn std::error::Error>> {
        let _serial = SUBCLASS_TEST_SERIAL
            .lock()
            .map_err(|_| io::Error::other("subclass test lock was poisoned"))?;
        TEST_LIVE_CONTEXTS.store(0, Ordering::SeqCst);
        let class = [
            b'S' as u16,
            b'T' as u16,
            b'A' as u16,
            b'T' as u16,
            b'I' as u16,
            b'C' as u16,
            0,
        ];
        // SAFETY: STATIC is a process-global system class; the test owns the
        // hidden popup window through deterministic DestroyWindow.
        let window = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null_mut(),
                WS_POPUP,
                0,
                0,
                64,
                64,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null_mut()),
                null_mut(),
            )
        };
        assert!(!window.is_null());
        // SAFETY: the test-owned menu remains live through scalar refresh.
        let first_menu = unsafe { CreatePopupMenu() };
        assert!(!first_menu.is_null());
        let first = Box::into_raw(Box::new(PopupSubclassContext {
            owner: window,
            popup: window,
            root: first_menu,
            menu: first_menu,
            palette: PopupMenuPalette {
                background: 1,
                selected_background: 2,
                disabled_selected_background: 3,
                foreground: 4,
                disabled_foreground: 5,
            },
            dpi: 96,
            generation: next_generation(),
            callback_active: false,
            painting: false,
        }));
        // SAFETY: the Box remains live until deterministic window destruction.
        assert_ne!(
            // SAFETY: the Box remains live until deterministic window destroy.
            unsafe {
                SetWindowSubclass(
                    window,
                    Some(popup_subclass_proc),
                    POPUP_SUBCLASS_ID,
                    first as usize,
                )
            },
            0
        );
        TEST_LIVE_CONTEXTS.fetch_add(1, Ordering::SeqCst);
        let refreshed_palette = PopupMenuPalette {
            background: 6,
            selected_background: 7,
            disabled_selected_background: 8,
            foreground: 9,
            disabled_foreground: 10,
        };
        assert_eq!(
            install_or_refresh_subclass(
                window,
                window,
                first_menu,
                first_menu,
                refreshed_palette,
                192,
            ),
            PopupMenuUpdate::Refreshed
        );
        assert_eq!(TEST_LIVE_CONTEXTS.load(Ordering::SeqCst), 1);
        let current = current_subclass_context(window)
            .ok_or_else(|| io::Error::other("refreshed context is unavailable"))?;
        // SAFETY: current was returned for this exact installed proc/id.
        let current = unsafe { *current.as_ptr() };
        assert_eq!(current.menu, first_menu);
        assert_eq!(current.palette, refreshed_palette);
        // SAFETY: destruction delivers WM_NCDESTROY to the installed subclass,
        // then the unattached menu handle remains test-owned.
        unsafe {
            DestroyWindow(window);
            DestroyMenu(first_menu);
        }
        assert_eq!(TEST_LIVE_CONTEXTS.load(Ordering::SeqCst), 0);
        Ok(())
    }

    #[test]
    fn pending_requests_are_bounded_and_deduplicated() {
        let mut requests = PendingPopupMenuRequests::default();
        let root = 1_usize as HMENU;
        assert!(requests.push(PopupMenuRequest::new(root, 2_usize as HMENU, true)));
        assert!(!requests.push(PopupMenuRequest::new(root, 2_usize as HMENU, false)));
        for target in 3..=9 {
            assert!(requests.push(PopupMenuRequest::new(root, target as HMENU, false)));
        }
        assert_eq!(requests.len(), PendingPopupMenuRequests::MAX_REQUESTS);
        assert!(!requests.push(PopupMenuRequest::new(root, 10_usize as HMENU, true)));
    }
}
