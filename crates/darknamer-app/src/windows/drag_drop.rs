#[cfg(test)]
use crate::ADD_FILES;
#[cfg(test)]
use crate::APPLY;
#[cfg(test)]
use crate::DROP_EFFECT_COPY;
use crate::DROP_EFFECT_NONE;
use crate::DropNegotiation;
use crate::DropPresentation;
use crate::admission::MAX_ADMITTED_SOURCES;
use crate::admission::PathBudget;
use crate::admission::PathBudgetReservation;
use crate::admission::bounded_selection;
use crate::drop_effect_after_admission_start;
use crate::negotiate_drop_effect;
#[cfg(test)]
use crate::rename::FileJournalError;
use crate::rename::MAX_PATH_UNITS;
#[cfg(test)]
use std::ffi::c_void;
#[cfg(test)]
use std::fs;
use std::io;
#[cfg(test)]
use std::mem::size_of;
use std::os::windows::ffi::OsStringExt;
use std::panic::AssertUnwindSafe;
use std::panic::catch_unwind;
#[cfg(test)]
use std::path::Path;
use std::path::PathBuf;
#[cfg(test)]
use std::ptr::null;
use std::ptr::null_mut;
#[cfg(test)]
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::Ordering;
#[cfg(test)]
use std::thread;
use windows_sys::Win32::Foundation::E_FAIL;
#[cfg(test)]
use windows_sys::Win32::Foundation::E_NOINTERFACE;
use windows_sys::Win32::Foundation::E_POINTER;
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Foundation::S_OK;
#[cfg(test)]
use windows_sys::Win32::System::Com::DVASPECT_CONTENT;
#[cfg(test)]
use windows_sys::Win32::System::Com::FORMATETC;
#[cfg(test)]
use windows_sys::Win32::System::Com::STGMEDIUM;
use windows_sys::Win32::System::Com::TYMED_HGLOBAL;
#[cfg(test)]
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Ole::CF_HDROP;
use windows_sys::Win32::System::Ole::DROPEFFECT_COPY;

#[cfg(test)]
use super::initialize_safe_runtime_at;
#[cfg(test)]
use super::{
    APPLY_POLL_TIMER_ID, AppState, ReclaimDisposition, create_drop_overlay,
    finalize_admission_start_failure, wide,
};
use super::{
    AppStateSlot, CallbackState, WM_APP_ADMISSION_STARTED, admit_paths, message,
    report_admission_start_error, set_drop_overlay_control, try_app_state,
};
use ::windows::Win32::Foundation::{HWND as ComHwnd, POINTL as ComPoint};
use ::windows::Win32::System::Com::{
    DVASPECT_CONTENT as COM_DVASPECT_CONTENT, FORMATETC as ComFormatEtc, IDataObject,
    STGMEDIUM as ComStgMedium,
};
use ::windows::Win32::System::Ole::{
    DROPEFFECT, IDropTarget, IDropTarget_Impl, RegisterDragDrop as register_drag_drop,
    ReleaseStgMedium as release_stg_medium, RevokeDragDrop as revoke_drag_drop,
};
use ::windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
use windows_core::{ComObject, IUnknownImpl, Ref};
#[cfg(test)]
use windows_sys::Win32::System::Ole::OleUninitialize;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::ICC_LISTVIEW_CLASSES;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::INITCOMMONCONTROLSEX;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::InitCommonControlsEx;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVS_REPORT;
use windows_sys::Win32::UI::Shell::DragQueryFileW;
use windows_sys::Win32::UI::Shell::HDROP;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::CreateWindowExW;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::DestroyWindow;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::GWLP_USERDATA;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::KillTimer;
use windows_sys::Win32::UI::WindowsAndMessaging::PostMessageW;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::SetWindowLongPtrW;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::WS_CHILD;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::WS_OVERLAPPEDWINDOW;
#[cfg(test)]
use windows_sys::core::GUID;
use windows_sys::core::HRESULT;

#[cfg(test)]
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

// The HWND and AppState callbacks belong to the UI apartment. The macro's
// default agile object would advertise cross-thread calls and free-threaded
// marshaling, which this target cannot support.
#[::windows::core::implement(IDropTarget, Agile = false)]
struct DropTarget {
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

impl DropTarget {
    fn new(
        state_owner: HWND,
        #[cfg(test)] drop_observer: Option<Arc<AtomicUsize>>,
    ) -> ComObject<Self> {
        ComObject::new(Self {
            state_owner,
            format_supported: AtomicBool::new(false),
            #[cfg(test)]
            drop_observer,
        })
    }
}

pub(super) struct DropTargetRegistration {
    registered_hwnd: HWND,
    target: IDropTarget,
}

impl DropTargetRegistration {
    fn register(registered_hwnd: HWND, state_owner: HWND) -> io::Result<Self> {
        if registered_hwnd.is_null() || state_owner.is_null() {
            return Err(io::Error::other("drop target window is null"));
        }
        let target = DropTarget::new(
            state_owner,
            #[cfg(test)]
            None,
        )
        .into_interface::<IDropTarget>();
        // SAFETY: both HWNDs are live on the OLE UI thread; the owner retains
        // its typed COM reference until after RevokeDragDrop returns.
        unsafe { register_drag_drop(ComHwnd(registered_hwnd), &target) }.map_err(|error| {
            io::Error::other(format!("OLE drop target registration failed: {error}"))
        })?;
        Ok(Self {
            registered_hwnd,
            target,
        })
    }

    #[cfg(test)]
    fn registered_hwnd(&self) -> HWND {
        self.registered_hwnd
    }
}

impl Drop for DropTargetRegistration {
    fn drop(&mut self) {
        let _registration_owner = self.target.clone();
        // SAFETY: this is the exact UI-thread HWND registered by this owner.
        // Both typed references stay alive until after RevokeDragDrop returns.
        let _ = unsafe { revoke_drag_drop(ComHwnd(self.registered_hwnd)) };
    }
}

pub(super) struct DropTargetRegistrations {
    list: Option<DropTargetRegistration>,
    overlay: Option<DropTargetRegistration>,
}

impl DropTargetRegistrations {
    const fn empty() -> Self {
        Self {
            list: None,
            overlay: None,
        }
    }

    #[cfg(test)]
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
            list: Some(list),
            overlay: Some(overlay),
        })
    }

    fn install_list(&mut self, registration: DropTargetRegistration) -> Result<(), io::Error> {
        if self.list.is_some() {
            return Err(io::Error::other("list drop target is already registered"));
        }
        self.list = Some(registration);
        Ok(())
    }

    fn install_overlay(&mut self, registration: DropTargetRegistration) -> Result<(), io::Error> {
        if self.overlay.is_some() {
            return Err(io::Error::other(
                "overlay drop target is already registered",
            ));
        }
        self.overlay = Some(registration);
        Ok(())
    }

    #[cfg(test)]
    fn registrations(&self) -> impl Iterator<Item = &DropTargetRegistration> {
        self.list.iter().chain(self.overlay.iter())
    }
}

pub(super) fn register_drop_targets(
    list: HWND,
    overlay: HWND,
    state_owner: HWND,
    state_slot: *mut AppStateSlot,
) -> io::Result<()> {
    // Install the empty owner before the first OLE call. RegisterDragDrop's
    // documented synchronous target callback is IUnknown::AddRef, and this
    // implementation's AddRef performs no FFI or message dispatch. Every
    // successful individual registration is still transferred into the
    // sidecar before the next OLE call so prior registrations remain revocable
    // if later setup triggers window teardown.
    // SAFETY: state_slot is the currently leased UI-thread slot and its sidecar
    // is disjoint from AppState.
    unsafe { CallbackState::install_retirement(state_slot, DropTargetRegistrations::empty()) }
        .map_err(|_registrations| io::Error::other("drop registration sidecar is occupied"))?;

    let result = (|| {
        let list_registration = DropTargetRegistration::register(list, state_owner)?;
        install_drop_registration(state_slot, list_registration, true)?;
        let overlay_registration = DropTargetRegistration::register(overlay, state_owner)?;
        install_drop_registration(state_slot, overlay_registration, false)
    })();
    if result.is_err() {
        // SAFETY: failure leaves no future registration call. Taking the
        // sidecar immediately revokes every successfully transferred target.
        drop(unsafe { CallbackState::take_retirement(state_slot) });
    }
    result
}

fn install_drop_registration(
    state_slot: *mut AppStateSlot,
    registration: DropTargetRegistration,
    is_list: bool,
) -> io::Result<()> {
    // SAFETY: the just-completed RegisterDragDrop call returned. This immediate
    // sidecar take performs no Win32 call and detects reentrant destruction.
    let Some(mut registrations) = (unsafe { CallbackState::take_retirement(state_slot) }) else {
        drop(registration);
        return Err(io::Error::other(
            "window was destroyed during drop target registration",
        ));
    };
    let installed = if is_list {
        registrations.install_list(registration)
    } else {
        registrations.install_overlay(registration)
    };
    if let Err(error) = installed {
        drop(registrations);
        return Err(error);
    }
    // SAFETY: no reentrant operation occurred since taking the sidecar. Restore
    // it before any subsequent RegisterDragDrop call can enter window teardown.
    unsafe { CallbackState::install_retirement(state_slot, registrations) }.map_err(
        |registrations| {
            drop(registrations);
            io::Error::other("drop registration sidecar was retired")
        },
    )
}

#[must_use]
fn file_drop_format() -> ComFormatEtc {
    ComFormatEtc {
        cfFormat: CF_HDROP,
        ptd: null_mut(),
        dwAspect: COM_DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL as u32,
    }
}

struct OwnedStgMedium {
    medium: ComStgMedium,
}

impl OwnedStgMedium {
    fn from_successful_get_data(medium: ComStgMedium) -> Self {
        Self { medium }
    }

    fn file_drop_handle(&self) -> Option<HDROP> {
        if self.medium.tymed != TYMED_HGLOBAL as u32 {
            return None;
        }
        // SAFETY: the discriminant was checked for the hGlobal union member.
        let global = unsafe { self.medium.u.hGlobal };
        (!global.0.is_null()).then_some(global.0 as HDROP)
    }
}

impl Drop for OwnedStgMedium {
    fn drop(&mut self) {
        // SAFETY: this wrapper is created immediately after one successful
        // IDataObject::GetData and releases that exact medium once.
        unsafe { release_stg_medium(&mut self.medium) };
    }
}

#[allow(non_snake_case)]
impl IDropTarget_Impl for DropTarget_Impl {
    fn DragEnter(
        &self,
        data: Ref<IDataObject>,
        _key_state: MODIFIERKEYS_FLAGS,
        _point: &ComPoint,
        effect: *mut DROPEFFECT,
    ) -> ::windows::core::Result<()> {
        // Keep the generated COM identity alive if provider calls reenter
        // window teardown and revoke this registration.
        let _self_reference = self.to_interface::<IDropTarget>();
        com_result(drop_callback(effect, || {
            let Some(data) = data.as_ref() else {
                self.format_supported.store(false, Ordering::Release);
                set_overlay_for_owner(self.state_owner, DropPresentation::Unsupported);
                // SAFETY: drop_callback validated effect before entering.
                unsafe { *effect = DROPEFFECT(DROP_EFFECT_NONE) };
                return Some(E_POINTER);
            };
            let supported = query_file_drop(data);
            self.format_supported.store(supported, Ordering::Release);
            // SAFETY: drop_callback validated effect and it remains live.
            let source_effects = unsafe { (*effect).0 };
            let negotiation = negotiate_for_owner(self.state_owner, supported, source_effects);
            set_overlay_for_owner(self.state_owner, negotiation.presentation);
            // SAFETY: same validated output pointer.
            unsafe { *effect = DROPEFFECT(negotiation.effect) };
            Some(S_OK)
        }))
    }

    fn DragOver(
        &self,
        _key_state: MODIFIERKEYS_FLAGS,
        _point: &ComPoint,
        effect: *mut DROPEFFECT,
    ) -> ::windows::core::Result<()> {
        let _self_reference = self.to_interface::<IDropTarget>();
        com_result(drop_callback(effect, || {
            let supported = self.format_supported.load(Ordering::Acquire);
            // SAFETY: drop_callback validated effect and it remains live.
            let source_effects = unsafe { (*effect).0 };
            let negotiation = negotiate_for_owner(self.state_owner, supported, source_effects);
            set_overlay_for_owner(self.state_owner, negotiation.presentation);
            // SAFETY: same validated output pointer.
            unsafe { *effect = DROPEFFECT(negotiation.effect) };
            Some(S_OK)
        }))
    }

    fn DragLeave(&self) -> ::windows::core::Result<()> {
        let _self_reference = self.to_interface::<IDropTarget>();
        let result = catch_unwind(AssertUnwindSafe(|| {
            self.format_supported.store(false, Ordering::Release);
            set_overlay_for_owner(self.state_owner, DropPresentation::Inactive);
        }));
        com_result(if result.is_ok() { S_OK } else { E_FAIL })
    }

    fn Drop(
        &self,
        data: Ref<IDataObject>,
        _key_state: MODIFIERKEYS_FLAGS,
        _point: &ComPoint,
        effect: *mut DROPEFFECT,
    ) -> ::windows::core::Result<()> {
        let _self_reference = self.to_interface::<IDropTarget>();
        com_result(drop_callback(effect, || {
            let format_supported = self.format_supported.swap(false, Ordering::AcqRel);
            // SAFETY: drop_callback validated effect and it remains live.
            let source_effects = unsafe { (*effect).0 };
            // SAFETY: same validated output pointer.
            unsafe { *effect = DROPEFFECT(DROP_EFFECT_NONE) };
            set_overlay_for_owner(self.state_owner, DropPresentation::Inactive);
            if !format_supported
                || source_effects & DROPEFFECT_COPY == 0
                || drop_locked(self.state_owner) != Some(false)
            {
                return Some(S_OK);
            }
            if remaining_capacity(self.state_owner).is_none_or(|remaining| remaining == 0) {
                return Some(S_OK);
            }
            let Some(data) = data.as_ref() else {
                return Some(E_POINTER);
            };

            // SAFETY: data is borrowed only for this provider call; successful
            // output is immediately wrapped in OwnedStgMedium.
            let Some(medium) = get_file_drop_medium(data) else {
                // Provider rejection is a normal non-drop, not a COM target error.
                return Some(S_OK);
            };
            let Some(drop_handle) = medium.file_drop_handle() else {
                drop(medium);
                return Some(S_OK);
            };
            let Some(limits) = remaining_admission_limits(self.state_owner) else {
                drop(medium);
                return Some(S_OK);
            };
            let extracted =
                extract_drop_paths(drop_handle, limits.remaining_count, limits.path_budget);
            drop(medium);

            if drop_locked(self.state_owner) != Some(false) {
                return Some(S_OK);
            }
            if extracted.count_truncated || extracted.path_budget_exhausted {
                let detail = if extracted.count_truncated && extracted.path_budget_exhausted {
                    "선택 항목이 남은 개수와 UTF-16 경로 용량 안전 한도를 초과해 제한된 수만 처리합니다."
                } else if extracted.count_truncated {
                    "선택 항목이 남은 개수 한도를 초과해 제한된 수만 처리합니다."
                } else {
                    "선택 경로가 UTF-16 경로 용량 안전 한도를 초과해 이미 확인한 항목만 처리합니다."
                };
                message(self.state_owner, detail, "DarkReNamer - 추가 한도");
            }
            if drop_locked(self.state_owner) != Some(false) {
                return Some(S_OK);
            }
            if extracted.paths.is_empty() {
                return Some(S_OK);
            }
            let Some(mut state_lease) = try_app_state(self.state_owner) else {
                return Some(S_OK);
            };
            if state_lease.state().drop_locked() {
                return Some(S_OK);
            }
            let start_result =
                admit_paths(self.state_owner, state_lease.state_mut(), extracted.paths);
            drop(state_lease);
            // SAFETY: drop_callback validated effect and it remains live.
            unsafe {
                *effect = DROPEFFECT(drop_effect_after_admission_start(start_result.is_ok()))
            };
            match start_result {
                Ok(()) => {
                    // SAFETY: state borrow ended above; this posts an integral
                    // handoff that will re-resolve AppState in window_proc.
                    unsafe {
                        PostMessageW(self.state_owner, WM_APP_ADMISSION_STARTED, 0, 0);
                    }
                }
                Err(error) => {
                    // No AppState borrow survives into this modal reporter.
                    report_admission_start_error(self.state_owner, &error);
                }
            }
            Some(S_OK)
        }))
    }
}

fn com_result(status: HRESULT) -> ::windows::core::Result<()> {
    ::windows::core::HRESULT(status).ok()
}

fn drop_callback(effect: *mut DROPEFFECT, body: impl FnOnce() -> Option<HRESULT>) -> HRESULT {
    if effect.is_null() {
        return E_POINTER;
    }
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Some(status)) => status,
        Ok(None) => {
            // SAFETY: effect was checked before entering caller-controlled work.
            unsafe { *effect = DROPEFFECT(DROP_EFFECT_NONE) };
            E_POINTER
        }
        Err(_) => {
            // SAFETY: effect was checked before entering caller-controlled work.
            unsafe { *effect = DROPEFFECT(DROP_EFFECT_NONE) };
            E_FAIL
        }
    }
}

fn query_file_drop(data: &IDataObject) -> bool {
    let format = file_drop_format();
    // SAFETY: the typed borrowed interface and format remain live for this call.
    unsafe { data.QueryGetData(&format).is_ok() }
}

fn get_file_drop_medium(data: &IDataObject) -> Option<OwnedStgMedium> {
    let format = file_drop_format();
    // SAFETY: the provider controls this call, so no AppState lease is held.
    unsafe { data.GetData(&format) }
        .ok()
        .map(OwnedStgMedium::from_successful_get_data)
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

fn drop_locked(owner: HWND) -> Option<bool> {
    try_app_state(owner).map(|state_lease| state_lease.state().drop_locked())
}

fn remaining_capacity(owner: HWND) -> Option<usize> {
    try_app_state(owner)
        .map(|state_lease| MAX_ADMITTED_SOURCES.saturating_sub(state_lease.state().model.len()))
}

#[derive(Clone, Copy)]
struct RemainingAdmissionLimits {
    remaining_count: usize,
    path_budget: PathBudget,
}

fn remaining_admission_limits(owner: HWND) -> Option<RemainingAdmissionLimits> {
    try_app_state(owner).map(|state_lease| {
        let state = state_lease.state();
        let mut path_budget = PathBudget::new();
        for item in state.model.items() {
            if path_budget.reserve_utf16_units(item.source_path().units().len())
                == PathBudgetReservation::Exhausted
            {
                break;
            }
        }
        RemainingAdmissionLimits {
            remaining_count: MAX_ADMITTED_SOURCES.saturating_sub(state.model.len()),
            path_budget,
        }
    })
}

fn set_overlay_for_owner(owner: HWND, presentation: DropPresentation) {
    let overlay = try_app_state(owner).map(|state_lease| state_lease.state().drop_overlay);
    if let Some(overlay) = overlay {
        set_drop_overlay_control(overlay, presentation);
    }
}

struct DropPathExtraction {
    paths: Vec<PathBuf>,
    count_truncated: bool,
    path_budget_exhausted: bool,
}

fn reserve_drop_path_allocation(path_budget: &mut PathBudget, utf16_units: usize) -> bool {
    path_budget.reserve_utf16_units(utf16_units) == PathBudgetReservation::Reserved
}

fn extract_drop_paths(
    drop: HDROP,
    remaining: usize,
    mut path_budget: PathBudget,
) -> DropPathExtraction {
    // SAFETY: drop is the live HGLOBAL-backed HDROP retained by OwnedStgMedium.
    let reported = unsafe { DragQueryFileW(drop, u32::MAX, null_mut(), 0) } as usize;
    let bounded = bounded_selection(reported, remaining);
    let mut paths = Vec::with_capacity(bounded.take);
    let mut path_budget_exhausted = false;
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
        if !reserve_drop_path_allocation(&mut path_budget, length) {
            path_budget_exhausted = true;
            break;
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
    DropPathExtraction {
        paths,
        count_truncated: bounded.truncated,
        path_budget_exhausted,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::windows::ffi::OsStrExt;
    use std::time::{Duration, Instant};

    use ::windows::Win32::Foundation::HGLOBAL as ComHglobal;
    use ::windows::Win32::System::Com::STGMEDIUM_0 as ComStgMediumUnion;
    use ::windows::Win32::System::Ole::IDropTarget_Vtbl;
    use windows_core::{IUnknown, Interface};
    use windows_sys::Win32::Foundation::{DV_E_FORMATETC, E_NOTIMPL, GlobalFree, HGLOBAL};
    use windows_sys::Win32::System::Memory::{
        GMEM_MOVEABLE, GMEM_ZEROINIT, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock,
    };
    use windows_sys::Win32::System::Ole::OleInitialize;
    use windows_sys::Win32::UI::Shell::DROPFILES;
    use windows_sys::core::{IID_IUnknown, IUnknown_Vtbl};

    #[repr(C)]
    struct FakeDataObject {
        vtable: *const DataObjectVTable,
        refs: AtomicUsize,
        query_status: HRESULT,
        get_status: HRESULT,
        transferred_tymed: u32,
        global: HGLOBAL,
        release_unknown: *mut c_void,
        lock_owner_during_get: HWND,
        revoke_during_get: Option<DropTargetRegistration>,
        drop_observer: Option<Arc<AtomicUsize>>,
        observed_drops_after_revoke: AtomicUsize,
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
                release_unknown: null_mut(),
                lock_owner_during_get: null_mut(),
                revoke_during_get: None,
                drop_observer: None,
                observed_drops_after_revoke: AtomicUsize::new(0),
                query_calls: AtomicUsize::new(0),
                get_calls: AtomicUsize::new(0),
            }
        }

        fn interface(&mut self) -> *mut c_void {
            (self as *mut Self).cast()
        }

        fn owned_interface(&mut self) -> IDataObject {
            let raw = self.interface();
            // SAFETY: the fake COM vtable is live on this test stack until the
            // returned typed interface is dropped.
            unsafe {
                fake_add_ref(raw);
                IDataObject::from_raw(raw)
            }
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

    #[repr(C)]
    struct MediumReleaseObserver {
        vtable: *const IUnknown_Vtbl,
        refs: AtomicUsize,
        releases: AtomicUsize,
        global: HGLOBAL,
        freed: AtomicBool,
    }

    impl MediumReleaseObserver {
        fn new(global: HGLOBAL) -> Self {
            Self {
                vtable: &raw const MEDIUM_RELEASE_VTABLE,
                refs: AtomicUsize::new(1),
                releases: AtomicUsize::new(0),
                global,
                freed: AtomicBool::new(false),
            }
        }

        fn interface(&mut self) -> *mut c_void {
            (self as *mut Self).cast()
        }

        fn assert_released_once(&self) {
            assert_eq!(self.releases.load(Ordering::Acquire), 1);
            assert_eq!(self.refs.load(Ordering::Acquire), 0);
            assert!(self.freed.load(Ordering::Acquire));
        }
    }

    static MEDIUM_RELEASE_VTABLE: IUnknown_Vtbl = IUnknown_Vtbl {
        QueryInterface: medium_release_query_interface,
        AddRef: medium_release_add_ref,
        Release: medium_release_release,
    };

    unsafe extern "system" fn medium_release_query_interface(
        this: *mut c_void,
        iid: *const GUID,
        object: *mut *mut c_void,
    ) -> HRESULT {
        if this.is_null() || iid.is_null() || object.is_null() {
            return E_POINTER;
        }
        // SAFETY: COM supplied a writable output and a readable IID for this call.
        unsafe { *object = null_mut() };
        // SAFETY: iid was checked and remains live throughout this callback.
        let requested = unsafe { &*iid };
        if requested.data1 != IID_IUnknown.data1
            || requested.data2 != IID_IUnknown.data2
            || requested.data3 != IID_IUnknown.data3
            || requested.data4 != IID_IUnknown.data4
        {
            return E_NOINTERFACE;
        }
        // SAFETY: the observer remains live until the medium releases its reference.
        unsafe {
            medium_release_add_ref(this);
            *object = this;
        }
        S_OK
    }

    unsafe extern "system" fn medium_release_add_ref(this: *mut c_void) -> u32 {
        // SAFETY: the test keeps the observer allocation live through COM calls.
        let observer = unsafe { &*(this as *const MediumReleaseObserver) };
        u32::try_from(observer.refs.fetch_add(1, Ordering::AcqRel) + 1).unwrap_or(u32::MAX)
    }

    unsafe extern "system" fn medium_release_release(this: *mut c_void) -> u32 {
        // SAFETY: the test keeps the observer allocation live through COM calls.
        let observer = unsafe { &*(this as *const MediumReleaseObserver) };
        observer.releases.fetch_add(1, Ordering::AcqRel);
        let previous = observer
            .refs
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |refs| {
                refs.checked_sub(1)
            })
            .unwrap_or(0);
        if previous == 1 {
            // SAFETY: this final reference owns the live HGLOBAL. GlobalFree is
            // observed here, before the handle can be reused by another owner.
            observer.freed.store(
                unsafe { GlobalFree(observer.global) }.is_null(),
                Ordering::Release,
            );
        }
        u32::try_from(previous.saturating_sub(1)).unwrap_or(u32::MAX)
    }

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
        if !fake.lock_owner_during_get.is_null()
            && let Some(mut state_lease) = try_app_state(fake.lock_owner_during_get)
        {
            state_lease.state_mut().mutation_locked = true;
        }
        if let Some(registration) = fake.revoke_during_get.take() {
            drop(registration);
            if let Some(observer) = &fake.drop_observer {
                fake.observed_drops_after_revoke
                    .store(observer.load(Ordering::Acquire), Ordering::Release);
            }
        }
        // SAFETY: medium is writable provider output. Its release obligation
        // transfers once: NULL pUnkForRelease lets the receiver free global;
        // otherwise the provider observer frees it on IUnknown::Release.
        unsafe {
            *medium = STGMEDIUM {
                tymed: fake.transferred_tymed,
                u: windows_sys::Win32::System::Com::STGMEDIUM_0 {
                    hGlobal: fake.global,
                },
                pUnkForRelease: fake.release_unknown,
            };
        }
        fake.global = null_mut();
        fake.release_unknown = null_mut();
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
            let medium = OwnedStgMedium::from_successful_get_data(ComStgMedium {
                tymed: TYMED_HGLOBAL as u32,
                u: ComStgMediumUnion {
                    hGlobal: ComHglobal(global),
                },
                pUnkForRelease: std::mem::ManuallyDrop::new(None),
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
        assert_eq!(format.dwAspect, COM_DVASPECT_CONTENT.0);
        assert_eq!(format.lindex, -1);
        assert_eq!(format.tymed, TYMED_HGLOBAL as u32);
        assert_eq!(DROP_EFFECT_COPY, DROPEFFECT_COPY);
    }

    #[test]
    fn long_drop_length_reports_stop_before_next_buffer_allocation() {
        let one_path_bytes = MAX_PATH_UNITS * size_of::<u16>();
        let mut path_budget = PathBudget::from_remaining_bytes(one_path_bytes);
        let mut allocations = 0_usize;

        for _length_report in 0..MAX_ADMITTED_SOURCES {
            if !reserve_drop_path_allocation(&mut path_budget, MAX_PATH_UNITS) {
                break;
            }
            allocations += 1;
        }

        assert_eq!(allocations, 1);
        assert_eq!(path_budget.remaining_bytes(), 0);
    }

    #[test]
    fn drop_target_query_interface_and_reference_count_are_defensive() -> windows_core::Result<()> {
        let observer = Arc::new(AtomicUsize::new(0));
        let target = DropTarget::new(null_mut(), Some(Arc::clone(&observer)));
        let drop_target = target.to_interface::<IDropTarget>();
        let unknown = drop_target.cast::<IUnknown>()?;
        // The macro also exposes its metadata identity, without UI operations
        // or agility. It must preserve the same canonical IUnknown identity.
        let inspectable = drop_target.cast::<windows_core::IInspectable>()?;
        assert_eq!(inspectable.cast::<IUnknown>()?, unknown);
        drop(inspectable);
        let unsupported = drop_target.cast::<IDataObject>();
        assert!(unsupported.is_err());
        assert!(
            drop_target
                .cast::<windows_core::imp::IAgileObject>()
                .is_err()
        );
        assert!(drop_target.cast::<windows_core::imp::IMarshal>().is_err());
        drop(target);
        assert_eq!(observer.load(Ordering::Acquire), 0);
        drop(unknown);
        assert_eq!(observer.load(Ordering::Acquire), 0);
        drop(drop_target);
        assert_eq!(observer.load(Ordering::Acquire), 1);
        Ok(())
    }

    #[test]
    fn fake_data_object_rejects_wrong_format_and_get_data_failure() {
        let mut rejected = FakeDataObject::new(DV_E_FORMATETC, E_FAIL);
        assert!(!query_file_drop(&rejected.owned_interface()));
        assert_eq!(rejected.query_calls.load(Ordering::Acquire), 1);
        assert_eq!(rejected.get_calls.load(Ordering::Acquire), 0);

        let mut failing = FakeDataObject::new(S_OK, E_FAIL);
        assert!(query_file_drop(&failing.owned_interface()));
        assert!(get_file_drop_medium(&failing.owned_interface()).is_none());
        assert_eq!(failing.query_calls.load(Ordering::Acquire), 1);
        assert_eq!(failing.get_calls.load(Ordering::Acquire), 1);

        let mut wrong_tymed = FakeDataObject::new(S_OK, S_OK);
        wrong_tymed.transferred_tymed = 0;
        let medium = get_file_drop_medium(&wrong_tymed.owned_interface());
        assert!(
            medium
                .as_ref()
                .is_some_and(|medium| medium.file_drop_handle().is_none())
        );
        drop(medium);

        let target = test_drop_target(null_mut());
        let mut enter_only = FakeDataObject::new(S_OK, E_FAIL);
        let mut effect = DROPEFFECT(DROP_EFFECT_COPY);
        // SAFETY: target, typed fake provider and effect remain live for this call.
        let status = unsafe {
            target.DragEnter(
                &enter_only.owned_interface(),
                MODIFIERKEYS_FLAGS(0),
                ComPoint::default(),
                &mut effect,
            )
        };
        assert!(status.is_ok());
        assert_eq!(enter_only.query_calls.load(Ordering::Acquire), 1);
        assert_eq!(enter_only.get_calls.load(Ordering::Acquire), 0);
        assert_eq!(effect.0, DROP_EFFECT_NONE);
    }

    #[test]
    fn successful_medium_is_released_exactly_once() -> Result<(), Box<dyn std::error::Error>> {
        let path = PathBuf::from(r"C:\drop\sample.txt");
        let global = create_drop_global(&[path])?;
        let mut release = MediumReleaseObserver::new(global);
        let mut fake = FakeDataObject::new(S_OK, S_OK);
        fake.global = global;
        fake.release_unknown = release.interface();
        let medium = get_file_drop_medium(&fake.owned_interface())
            .ok_or_else(|| io::Error::other("fake GetData did not return a medium"))?;
        assert!(medium.file_drop_handle().is_some());
        assert!(fake.global.is_null());
        // SAFETY: global remains live while the medium owns it.
        assert!(unsafe { GlobalSize(global) } > 0);
        drop(medium);
        release.assert_released_once();
        Ok(())
    }

    #[test]
    fn null_release_unknown_medium_uses_default_receiver_owned_path()
    -> Result<(), Box<dyn std::error::Error>> {
        let global = create_drop_global(&[PathBuf::from(r"C:\drop\default.txt")])?;
        let mut fake = FakeDataObject::new(S_OK, S_OK);
        fake.global = global;
        let medium = get_file_drop_medium(&fake.owned_interface())
            .ok_or_else(|| io::Error::other("fake GetData did not return a medium"))?;
        assert!(medium.file_drop_handle().is_some());
        assert!(fake.global.is_null());
        // SAFETY: the medium still owns the live HGLOBAL before it is dropped.
        assert!(unsafe { GlobalSize(global) } > 0);
        drop(medium);
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
        for (registration, expected) in registrations.registrations().zip([list, overlay]) {
            assert_eq!(registration.registered_hwnd(), expected);
            assert!(!registration.target.as_raw().is_null());
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
    fn failed_overlay_registration_revokes_the_list() -> Result<(), Box<dyn std::error::Error>> {
        let _ole = TestOle::initialize()?;
        let owner = create_test_owner()?;
        let list = create_test_list(owner)?;
        assert!(DropTargetRegistrations::register(list, null_mut(), owner).is_err());
        let registration = DropTargetRegistration::register(list, owner)?;
        drop(registration);
        // SAFETY: the exact registration was revoked before destroying owner.
        unsafe { DestroyWindow(owner) };
        Ok(())
    }

    #[test]
    fn callback_self_reference_is_target_specific_and_outlives_creator_release()
    -> Result<(), Box<dyn std::error::Error>> {
        let observer = Arc::new(AtomicUsize::new(0));
        let target = DropTarget::new(null_mut(), Some(Arc::clone(&observer)));
        let guard = target.to_interface::<IDropTarget>();
        // Simulate reentrant owner teardown releasing the creator reference.
        drop(target);
        assert_eq!(observer.load(Ordering::Acquire), 0);
        drop(guard);
        assert_eq!(observer.load(Ordering::Acquire), 1);
        Ok(())
    }

    #[test]
    fn reentrant_revoke_during_get_data_keeps_callback_alive()
    -> Result<(), Box<dyn std::error::Error>> {
        let _ole = TestOle::initialize()?;
        let local = tempfile::tempdir()?;
        let Some(mut state) = test_app_state(local.path())? else {
            return Ok(());
        };
        let owner = create_test_owner()?;
        let list = create_test_list(owner)?;
        state.list_window = list;
        let state_slot = publish_test_state(owner, state);

        let observer = Arc::new(AtomicUsize::new(0));
        let target =
            DropTarget::new(owner, Some(Arc::clone(&observer))).into_interface::<IDropTarget>();
        // SAFETY: OLE is initialized and the list HWND belongs to this thread.
        unsafe { register_drag_drop(ComHwnd(list), &target) }?;
        let raw = target.as_raw();
        // SAFETY: target is live; the generated vtable remains static after
        // registration ownership is moved into the fake provider.
        let vtable = unsafe { *(raw as *const *const IDropTarget_Vtbl) };
        let registration = DropTargetRegistration {
            registered_hwnd: list,
            target,
        };

        let global = create_drop_global(&[local.path().join("reentrant.txt")])?;
        let mut release = MediumReleaseObserver::new(global);
        let mut fake = FakeDataObject::new(S_OK, S_OK);
        fake.global = global;
        fake.release_unknown = release.interface();
        fake.lock_owner_during_get = owner;
        fake.revoke_during_get = Some(registration);
        fake.drop_observer = Some(Arc::clone(&observer));
        let mut effect = DROPEFFECT(DROP_EFFECT_COPY);
        // Complete the normal DragEnter negotiation before Drop; without it
        // Drop correctly rejects the unnegotiated provider before GetData.
        // SAFETY: registration owns the live interface, and the borrowed fake
        // provider and effect storage remain valid for this synchronous call.
        unsafe {
            ((*vtable).DragEnter)(
                raw,
                fake.interface(),
                MODIFIERKEYS_FLAGS(0),
                ComPoint::default(),
                &mut effect,
            )
        }
        .ok()?;
        assert_eq!(effect.0, DROP_EFFECT_COPY);
        // SAFETY: OLE holds the registered target on entry. The provider is
        // live throughout this synchronous generated-vtable callback.
        let status = unsafe {
            ((*vtable).Drop)(
                raw,
                fake.interface(),
                MODIFIERKEYS_FLAGS(0),
                ComPoint::default(),
                &mut effect,
            )
        };
        assert!(status.is_ok());
        assert_eq!(effect.0, DROP_EFFECT_NONE);
        assert_eq!(fake.observed_drops_after_revoke.load(Ordering::Acquire), 0);
        assert_eq!(observer.load(Ordering::Acquire), 1);
        assert_eq!(fake.get_calls.load(Ordering::Acquire), 1);
        assert!(fake.revoke_during_get.is_none());
        assert!(fake.global.is_null());
        release.assert_released_once();

        unpublish_test_state(owner, state_slot);
        // SAFETY: registration was revoked during the callback.
        unsafe { DestroyWindow(owner) };
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
        let state_slot = publish_test_state(owner, state);

        let mut fake = FakeDataObject::new(S_OK, S_OK);
        fake.global = create_drop_global(&[local.path().join("locked.txt")])?;
        fake.lock_owner_during_get = owner;
        let target = test_drop_target(owner);
        let mut effect = DROPEFFECT(DROP_EFFECT_COPY);
        // SAFETY: all interfaces and effect storage remain live synchronously.
        let status = unsafe {
            target.Drop(
                &fake.owned_interface(),
                MODIFIERKEYS_FLAGS(0),
                ComPoint::default(),
                &mut effect,
            )
        };
        assert!(status.is_ok());
        assert_eq!(effect.0, DROP_EFFECT_NONE);
        // SAFETY: the test owns the live slot published to this owner.
        let mut state_lease = unsafe { CallbackState::try_lease(state_slot) }
            .ok_or_else(|| io::Error::other("test state lease unavailable"))?;
        let state = state_lease.state_mut();
        assert!(state.mutation_locked);
        assert!(state.admission_worker.is_none());
        assert_eq!(fake.get_calls.load(Ordering::Acquire), 1);
        state.mutation_locked = false;
        finalize_admission_start_failure(state);
        assert!(state.command_states[usize::from(ADD_FILES - APPLY)]);
        drop(state_lease);
        unpublish_test_state(owner, state_slot);
        drop(target);
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
        let state_slot = publish_test_state(owner, state);

        let mut fake = FakeDataObject::new(S_OK, S_OK);
        fake.global = create_drop_global(&[source])?;
        let target = test_drop_target(owner);
        let mut effect = DROPEFFECT(DROP_EFFECT_COPY | 2);
        // SAFETY: all interfaces and effect storage remain live synchronously.
        let status = unsafe {
            target.Drop(
                &fake.owned_interface(),
                MODIFIERKEYS_FLAGS(0),
                ComPoint::default(),
                &mut effect,
            )
        };
        assert!(status.is_ok());
        assert_eq!(effect.0, DROP_EFFECT_COPY);
        assert_eq!(fake.get_calls.load(Ordering::Acquire), 1);
        // SAFETY: the test owns the live slot published to this owner.
        let mut state_lease = unsafe { CallbackState::try_lease(state_slot) }
            .ok_or_else(|| io::Error::other("test state lease unavailable"))?;
        let state = state_lease.state_mut();
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

        drop(state_lease);
        unpublish_test_state(owner, state_slot);
        drop(target);
        // SAFETY: owner destroys its ListView child.
        unsafe { DestroyWindow(owner) };
        Ok(())
    }

    fn test_drop_target(owner: HWND) -> IDropTarget {
        let target = DropTarget::new(owner, None);
        target.format_supported.store(true, Ordering::Release);
        target.into_interface::<IDropTarget>()
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

    fn publish_test_state(owner: HWND, state: AppState) -> *mut AppStateSlot {
        let state_slot = CallbackState::into_raw(state);
        // SAFETY: the slot is UI-thread owned and remains published until the
        // paired test cleanup retires and reclaims it.
        unsafe { SetWindowLongPtrW(owner, GWLP_USERDATA, state_slot as isize) };
        state_slot
    }

    fn unpublish_test_state(owner: HWND, state_slot: *mut AppStateSlot) {
        // SAFETY: owner is live and this clears its test-owned slot before its
        // unique immediate reclamation.
        unsafe { SetWindowLongPtrW(owner, GWLP_USERDATA, 0) };
        // SAFETY: publication was cleared and every test lease has ended.
        let disposition = unsafe { CallbackState::request_reclaim(state_slot) };
        assert_eq!(disposition, ReclaimDisposition::Reclaimed);
    }
}
