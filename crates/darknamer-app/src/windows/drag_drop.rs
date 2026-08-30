use super::*;

const IID_IDROP_TARGET: GUID = GUID::from_u128(0x00000122_0000_0000_c000_000000000046);

#[repr(C)]
struct DataObjectVTable {
    query_interface:
        unsafe extern "system" fn(*mut c_void, *const GUID, *mut *mut c_void) -> HRESULT,
    add_ref: unsafe extern "system" fn(*mut c_void) -> u32,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
    get_data: unsafe extern "system" fn(*mut c_void, *mut FORMATETC, *mut STGMEDIUM) -> HRESULT,
    get_data_here:
        unsafe extern "system" fn(*mut c_void, *mut FORMATETC, *mut STGMEDIUM) -> HRESULT,
    query_get_data: unsafe extern "system" fn(*mut c_void, *mut FORMATETC) -> HRESULT,
    get_canonical_format_etc:
        unsafe extern "system" fn(*mut c_void, *mut FORMATETC, *mut FORMATETC) -> HRESULT,
    set_data:
        unsafe extern "system" fn(*mut c_void, *mut FORMATETC, *mut STGMEDIUM, i32) -> HRESULT,
    enum_format_etc: unsafe extern "system" fn(*mut c_void, u32, *mut *mut c_void) -> HRESULT,
    d_advise: unsafe extern "system" fn(
        *mut c_void,
        *mut FORMATETC,
        u32,
        *mut c_void,
        *mut u32,
    ) -> HRESULT,
    d_unadvise: unsafe extern "system" fn(*mut c_void, u32) -> HRESULT,
    enum_d_advise: unsafe extern "system" fn(*mut c_void, *mut *mut c_void) -> HRESULT,
}

#[repr(C)]
struct DropTargetVTable {
    query_interface:
        unsafe extern "system" fn(*mut c_void, *const GUID, *mut *mut c_void) -> HRESULT,
    add_ref: unsafe extern "system" fn(*mut c_void) -> u32,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
    drag_enter:
        unsafe extern "system" fn(*mut c_void, *mut c_void, u32, POINTL, *mut u32) -> HRESULT,
    drag_over: unsafe extern "system" fn(*mut c_void, u32, POINTL, *mut u32) -> HRESULT,
    drag_leave: unsafe extern "system" fn(*mut c_void) -> HRESULT,
    drop: unsafe extern "system" fn(*mut c_void, *mut c_void, u32, POINTL, *mut u32) -> HRESULT,
}

#[repr(C)]
struct DropTarget {
    vtable: *const DropTargetVTable,
    refs: AtomicUsize,
    state_owner: HWND,
    format_supported: AtomicBool,
    #[cfg(test)]
    drop_observer: Option<Arc<AtomicUsize>>,
}

impl Drop for DropTarget {
    fn drop(&mut self) {
        #[cfg(test)]
        if let Some(observer) = &self.drop_observer {
            observer.fetch_add(1, Ordering::AcqRel);
        }
    }
}

static DROP_TARGET_VTABLE: DropTargetVTable = DropTargetVTable {
    query_interface: drop_target_query_interface,
    add_ref: drop_target_add_ref,
    release: drop_target_release,
    drag_enter: drop_target_drag_enter,
    drag_over: drop_target_drag_over,
    drag_leave: drop_target_drag_leave,
    drop: drop_target_drop,
};

struct CallbackSelfReference(*mut c_void);

impl CallbackSelfReference {
    unsafe fn acquire(this: *mut c_void) -> Option<Self> {
        if this.is_null() {
            return None;
        }
        // SAFETY: this is the live interface pointer supplied for the callback.
        unsafe { drop_target_add_ref(this) };
        Some(Self(this))
    }
}

impl Drop for CallbackSelfReference {
    fn drop(&mut self) {
        // SAFETY: acquire took exactly one callback-local reference.
        unsafe { drop_target_release(self.0) };
    }
}

pub(super) struct DropTargetRegistration {
    registered_hwnd: HWND,
    target: *mut DropTarget,
    registered: bool,
}

impl DropTargetRegistration {
    fn register(registered_hwnd: HWND, state_owner: HWND) -> io::Result<Self> {
        if registered_hwnd.is_null() || state_owner.is_null() {
            return Err(io::Error::other("drop target window is null"));
        }
        let target = Box::into_raw(Box::new(DropTarget {
            vtable: &raw const DROP_TARGET_VTABLE,
            refs: AtomicUsize::new(1),
            state_owner,
            format_supported: AtomicBool::new(false),
            #[cfg(test)]
            drop_observer: None,
        }));
        // SAFETY: target begins with the exact IDropTarget vtable pointer and
        // keeps its creator reference while OLE takes its documented AddRef.
        let status = unsafe { RegisterDragDrop(registered_hwnd, target.cast()) };
        if status < 0 {
            // SAFETY: failed registration did not transfer the creator-owned
            // object; this is its one terminal Release.
            unsafe { drop_target_release(target.cast()) };
            return Err(io::Error::other(format!(
                "OLE drop target registration failed: 0x{:08X}",
                status as u32
            )));
        }
        Ok(Self {
            registered_hwnd,
            target,
            registered: true,
        })
    }

    #[cfg(test)]
    fn reference_count(&self) -> usize {
        // SAFETY: registration retains the creator reference for target.
        unsafe { (*self.target).refs.load(Ordering::Acquire) }
    }

    #[cfg(test)]
    fn registered_hwnd(&self) -> HWND {
        self.registered_hwnd
    }
}

impl Drop for DropTargetRegistration {
    fn drop(&mut self) {
        if self.registered {
            // SAFETY: owner is the exact HWND successfully registered once by
            // this object. Revoke releases OLE's registration reference.
            unsafe { RevokeDragDrop(self.registered_hwnd) };
            self.registered = false;
        }
        if !self.target.is_null() {
            // SAFETY: this releases the one creator reference retained since
            // construction, after OLE's registration reference was revoked.
            unsafe { drop_target_release(self.target.cast()) };
            self.target = null_mut();
        }
    }
}

pub(super) struct DropTargetRegistrations {
    _list: DropTargetRegistration,
    _overlay: DropTargetRegistration,
}

impl DropTargetRegistrations {
    fn register(list: HWND, overlay: HWND, state_owner: HWND) -> io::Result<Self> {
        let list = DropTargetRegistration::register(list, state_owner)?;
        let overlay = match DropTargetRegistration::register(overlay, state_owner) {
            Ok(overlay) => overlay,
            Err(error) => {
                drop(list);
                return Err(error);
            }
        };
        Ok(Self {
            _list: list,
            _overlay: overlay,
        })
    }

    #[cfg(test)]
    fn registrations(&self) -> [&DropTargetRegistration; 2] {
        [&self._list, &self._overlay]
    }
}

pub(super) fn register_drop_targets(
    list: HWND,
    overlay: HWND,
    state_owner: HWND,
) -> io::Result<DropTargetRegistrations> {
    DropTargetRegistrations::register(list, overlay, state_owner)
}

#[must_use]
fn file_drop_format() -> FORMATETC {
    FORMATETC {
        cfFormat: CF_HDROP,
        ptd: null_mut(),
        dwAspect: DVASPECT_CONTENT,
        lindex: -1,
        tymed: TYMED_HGLOBAL as u32,
    }
}

struct OwnedStgMedium {
    medium: STGMEDIUM,
}

impl OwnedStgMedium {
    fn from_successful_get_data(medium: STGMEDIUM) -> Self {
        Self { medium }
    }

    fn file_drop_handle(&self) -> Option<HDROP> {
        if self.medium.tymed != TYMED_HGLOBAL as u32 {
            return None;
        }
        // SAFETY: the discriminant was checked for the hGlobal union member.
        let global = unsafe { self.medium.u.hGlobal };
        (!global.is_null()).then_some(global as HDROP)
    }
}

impl Drop for OwnedStgMedium {
    fn drop(&mut self) {
        // SAFETY: this wrapper is created immediately after one successful
        // IDataObject::GetData and releases that exact medium once.
        unsafe { ReleaseStgMedium(&mut self.medium) };
    }
}

unsafe extern "system" fn drop_target_query_interface(
    this: *mut c_void,
    iid: *const GUID,
    object: *mut *mut c_void,
) -> HRESULT {
    if object.is_null() {
        return E_POINTER;
    }
    // SAFETY: object was checked and is the caller's writable out pointer.
    unsafe { *object = null_mut() };
    if this.is_null() || iid.is_null() {
        return E_POINTER;
    }
    // SAFETY: iid remains readable for this COM call.
    let requested = unsafe { *iid };
    if !guid_eq(requested, IID_IUnknown) && !guid_eq(requested, IID_IDROP_TARGET) {
        return E_NOINTERFACE;
    }
    // SAFETY: this is the same interface pointer and object is writable.
    unsafe {
        *object = this;
        drop_target_add_ref(this);
    }
    S_OK
}

const fn guid_eq(left: GUID, right: GUID) -> bool {
    left.data1 == right.data1
        && left.data2 == right.data2
        && left.data3 == right.data3
        && left.data4[0] == right.data4[0]
        && left.data4[1] == right.data4[1]
        && left.data4[2] == right.data4[2]
        && left.data4[3] == right.data4[3]
        && left.data4[4] == right.data4[4]
        && left.data4[5] == right.data4[5]
        && left.data4[6] == right.data4[6]
        && left.data4[7] == right.data4[7]
}

unsafe extern "system" fn drop_target_add_ref(this: *mut c_void) -> u32 {
    // SAFETY: COM passes the interface pointer originally registered.
    let Some(target) = (unsafe { (this as *mut DropTarget).as_ref() }) else {
        return 0;
    };
    let previous = target
        .refs
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
            value.checked_add(1)
        })
        .unwrap_or(usize::MAX);
    u32::try_from(previous.saturating_add(1)).unwrap_or(u32::MAX)
}

unsafe extern "system" fn drop_target_release(this: *mut c_void) -> u32 {
    let target = this as *mut DropTarget;
    // SAFETY: COM passes the interface pointer originally registered.
    let Some(target_ref) = (unsafe { target.as_ref() }) else {
        return 0;
    };
    let mut current = target_ref.refs.load(Ordering::Acquire);
    loop {
        if current == 0 {
            return 0;
        }
        match target_ref.refs.compare_exchange_weak(
            current,
            current - 1,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => break,
            Err(observed) => current = observed,
        }
    }
    let remaining = current - 1;
    if remaining == 0 {
        // SAFETY: the successful 1->0 transition owns the sole deallocation.
        unsafe { drop(Box::from_raw(target)) };
    }
    u32::try_from(remaining).unwrap_or(u32::MAX)
}

unsafe extern "system" fn drop_target_drag_enter(
    this: *mut c_void,
    data: *mut c_void,
    _key_state: u32,
    _point: POINTL,
    effect: *mut u32,
) -> HRESULT {
    // SAFETY: COM supplies this for the callback; the guard prevents reentrant
    // RevokeDragDrop from freeing the object before return.
    let Some(_self_reference) = (unsafe { CallbackSelfReference::acquire(this) }) else {
        return invalid_target_effect(effect);
    };
    drop_callback(effect, || {
        // SAFETY: COM supplies the registered interface pointer for this call.
        let target = unsafe { target_ref(this)? };
        if data.is_null() {
            target.format_supported.store(false, Ordering::Release);
            set_overlay_for_owner(target.state_owner, DropPresentation::Unsupported);
            // SAFETY: drop_callback validated effect before invoking this body.
            unsafe { *effect = DROP_EFFECT_NONE };
            return Some(E_POINTER);
        }
        // SAFETY: data is non-null and borrowed for this provider query only.
        let supported = unsafe { query_file_drop(data) };
        target.format_supported.store(supported, Ordering::Release);
        // SAFETY: drop_callback validated effect and it remains live.
        let source_effects = unsafe { *effect };
        let negotiation = negotiate_for_owner(target.state_owner, supported, source_effects);
        set_overlay_for_owner(target.state_owner, negotiation.presentation);
        // SAFETY: same validated output pointer.
        unsafe { *effect = negotiation.effect };
        Some(S_OK)
    })
}

unsafe extern "system" fn drop_target_drag_over(
    this: *mut c_void,
    _key_state: u32,
    _point: POINTL,
    effect: *mut u32,
) -> HRESULT {
    // SAFETY: same callback-local lifetime protection as DragEnter.
    let Some(_self_reference) = (unsafe { CallbackSelfReference::acquire(this) }) else {
        return invalid_target_effect(effect);
    };
    drop_callback(effect, || {
        // SAFETY: COM supplies the registered interface pointer for this call.
        let target = unsafe { target_ref(this)? };
        let supported = target.format_supported.load(Ordering::Acquire);
        // SAFETY: drop_callback validated effect and it remains live.
        let source_effects = unsafe { *effect };
        let negotiation = negotiate_for_owner(target.state_owner, supported, source_effects);
        set_overlay_for_owner(target.state_owner, negotiation.presentation);
        // SAFETY: same validated output pointer.
        unsafe { *effect = negotiation.effect };
        Some(S_OK)
    })
}

unsafe extern "system" fn drop_target_drag_leave(this: *mut c_void) -> HRESULT {
    // SAFETY: same callback-local lifetime protection as DragEnter.
    let Some(_self_reference) = (unsafe { CallbackSelfReference::acquire(this) }) else {
        return E_POINTER;
    };
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: COM supplies the registered interface pointer for this call.
        let Some(target) = (unsafe { target_ref(this) }) else {
            return E_POINTER;
        };
        target.format_supported.store(false, Ordering::Release);
        set_overlay_for_owner(target.state_owner, DropPresentation::Inactive);
        S_OK
    }));
    result.unwrap_or(E_FAIL)
}

unsafe extern "system" fn drop_target_drop(
    this: *mut c_void,
    data: *mut c_void,
    _key_state: u32,
    _point: POINTL,
    effect: *mut u32,
) -> HRESULT {
    // SAFETY: same callback-local lifetime protection as DragEnter.
    let Some(_self_reference) = (unsafe { CallbackSelfReference::acquire(this) }) else {
        return invalid_target_effect(effect);
    };
    drop_callback(effect, || {
        // SAFETY: COM supplies the registered interface pointer for this call.
        let target = unsafe { target_ref(this)? };
        let format_supported = target.format_supported.swap(false, Ordering::AcqRel);
        // SAFETY: drop_callback validated effect and it remains live.
        let source_effects = unsafe { *effect };
        // SAFETY: same validated output pointer.
        unsafe { *effect = DROP_EFFECT_NONE };
        set_overlay_for_owner(target.state_owner, DropPresentation::Inactive);
        if !format_supported
            || source_effects & DROPEFFECT_COPY == 0
            || drop_locked(target.state_owner) != Some(false)
        {
            return Some(S_OK);
        }
        if remaining_capacity(target.state_owner).is_none_or(|remaining| remaining == 0) {
            return Some(S_OK);
        }
        if data.is_null() {
            return Some(E_POINTER);
        }
        // SAFETY: data is non-null and is inspected only for its COM vtable.
        if unsafe { data_vtable(data) }.is_none() {
            return Some(E_POINTER);
        }

        // SAFETY: data is borrowed only for this provider call; successful
        // output is immediately wrapped in OwnedStgMedium.
        let Some(medium) = (unsafe { get_file_drop_medium(data) }) else {
            // Provider rejection is a normal non-drop, not a COM target error.
            return Some(S_OK);
        };
        let Some(drop_handle) = medium.file_drop_handle() else {
            drop(medium);
            return Some(S_OK);
        };
        let Some(remaining) = remaining_capacity(target.state_owner) else {
            drop(medium);
            return Some(S_OK);
        };
        let (paths, truncated) = extract_drop_paths(drop_handle, remaining);
        drop(medium);

        if drop_locked(target.state_owner) != Some(false) {
            return Some(S_OK);
        }
        if truncated {
            message(
                target.state_owner,
                "선택 항목이 남은 10,000개 한도를 초과해 제한된 수만 처리합니다.",
                "DarkReNamer - 추가 한도",
            );
        }
        if drop_locked(target.state_owner) != Some(false) {
            return Some(S_OK);
        }
        if paths.is_empty() {
            return Some(S_OK);
        }
        let state = window_state_ptr(target.state_owner);
        if state.is_null() {
            return Some(S_OK);
        }
        // SAFETY: the pointer was freshly resolved after every provider,
        // medium, and modal boundary and remains UI-thread confined.
        if unsafe { (*state).drop_locked() } {
            return Some(S_OK);
        }
        // The tiny borrow ends before PostMessageW or the error reporter can
        // reenter the window. No IDataObject/STGMEDIUM/HGLOBAL is retained.
        // SAFETY: state was freshly resolved after all external boundaries.
        let start_result = unsafe {
            let state = &mut *state;
            admit_paths(target.state_owner, state, paths)
        };
        // SAFETY: drop_callback validated effect and it remains live.
        unsafe { *effect = drop_effect_after_admission_start(start_result.is_ok()) };
        match start_result {
            Ok(()) => {
                // SAFETY: state borrow ended above; this posts an integral
                // handoff that will re-resolve AppState in window_proc.
                unsafe {
                    PostMessageW(target.state_owner, WM_APP_ADMISSION_STARTED, 0, 0);
                }
            }
            Err(error) => {
                // No AppState borrow survives into this modal reporter.
                report_admission_start_error(target.state_owner, &error);
            }
        }
        Some(S_OK)
    })
}

fn drop_callback(effect: *mut u32, body: impl FnOnce() -> Option<HRESULT>) -> HRESULT {
    if effect.is_null() {
        return E_POINTER;
    }
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Some(status)) => status,
        Ok(None) => {
            // SAFETY: effect was checked before entering caller-controlled work.
            unsafe { *effect = DROP_EFFECT_NONE };
            E_POINTER
        }
        Err(_) => {
            // SAFETY: effect was checked before entering caller-controlled work.
            unsafe { *effect = DROP_EFFECT_NONE };
            E_FAIL
        }
    }
}

fn invalid_target_effect(effect: *mut u32) -> HRESULT {
    if !effect.is_null() {
        // SAFETY: a non-null effect is writable callback storage by contract.
        unsafe { *effect = DROP_EFFECT_NONE };
    }
    E_POINTER
}

unsafe fn target_ref<'a>(this: *mut c_void) -> Option<&'a DropTarget> {
    // SAFETY: callers pass the interface pointer supplied by COM.
    unsafe { (this as *mut DropTarget).as_ref() }
}

unsafe fn data_vtable(data: *mut c_void) -> Option<&'static DataObjectVTable> {
    if data.is_null() {
        return None;
    }
    // SAFETY: an IDataObject interface begins with a readable vtable pointer.
    let vtable = unsafe { *(data as *mut *const DataObjectVTable) };
    // SAFETY: COM guarantees a process-live vtable for the duration of calls.
    unsafe { vtable.as_ref() }
}

unsafe fn query_file_drop(data: *mut c_void) -> bool {
    // SAFETY: caller supplies the borrowed IDataObject interface pointer.
    let Some(vtable) = (unsafe { data_vtable(data) }) else {
        return false;
    };
    let mut format = file_drop_format();
    // SAFETY: data and its vtable are live for this provider call; format is
    // writable caller-owned storage and no AppState borrow is held.
    unsafe { (vtable.query_get_data)(data, &mut format) >= 0 }
}

unsafe fn get_file_drop_medium(data: *mut c_void) -> Option<OwnedStgMedium> {
    // SAFETY: caller supplies the borrowed IDataObject interface pointer.
    let vtable = unsafe { data_vtable(data)? };
    let mut format = file_drop_format();
    let mut medium = STGMEDIUM::default();
    // SAFETY: data/vtable are live and both out structures remain writable;
    // no AppState borrow exists across this provider-controlled call.
    let status = unsafe { (vtable.get_data)(data, &mut format, &mut medium) };
    (status >= 0).then(|| OwnedStgMedium::from_successful_get_data(medium))
}

fn negotiate_for_owner(
    owner: HWND,
    format_supported: bool,
    source_effects: u32,
) -> DropNegotiation {
    negotiate_drop_effect(
        format_supported,
        drop_locked(owner).unwrap_or(true),
        remaining_capacity(owner).unwrap_or(0),
        source_effects,
    )
}

fn window_state_ptr(owner: HWND) -> *mut AppState {
    if owner.is_null() {
        return null_mut();
    }
    // SAFETY: owner is the registered UI-thread HWND and this is a value query.
    unsafe { GetWindowLongPtrW(owner, GWLP_USERDATA) as *mut AppState }
}

fn drop_locked(owner: HWND) -> Option<bool> {
    let state = window_state_ptr(owner);
    // SAFETY: GWLP_USERDATA is cleared before AppState reclamation and this
    // borrow ends before return.
    unsafe { state.as_ref().map(AppState::drop_locked) }
}

fn remaining_capacity(owner: HWND) -> Option<usize> {
    let state = window_state_ptr(owner);
    // SAFETY: same short UI-thread-confined read as drop_locked.
    unsafe {
        state
            .as_ref()
            .map(|state| MAX_ADMITTED_SOURCES.saturating_sub(state.model.len()))
    }
}

fn set_overlay_for_owner(owner: HWND, presentation: DropPresentation) {
    let state = window_state_ptr(owner);
    // SAFETY: copy the HWND in a tiny shared borrow that ends before any
    // SetWindowTextW/UpdateWindow/ShowWindow reentrancy.
    let overlay = unsafe { state.as_ref().map(|state| state.drop_overlay) };
    if let Some(overlay) = overlay {
        set_drop_overlay_control(overlay, presentation);
    }
}

fn extract_drop_paths(drop: HDROP, remaining: usize) -> (Vec<PathBuf>, bool) {
    // SAFETY: drop is the live HGLOBAL-backed HDROP retained by OwnedStgMedium.
    let reported = unsafe { DragQueryFileW(drop, u32::MAX, null_mut(), 0) } as usize;
    let bounded = bounded_selection(reported, remaining);
    let mut paths = Vec::with_capacity(bounded.take);
    for index in 0..bounded.take {
        let native_index = u32::try_from(index).unwrap_or(u32::MAX);
        // SAFETY: drop remains live and this length query writes no buffer.
        let length = unsafe { DragQueryFileW(drop, native_index, null_mut(), 0) };
        let Ok(length) = usize::try_from(length) else {
            continue;
        };
        if length == 0 || length > MAX_PATH_UNITS {
            continue;
        }
        let Some(capacity) = length.checked_add(1) else {
            continue;
        };
        let mut buffer = vec![0; capacity];
        // SAFETY: buffer has exactly the advertised capacity and drop remains
        // owned by the live medium for the full synchronous copy.
        let copied = unsafe {
            DragQueryFileW(
                drop,
                native_index,
                buffer.as_mut_ptr(),
                u32::try_from(buffer.len()).unwrap_or(u32::MAX),
            )
        };
        if usize::try_from(copied).ok() != Some(length) {
            continue;
        }
        buffer.truncate(length);
        paths.push(PathBuf::from(std::ffi::OsString::from_wide(&buffer)));
    }
    (paths, bounded.truncated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::windows::ffi::OsStrExt;
    use std::time::{Duration, Instant};

    use windows_sys::Win32::Foundation::{DV_E_FORMATETC, E_NOTIMPL, HGLOBAL};
    use windows_sys::Win32::System::Memory::{
        GMEM_MOVEABLE, GMEM_ZEROINIT, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock,
    };
    use windows_sys::Win32::System::Ole::OleInitialize;
    use windows_sys::Win32::UI::Shell::DROPFILES;

    #[repr(C)]
    struct FakeDataObject {
        vtable: *const DataObjectVTable,
        refs: AtomicUsize,
        query_status: HRESULT,
        get_status: HRESULT,
        transferred_tymed: u32,
        global: HGLOBAL,
        lock_owner_during_get: HWND,
        query_calls: AtomicUsize,
        get_calls: AtomicUsize,
    }

    impl FakeDataObject {
        fn new(query_status: HRESULT, get_status: HRESULT) -> Self {
            Self {
                vtable: &raw const FAKE_DATA_VTABLE,
                refs: AtomicUsize::new(1),
                query_status,
                get_status,
                transferred_tymed: TYMED_HGLOBAL as u32,
                global: null_mut(),
                lock_owner_during_get: null_mut(),
                query_calls: AtomicUsize::new(0),
                get_calls: AtomicUsize::new(0),
            }
        }

        fn interface(&mut self) -> *mut c_void {
            (self as *mut Self).cast()
        }
    }

    static FAKE_DATA_VTABLE: DataObjectVTable = DataObjectVTable {
        query_interface: fake_query_interface,
        add_ref: fake_add_ref,
        release: fake_release,
        get_data: fake_get_data,
        get_data_here: fake_get_data_here,
        query_get_data: fake_query_get_data,
        get_canonical_format_etc: fake_get_canonical_format_etc,
        set_data: fake_set_data,
        enum_format_etc: fake_enum_format_etc,
        d_advise: fake_d_advise,
        d_unadvise: fake_d_unadvise,
        enum_d_advise: fake_enum_d_advise,
    };

    unsafe extern "system" fn fake_query_interface(
        _this: *mut c_void,
        _iid: *const GUID,
        object: *mut *mut c_void,
    ) -> HRESULT {
        if !object.is_null() {
            // SAFETY: object is the caller-provided writable output.
            unsafe { *object = null_mut() };
        }
        E_NOINTERFACE
    }

    unsafe extern "system" fn fake_add_ref(this: *mut c_void) -> u32 {
        // SAFETY: tests pass a live FakeDataObject interface.
        let Some(fake) = (unsafe { (this as *mut FakeDataObject).as_ref() }) else {
            return 0;
        };
        u32::try_from(fake.refs.fetch_add(1, Ordering::AcqRel) + 1).unwrap_or(u32::MAX)
    }

    unsafe extern "system" fn fake_release(this: *mut c_void) -> u32 {
        // SAFETY: tests pass a live FakeDataObject interface.
        let Some(fake) = (unsafe { (this as *mut FakeDataObject).as_ref() }) else {
            return 0;
        };
        u32::try_from(fake.refs.fetch_sub(1, Ordering::AcqRel).saturating_sub(1))
            .unwrap_or(u32::MAX)
    }

    unsafe extern "system" fn fake_get_data(
        this: *mut c_void,
        format: *mut FORMATETC,
        medium: *mut STGMEDIUM,
    ) -> HRESULT {
        if this.is_null() || format.is_null() || medium.is_null() {
            return E_POINTER;
        }
        // SAFETY: pointers were checked and originate from the test helper.
        let fake = unsafe { &mut *(this as *mut FakeDataObject) };
        fake.get_calls.fetch_add(1, Ordering::AcqRel);
        // SAFETY: format remains readable throughout this call.
        if !format_is_exact(unsafe { &*format }) {
            return DV_E_FORMATETC;
        }
        if fake.get_status < 0 {
            return fake.get_status;
        }
        if !fake.lock_owner_during_get.is_null() {
            let state = window_state_ptr(fake.lock_owner_during_get);
            if !state.is_null() {
                // SAFETY: test callback runs synchronously on the owner UI thread.
                unsafe { (*state).mutation_locked = true };
            }
        }
        // SAFETY: medium is writable provider output. Ownership of global is
        // transferred to the receiver exactly once.
        unsafe {
            *medium = STGMEDIUM {
                tymed: fake.transferred_tymed,
                u: windows_sys::Win32::System::Com::STGMEDIUM_0 {
                    hGlobal: fake.global,
                },
                pUnkForRelease: null_mut(),
            };
        }
        fake.global = null_mut();
        S_OK
    }

    unsafe extern "system" fn fake_query_get_data(
        this: *mut c_void,
        format: *mut FORMATETC,
    ) -> HRESULT {
        if this.is_null() || format.is_null() {
            return E_POINTER;
        }
        // SAFETY: pointers were checked and originate from the test helper.
        let fake = unsafe { &*(this as *mut FakeDataObject) };
        fake.query_calls.fetch_add(1, Ordering::AcqRel);
        // SAFETY: format remains readable for this synchronous query.
        if !format_is_exact(unsafe { &*format }) {
            DV_E_FORMATETC
        } else {
            fake.query_status
        }
    }

    unsafe extern "system" fn fake_get_data_here(
        _this: *mut c_void,
        _format: *mut FORMATETC,
        _medium: *mut STGMEDIUM,
    ) -> HRESULT {
        E_NOTIMPL
    }

    unsafe extern "system" fn fake_get_canonical_format_etc(
        _this: *mut c_void,
        _input: *mut FORMATETC,
        _output: *mut FORMATETC,
    ) -> HRESULT {
        E_NOTIMPL
    }

    unsafe extern "system" fn fake_set_data(
        _this: *mut c_void,
        _format: *mut FORMATETC,
        _medium: *mut STGMEDIUM,
        _release: i32,
    ) -> HRESULT {
        E_NOTIMPL
    }

    unsafe extern "system" fn fake_enum_format_etc(
        _this: *mut c_void,
        _direction: u32,
        _output: *mut *mut c_void,
    ) -> HRESULT {
        E_NOTIMPL
    }

    unsafe extern "system" fn fake_d_advise(
        _this: *mut c_void,
        _format: *mut FORMATETC,
        _flags: u32,
        _sink: *mut c_void,
        _connection: *mut u32,
    ) -> HRESULT {
        E_NOTIMPL
    }

    unsafe extern "system" fn fake_d_unadvise(_this: *mut c_void, _connection: u32) -> HRESULT {
        E_NOTIMPL
    }

    unsafe extern "system" fn fake_enum_d_advise(
        _this: *mut c_void,
        _output: *mut *mut c_void,
    ) -> HRESULT {
        E_NOTIMPL
    }

    fn format_is_exact(format: &FORMATETC) -> bool {
        format.cfFormat == CF_HDROP
            && format.ptd.is_null()
            && format.dwAspect == DVASPECT_CONTENT
            && format.lindex == -1
            && format.tymed == TYMED_HGLOBAL as u32
    }

    fn create_drop_global(paths: &[PathBuf]) -> io::Result<HGLOBAL> {
        let mut names = Vec::<u16>::new();
        for path in paths {
            names.extend(path.as_os_str().encode_wide());
            names.push(0);
        }
        names.push(0);
        let header_size = size_of::<DROPFILES>();
        let names_size = names.len().saturating_mul(size_of::<u16>());
        let total = header_size
            .checked_add(names_size)
            .ok_or_else(|| io::Error::other("test drop allocation overflow"))?;
        // SAFETY: flags request a movable zeroed block owned by the returned medium.
        let global = unsafe { GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, total) };
        if global.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: global is live and locked until the copy completes.
        let bytes = unsafe { GlobalLock(global) };
        if bytes.is_null() {
            let medium = OwnedStgMedium::from_successful_get_data(STGMEDIUM {
                tymed: TYMED_HGLOBAL as u32,
                u: windows_sys::Win32::System::Com::STGMEDIUM_0 { hGlobal: global },
                pUnkForRelease: null_mut(),
            });
            drop(medium);
            return Err(io::Error::last_os_error());
        }
        let header = DROPFILES {
            pFiles: u32::try_from(header_size)
                .map_err(|_| io::Error::other("test drop header is too large"))?,
            pt: Default::default(),
            fNC: 0,
            fWide: 1,
        };
        // SAFETY: the allocation is at least total bytes; unaligned write is
        // valid and the UTF-16 slice occupies the remaining non-overlapping area.
        unsafe {
            (bytes as *mut DROPFILES).write_unaligned(header);
            (bytes.cast::<u8>().add(header_size) as *mut u16)
                .copy_from_nonoverlapping(names.as_ptr(), names.len());
            GlobalUnlock(global);
        }
        Ok(global)
    }

    struct TestOle;

    impl TestOle {
        fn initialize() -> io::Result<Self> {
            // SAFETY: null is required and Drop balances success on this thread.
            let status = unsafe { OleInitialize(null()) };
            if status < 0 {
                Err(io::Error::other(format!(
                    "test OLE initialization failed: 0x{:08X}",
                    status as u32
                )))
            } else {
                Ok(Self)
            }
        }
    }

    impl Drop for TestOle {
        fn drop(&mut self) {
            // SAFETY: this guard was initialized and drops on the same thread.
            unsafe { OleUninitialize() };
        }
    }

    #[test]
    fn file_drop_format_is_exact() {
        let format = file_drop_format();
        assert_eq!(format.cfFormat, CF_HDROP);
        assert!(format.ptd.is_null());
        assert_eq!(format.dwAspect, DVASPECT_CONTENT);
        assert_eq!(format.lindex, -1);
        assert_eq!(format.tymed, TYMED_HGLOBAL as u32);
        assert_eq!(DROP_EFFECT_COPY, DROPEFFECT_COPY);
    }

    #[test]
    fn drop_target_query_interface_and_reference_count_are_defensive() {
        let target = Box::into_raw(Box::new(DropTarget {
            vtable: &raw const DROP_TARGET_VTABLE,
            refs: AtomicUsize::new(1),
            state_owner: null_mut(),
            format_supported: AtomicBool::new(false),
            drop_observer: None,
        }));
        let mut object = null_mut();
        // SAFETY: target is a live private COM object and object is writable.
        assert_eq!(
            // SAFETY: target is live and object is writable for QI.
            unsafe { drop_target_query_interface(target.cast(), &IID_IDROP_TARGET, &mut object) },
            S_OK
        );
        assert_eq!(object, target.cast());
        // SAFETY: target remains live with two references.
        assert_eq!(unsafe { (*target).refs.load(Ordering::Acquire) }, 2);
        object = null_mut();
        assert_eq!(
            // SAFETY: target is live and object is writable for IUnknown QI.
            unsafe { drop_target_query_interface(target.cast(), &IID_IUnknown, &mut object) },
            S_OK
        );
        assert_eq!(object, target.cast());
        // SAFETY: target remains live with three references.
        assert_eq!(unsafe { (*target).refs.load(Ordering::Acquire) }, 3);
        // SAFETY: null output is rejected before any dereference.
        assert_eq!(
            // SAFETY: target is live; null output is intentionally tested.
            unsafe { drop_target_query_interface(target.cast(), &IID_IDROP_TARGET, null_mut()) },
            E_POINTER
        );
        object = std::ptr::dangling_mut::<c_void>();
        // SAFETY: null IID is rejected and the writable output is cleared.
        assert_eq!(
            // SAFETY: target/output are live; null IID is intentionally tested.
            unsafe { drop_target_query_interface(target.cast(), null(), &mut object) },
            E_POINTER
        );
        assert!(object.is_null());
        let unsupported = GUID::from_u128(0x11111111_2222_3333_4444_555555555555);
        object = std::ptr::dangling_mut::<c_void>();
        // SAFETY: same live object and writable output.
        assert_eq!(
            // SAFETY: same live object and writable QI output.
            unsafe { drop_target_query_interface(target.cast(), &unsupported, &mut object) },
            E_NOINTERFACE
        );
        assert!(object.is_null());
        // SAFETY: releases both QI references then the creator exactly once.
        assert_eq!(unsafe { drop_target_release(target.cast()) }, 2);
        // SAFETY: releases the second QI reference.
        assert_eq!(unsafe { drop_target_release(target.cast()) }, 1);
        // SAFETY: the remaining creator reference is released exactly once.
        assert_eq!(unsafe { drop_target_release(target.cast()) }, 0);
    }

    #[test]
    fn fake_data_object_rejects_wrong_format_and_get_data_failure() {
        let mut rejected = FakeDataObject::new(DV_E_FORMATETC, E_FAIL);
        // SAFETY: rejected is a live fake IDataObject with an exact vtable.
        assert!(!unsafe { query_file_drop(rejected.interface()) });
        assert_eq!(rejected.query_calls.load(Ordering::Acquire), 1);
        assert_eq!(rejected.get_calls.load(Ordering::Acquire), 0);

        let mut failing = FakeDataObject::new(S_OK, E_FAIL);
        // SAFETY: failing is a live fake IDataObject with an exact vtable.
        assert!(unsafe { query_file_drop(failing.interface()) });
        // SAFETY: provider failure returns no owned medium.
        assert!(unsafe { get_file_drop_medium(failing.interface()) }.is_none());
        assert_eq!(failing.query_calls.load(Ordering::Acquire), 1);
        assert_eq!(failing.get_calls.load(Ordering::Acquire), 1);

        let mut wrong_tymed = FakeDataObject::new(S_OK, S_OK);
        wrong_tymed.transferred_tymed = 0;
        // SAFETY: fake returns a successful but non-HGLOBAL medium, which is
        // still wrapped and released by the caller.
        let medium = unsafe { get_file_drop_medium(wrong_tymed.interface()) };
        assert!(
            medium
                .as_ref()
                .is_some_and(|medium| medium.file_drop_handle().is_none())
        );
        drop(medium);

        let target = test_drop_target(null_mut());
        let mut enter_only = FakeDataObject::new(S_OK, E_FAIL);
        let mut effect = DROP_EFFECT_COPY;
        // SAFETY: target/fake/effect remain live for this synchronous callback.
        assert_eq!(
            // SAFETY: target/fake/effect remain live through DragEnter.
            unsafe {
                drop_target_drag_enter(
                    target.cast(),
                    enter_only.interface(),
                    0,
                    POINTL::default(),
                    &mut effect,
                )
            },
            S_OK
        );
        assert_eq!(enter_only.query_calls.load(Ordering::Acquire), 1);
        assert_eq!(enter_only.get_calls.load(Ordering::Acquire), 0);
        assert_eq!(effect, DROP_EFFECT_NONE);
        // SAFETY: target retains only its creator reference.
        assert_eq!(unsafe { drop_target_release(target.cast()) }, 0);
    }

    #[test]
    fn successful_medium_is_released_exactly_once() -> Result<(), Box<dyn std::error::Error>> {
        let path = PathBuf::from(r"C:\drop\sample.txt");
        let global = create_drop_global(&[path])?;
        let mut fake = FakeDataObject::new(S_OK, S_OK);
        fake.global = global;
        // SAFETY: fake transfers its one live HGLOBAL into the returned wrapper.
        let medium = unsafe { get_file_drop_medium(fake.interface()) }
            .ok_or_else(|| io::Error::other("fake GetData did not return a medium"))?;
        assert!(medium.file_drop_handle().is_some());
        assert!(fake.global.is_null());
        // SAFETY: global remains live while the medium owns it.
        assert!(unsafe { GlobalSize(global) } > 0);
        drop(medium);
        // SAFETY: ReleaseStgMedium must have freed the transferred HGLOBAL.
        assert_eq!(unsafe { GlobalSize(global) }, 0);
        Ok(())
    }

    #[test]
    fn ole_registration_owns_exact_list_and_overlay_pair_and_revokes_both()
    -> Result<(), Box<dyn std::error::Error>> {
        let _ole = TestOle::initialize()?;
        let owner = create_test_owner()?;
        let list = create_test_list(owner)?;
        let overlay = create_drop_overlay(owner)?;
        let registrations = DropTargetRegistrations::register(list, overlay, owner)?;
        for (registration, expected) in registrations
            .registrations()
            .into_iter()
            .zip([list, overlay])
        {
            assert_eq!(registration.registered_hwnd(), expected);
            assert!(registration.reference_count() >= 2);
        }
        drop(registrations);
        // Both HWNDs can be registered again only if both previous entries
        // were revoked by the aggregate teardown.
        let second = DropTargetRegistrations::register(list, overlay, owner)?;
        drop(second);
        // SAFETY: owner is the hidden test HWND and registration is revoked.
        unsafe { DestroyWindow(owner) };
        Ok(())
    }

    #[test]
    fn callback_self_reference_is_target_specific_and_outlives_creator_release()
    -> Result<(), Box<dyn std::error::Error>> {
        let observer = Arc::new(AtomicUsize::new(0));
        let target = Box::into_raw(Box::new(DropTarget {
            vtable: &raw const DROP_TARGET_VTABLE,
            refs: AtomicUsize::new(1),
            state_owner: null_mut(),
            format_supported: AtomicBool::new(false),
            drop_observer: Some(Arc::clone(&observer)),
        }));
        // SAFETY: target is live and the guard takes one local reference.
        let guard = unsafe { CallbackSelfReference::acquire(target.cast()) }
            .ok_or_else(|| io::Error::other("callback guard was not acquired"))?;
        // SAFETY: target remains live with creator+callback references.
        assert_eq!(unsafe { (*target).refs.load(Ordering::Acquire) }, 2);
        // SAFETY: simulate reentrant revoke/owner teardown releasing creator.
        assert_eq!(unsafe { drop_target_release(target.cast()) }, 1);
        assert_eq!(observer.load(Ordering::Acquire), 0);
        drop(guard);
        assert_eq!(observer.load(Ordering::Acquire), 1);
        Ok(())
    }

    #[test]
    fn drop_rechecks_lock_after_get_data_and_never_dispatches_when_it_changed()
    -> Result<(), Box<dyn std::error::Error>> {
        let _ole = TestOle::initialize()?;
        let local = tempfile::tempdir()?;
        let Some(mut state) = test_app_state(local.path())? else {
            return Ok(());
        };
        let owner = create_test_owner()?;
        state.list_window = create_test_list(owner)?;
        publish_test_state(owner, &mut state);

        let mut fake = FakeDataObject::new(S_OK, S_OK);
        fake.global = create_drop_global(&[local.path().join("locked.txt")])?;
        fake.lock_owner_during_get = owner;
        let target = test_drop_target(owner);
        let mut effect = DROP_EFFECT_COPY;
        // SAFETY: all interfaces and effect storage remain live synchronously.
        let status = unsafe {
            drop_target_drop(
                target.cast(),
                fake.interface(),
                0,
                POINTL::default(),
                &mut effect,
            )
        };
        assert_eq!(status, S_OK);
        assert_eq!(effect, DROP_EFFECT_NONE);
        assert!(state.mutation_locked);
        assert!(state.admission_worker.is_none());
        assert_eq!(fake.get_calls.load(Ordering::Acquire), 1);
        state.mutation_locked = false;
        finalize_admission_start_failure(&mut state);
        assert!(state.command_states[usize::from(ADD_FILES - APPLY)]);
        unpublish_test_state(owner);
        // SAFETY: target retains only its creator reference.
        assert_eq!(unsafe { drop_target_release(target.cast()) }, 0);
        // SAFETY: owner destroys its ListView child.
        unsafe { DestroyWindow(owner) };
        Ok(())
    }

    #[test]
    fn eligible_drop_dispatches_one_owned_admission_batch() -> Result<(), Box<dyn std::error::Error>>
    {
        let _ole = TestOle::initialize()?;
        let local = tempfile::tempdir()?;
        let source = local.path().join("sample.txt");
        fs::write(&source, b"sample")?;
        let Some(mut state) = test_app_state(local.path())? else {
            return Ok(());
        };
        let owner = create_test_owner()?;
        state.list_window = create_test_list(owner)?;
        publish_test_state(owner, &mut state);

        let mut fake = FakeDataObject::new(S_OK, S_OK);
        fake.global = create_drop_global(&[source])?;
        let target = test_drop_target(owner);
        let mut effect = DROP_EFFECT_COPY | 2;
        // SAFETY: all interfaces and effect storage remain live synchronously.
        let status = unsafe {
            drop_target_drop(
                target.cast(),
                fake.interface(),
                0,
                POINTL::default(),
                &mut effect,
            )
        };
        assert_eq!(status, S_OK);
        assert_eq!(effect, DROP_EFFECT_COPY);
        assert_eq!(fake.get_calls.load(Ordering::Acquire), 1);
        assert!(state.admission_worker.is_some());

        let deadline = Instant::now() + Duration::from_secs(5);
        while state
            .admission_worker
            .as_ref()
            .is_some_and(|worker| !worker.handle.is_finished())
            && Instant::now() < deadline
        {
            thread::yield_now();
        }
        let worker = state
            .admission_worker
            .take()
            .ok_or_else(|| io::Error::other("admission worker was not started"))?;
        assert!(worker.handle.is_finished());
        assert!(worker.handle.join().is_ok());
        // SAFETY: the test owner owns this timer ID.
        unsafe { KillTimer(owner, APPLY_POLL_TIMER_ID) };
        state.mutation_locked = false;

        unpublish_test_state(owner);
        // SAFETY: target retains only its creator reference.
        assert_eq!(unsafe { drop_target_release(target.cast()) }, 0);
        // SAFETY: owner destroys its ListView child.
        unsafe { DestroyWindow(owner) };
        Ok(())
    }

    fn test_drop_target(owner: HWND) -> *mut DropTarget {
        Box::into_raw(Box::new(DropTarget {
            vtable: &raw const DROP_TARGET_VTABLE,
            refs: AtomicUsize::new(1),
            state_owner: owner,
            format_supported: AtomicBool::new(true),
            drop_observer: None,
        }))
    }

    fn test_app_state(path: &Path) -> Result<Option<AppState>, Box<dyn std::error::Error>> {
        match initialize_safe_runtime_at(path) {
            Ok(runtime) => Ok(Some(AppState::new(runtime))),
            Err(error)
                if error
                    .get_ref()
                    .and_then(|source| source.downcast_ref::<FileJournalError>())
                    .and_then(|source| source.os_code)
                    == Some(120) =>
            {
                // Wine does not implement the audited Windows journal handle
                // operations. Real Windows still executes this acceptance path.
                Ok(None)
            }
            Err(error) => Err(error.into()),
        }
    }

    fn create_test_owner() -> io::Result<HWND> {
        let class = wide("STATIC");
        // SAFETY: the system class/current module are live and no creation
        // parameter is retained.
        let owner = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if owner.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(owner)
        }
    }

    fn create_test_list(owner: HWND) -> io::Result<HWND> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: u32::try_from(size_of::<INITCOMMONCONTROLSEX>())
                .map_err(|_| io::Error::other("invalid controls size"))?,
            dwICC: ICC_LISTVIEW_CLASSES,
        };
        // SAFETY: controls has its exact size for synchronous initialization.
        unsafe { InitCommonControlsEx(&controls) };
        let class = wide("SysListView32");
        // SAFETY: owner/system class/current module are live.
        let list = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_CHILD | LVS_REPORT,
                0,
                0,
                320,
                240,
                owner,
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if list.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(list)
        }
    }

    fn publish_test_state(owner: HWND, state: &mut AppState) {
        // SAFETY: state outlives every synchronous callback in the test and is
        // unpublished before either state or owner is destroyed.
        unsafe { SetWindowLongPtrW(owner, GWLP_USERDATA, (state as *mut AppState) as isize) };
    }

    fn unpublish_test_state(owner: HWND) {
        // SAFETY: owner is live and this clears its test-only borrowed pointer.
        unsafe { SetWindowLongPtrW(owner, GWLP_USERDATA, 0) };
    }
}
