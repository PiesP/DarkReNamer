//! One tracked Shell-icon worker and its bounded, pointer-free handoff.

#[cfg(test)]
use std::cell::Cell;
use std::io;
use std::marker::PhantomData;
use std::mem::size_of;
use std::num::NonZeroIsize;
use std::ptr::{null, null_mut};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, TryLockError};
use std::thread::{self, JoinHandle};

use windows_sys::Win32::Foundation::{MAX_PATH, WAIT_FAILED};
use windows_sys::Win32::Storage::FileSystem::{FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL};
use windows_sys::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize};
use windows_sys::Win32::System::Threading::GetCurrentThreadId;
use windows_sys::Win32::UI::Controls::{I_IMAGENONE, ImageList_GetImageCount};
#[cfg(test)]
use windows_sys::Win32::UI::Controls::{
    ICC_WIN95_CLASSES, ILC_COLOR32, ILC_MASK, INITCOMMONCONTROLSEX, ImageList_Create,
    ImageList_Destroy, ImageList_ReplaceIcon, InitCommonControlsEx,
};
use windows_sys::Win32::UI::Shell::{
    SHFILEINFOW, SHGFI_SMALLICON, SHGFI_SYSICONINDEX, SHGFI_USEFILEATTRIBUTES, SHGetFileInfoW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MSG, MWMO_INPUTAVAILABLE, MsgWaitForMultipleObjectsEx, PM_REMOVE,
    PeekMessageW, PostThreadMessageW, QS_ALLINPUT, TranslateMessage, WM_QUIT,
};
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::{IDI_APPLICATION, LoadIconW};

use crate::icon_cache::IconCacheKey;
use crate::icon_requests::{
    Completion, CompletionDisposition, IconRequests, RequestKey, SubmitDisposition,
};

use super::{WM_APP_ICON_WAKE, WM_APP_ICON_WORK};

static NEXT_ICON_SESSION: AtomicU64 = AtomicU64::new(1);
#[cfg(test)]
thread_local! {
    static FAIL_NEXT_ICON_SPAWN: Cell<bool> = const { Cell::new(false) };
}
const IDLE_WAIT_MS: u32 = 250;
const MAX_PUMP_MESSAGES: usize = 256;

/// A read-only process-shared Shell image list, validated on the Shell thread.
/// Its scalar identity is transferred; neither thread owns or destroys it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct BorrowedSystemImageList(NonZeroIsize);

impl BorrowedSystemImageList {
    fn validate(raw: usize) -> Option<Self> {
        let identity = NonZeroIsize::new(raw as isize)?;
        // SAFETY: SHGetFileInfoW returned this process-shared system list.
        // ImageList_GetImageCount is read-only and rejects an unusable list.
        (unsafe { ImageList_GetImageCount(identity.get()) } > 0).then_some(Self(identity))
    }

    pub(super) const fn raw(self) -> isize {
        self.0.get()
    }
}

/// Owns a populated native image list for controlled worker tests only. The
/// caller keeps it alive until every attached ListView is destroyed and every
/// worker borrowing its scalar identity has joined.
#[cfg(test)]
pub(super) struct OwnedTestImageList(NonZeroIsize);

#[cfg(test)]
impl OwnedTestImageList {
    pub(super) fn new() -> io::Result<Self> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_WIN95_CLASSES,
        };
        // SAFETY: the exact-sized descriptor remains live through the call.
        if unsafe { InitCommonControlsEx(&controls) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the image list is local to this test and destroyed by Drop.
        let raw = unsafe { ImageList_Create(16, 16, ILC_COLOR32 | ILC_MASK, 2, 1) };
        let Some(identity) = NonZeroIsize::new(raw) else {
            return Err(io::Error::other("test image list creation failed"));
        };
        let owned = Self(identity);
        // SAFETY: null selects a predefined shared icon. LoadIconW retains its
        // ownership; ImageList_ReplaceIcon copies it into the owned list.
        let icon = unsafe { LoadIconW(null_mut(), IDI_APPLICATION) };
        if icon.is_null() {
            return Err(io::Error::other("test shared icon load failed"));
        }
        for index in 0..2 {
            // SAFETY: both native handles are live for this synchronous copy.
            if unsafe { ImageList_ReplaceIcon(owned.0.get(), -1, icon) } != index {
                return Err(io::Error::other("test image list population failed"));
            }
        }
        // SAFETY: the owned list remains live; this read verifies the exact
        // indices used by the controlled stale-result and update cases.
        if unsafe { ImageList_GetImageCount(owned.0.get()) } != 2 {
            return Err(io::Error::other("test image list has wrong size"));
        }
        Ok(owned)
    }

    pub(super) const fn borrowed(&self) -> BorrowedSystemImageList {
        BorrowedSystemImageList(self.0)
    }
}

#[cfg(test)]
impl Drop for OwnedTestImageList {
    fn drop(&mut self) {
        // SAFETY: the test wrapper outlives its worker guardian and the
        // production popup window, including their unwinding cleanup.
        unsafe { ImageList_Destroy(self.0.get()) };
    }
}

#[derive(Clone, Debug)]
pub(super) enum IconResult {
    Bootstrap(Option<BorrowedSystemImageList>),
    Class {
        list: Option<BorrowedSystemImageList>,
        index: i32,
    },
}

pub(super) enum IconSubmit {
    State(SubmitDisposition),
    Busy,
    Unavailable,
}

#[derive(Default)]
struct WorkWake {
    thread_id: u32,
    pending: bool,
}

/// The worker's entire shared state; no AppState, HWND, or model pointer enters it.
pub(super) struct IconShared {
    requests: Mutex<IconRequests<IconCacheKey, IconResult>>,
    retiring: AtomicBool,
    owner_destroyed: AtomicBool,
    unavailable: AtomicBool,
    wake_enabled: AtomicBool,
    ui_wake_pending: AtomicBool,
    #[cfg(test)]
    lose_next_ui_wake: AtomicBool,
    ui_thread_id: u32,
    work_wake: Mutex<WorkWake>,
    pending: AtomicUsize,
    queued: AtomicUsize,
    in_flight: AtomicUsize,
    completed: AtomicUsize,
    generation: AtomicU64,
    status_revision: AtomicU64,
    session: u64,
    joined: AtomicBool,
}

impl IconShared {
    fn new(session: u64, ui_thread_id: u32) -> Self {
        let mut requests = IconRequests::new(session);
        let bootstrap = requests.submit(RequestKey::Bootstrap);
        debug_assert_eq!(bootstrap, SubmitDisposition::Queued);
        Self {
            requests: Mutex::new(requests),
            retiring: AtomicBool::new(false),
            owner_destroyed: AtomicBool::new(false),
            unavailable: AtomicBool::new(false),
            wake_enabled: AtomicBool::new(true),
            ui_wake_pending: AtomicBool::new(false),
            #[cfg(test)]
            lose_next_ui_wake: AtomicBool::new(false),
            ui_thread_id,
            work_wake: Mutex::new(WorkWake::default()),
            pending: AtomicUsize::new(1),
            queued: AtomicUsize::new(1),
            in_flight: AtomicUsize::new(0),
            completed: AtomicUsize::new(0),
            generation: AtomicU64::new(0),
            status_revision: AtomicU64::new(0),
            session,
            joined: AtomicBool::new(false),
        }
    }

    fn lock_requests(&self) -> std::sync::MutexGuard<'_, IconRequests<IconCacheKey, IconResult>> {
        self.requests
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn update_pending(&self, requests: &IconRequests<IconCacheKey, IconResult>) {
        if self
            .status_revision
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
                value.checked_add(1)
            })
            .is_err()
        {
            self.unavailable.store(true, Ordering::Release);
            self.retiring.store(true, Ordering::Release);
            return;
        }
        self.pending
            .store(requests.pending_count(), Ordering::Release);
        self.queued
            .store(requests.queued_count(), Ordering::Release);
        self.in_flight
            .store(requests.in_flight_count(), Ordering::Release);
        self.completed
            .store(requests.completed_count(), Ordering::Release);
        self.generation
            .store(requests.generation(), Ordering::Release);
        if self
            .status_revision
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
                value.checked_add(1)
            })
            .is_err()
        {
            self.unavailable.store(true, Ordering::Release);
            self.retiring.store(true, Ordering::Release);
        }
    }

    fn signal_worker(&self) {
        if self.joined.load(Ordering::Acquire) {
            return;
        }
        let Ok(mut wake) = self.work_wake.try_lock() else {
            return;
        };
        if wake.thread_id != 0 && !wake.pending {
            wake.pending = true;
            // SAFETY: the worker creates its queue before publishing this ID;
            // terminal teardown clears it under this same gate, so the ID
            // cannot be reused before this pointer-free post completes.
            // A failed post is covered by the finite idle wait.
            unsafe { PostThreadMessageW(wake.thread_id, WM_APP_ICON_WORK, 0, 0) };
        }
    }

    fn signal_ui(&self) {
        if self.wake_enabled.load(Ordering::Acquire)
            && !self.ui_wake_pending.swap(true, Ordering::AcqRel)
        {
            #[cfg(test)]
            if self.lose_next_ui_wake.swap(false, Ordering::AcqRel) {
                return;
            }
            // SAFETY: run owns this UI thread through terminal join. The
            // thread message carries no HWND or pointer; a live-window timer
            // covers a failed post or a modal loop consuming it.
            unsafe { PostThreadMessageW(self.ui_thread_id, WM_APP_ICON_WAKE, 0, 0) };
        }
    }

    /// A disjoint callback sidecar may call this during busy WM_DESTROY.
    /// The in-flight Shell call remains tracked until the run guardian joins.
    pub(super) fn request_retire(&self) {
        self.retiring.store(true, Ordering::Release);
        self.wake_enabled.store(false, Ordering::Release);
        if let Ok(mut requests) = self.requests.try_lock() {
            requests.retire();
            self.update_pending(&requests);
        }
        self.signal_worker();
    }

    pub(super) fn request_destroy_retire(&self) {
        self.owner_destroyed.store(true, Ordering::Release);
        self.request_retire();
    }

    pub(super) fn submit(&self, key: IconCacheKey) -> IconSubmit {
        if self.retiring.load(Ordering::Acquire) || self.unavailable.load(Ordering::Acquire) {
            return IconSubmit::Unavailable;
        }
        let mut requests = match self.requests.try_lock() {
            Ok(requests) => requests,
            Err(TryLockError::WouldBlock) => return IconSubmit::Busy,
            Err(TryLockError::Poisoned(_)) => {
                self.request_retire();
                return IconSubmit::Unavailable;
            }
        };
        if self.retiring.load(Ordering::Acquire) {
            return IconSubmit::Unavailable;
        }
        let disposition = requests.submit(RequestKey::Class(key));
        self.update_pending(&requests);
        drop(requests);
        if disposition == SubmitDisposition::Queued {
            self.signal_worker();
        }
        IconSubmit::State(disposition)
    }

    pub(super) fn advance_generation(&self) -> bool {
        let Ok(mut requests) = self.requests.try_lock() else {
            return false;
        };
        if !requests.advance_generation() {
            self.unavailable.store(true, Ordering::Release);
        }
        self.update_pending(&requests);
        drop(requests);
        if !self.retiring.load(Ordering::Acquire) && !self.unavailable.load(Ordering::Acquire) {
            self.signal_worker();
        }
        true
    }

    pub(super) fn snapshot_completions(&self) -> Option<Vec<Completion<IconCacheKey, IconResult>>> {
        self.ui_wake_pending.store(false, Ordering::Release);
        let requests = match self.requests.try_lock() {
            Ok(requests) => requests,
            Err(TryLockError::WouldBlock) => return None,
            Err(TryLockError::Poisoned(_)) => {
                self.request_retire();
                return None;
            }
        };
        Some(requests.completed_snapshot())
    }

    pub(super) fn acknowledge_completions(&self, count: usize) -> bool {
        let Ok(mut requests) = self.requests.try_lock() else {
            return false;
        };
        let acknowledged = requests.acknowledge_completions(count);
        self.update_pending(&requests);
        drop(requests);
        if acknowledged != 0 {
            self.signal_worker();
        }
        true
    }

    pub(super) fn pending_count(&self) -> usize {
        self.pending.load(Ordering::Acquire)
    }

    pub(super) fn status_counts(&self) -> (usize, usize, usize) {
        (
            self.queued.load(Ordering::Acquire),
            self.in_flight.load(Ordering::Acquire),
            self.completed.load(Ordering::Acquire),
        )
    }

    pub(super) fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    pub(super) fn status_revision(&self) -> u64 {
        self.status_revision.load(Ordering::Acquire)
    }

    pub(super) fn session(&self) -> u64 {
        self.session
    }

    pub(super) fn is_unavailable(&self) -> bool {
        self.unavailable.load(Ordering::Acquire) || self.retiring.load(Ordering::Acquire)
    }

    #[cfg(test)]
    pub(super) fn post_quit_for_test(&self) -> bool {
        let wake = self
            .work_wake
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        wake.thread_id != 0
            // SAFETY: the test holds the same gate that terminal teardown uses
            // before a worker thread ID can be reused. WM_QUIT is pointer-free.
            && unsafe { PostThreadMessageW(wake.thread_id, WM_QUIT, 0, 0) } != 0
    }

    #[cfg(test)]
    pub(super) fn lose_next_ui_wake_for_test(&self) {
        self.lose_next_ui_wake.store(true, Ordering::Release);
    }

    #[cfg(test)]
    pub(super) fn test_ui_wake_loss_pending(&self) -> bool {
        self.lose_next_ui_wake.load(Ordering::Acquire)
    }

    pub(super) fn owner_destroyed(&self) -> bool {
        self.owner_destroyed.load(Ordering::Acquire)
    }

    pub(super) fn is_joined(&self) -> bool {
        self.joined.load(Ordering::Acquire)
    }

    fn next_request(&self) -> Option<crate::icon_requests::Request<IconCacheKey>> {
        let mut requests = self.lock_requests();
        if self.retiring.load(Ordering::Acquire) {
            requests.retire();
            self.update_pending(&requests);
            return None;
        }
        let next = requests.take_next();
        self.update_pending(&requests);
        next
    }

    fn publish(&self, token: crate::icon_requests::RequestToken, result: IconResult) {
        let mut requests = self.lock_requests();
        if self.retiring.load(Ordering::Acquire) {
            requests.retire();
        }
        let disposition = requests.complete(token, result);
        self.update_pending(&requests);
        drop(requests);
        if disposition != CompletionDisposition::Unexpected {
            self.signal_ui();
        }
    }
}

struct WorkerCom;

impl WorkerCom {
    fn initialize() -> Option<Self> {
        // SAFETY: a fresh worker initializes its own STA before Shell calls;
        // the null reserved pointer and flags follow CoInitializeEx's ABI.
        (unsafe { CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) } >= 0).then_some(Self)
    }
}

impl Drop for WorkerCom {
    fn drop(&mut self) {
        // SAFETY: this guard is created and dropped on the same Shell thread,
        // balancing exactly one successful CoInitializeEx call.
        unsafe { CoUninitialize() };
    }
}

pub(super) struct ShellLookup {
    _com: WorkerCom,
    image_list: Option<BorrowedSystemImageList>,
}

impl ShellLookup {
    pub(super) fn initialize() -> Option<Self> {
        Some(Self {
            _com: WorkerCom::initialize()?,
            image_list: None,
        })
    }

    pub(super) fn query(&mut self, key: &RequestKey<IconCacheKey>) -> IconResult {
        match key {
            RequestKey::Bootstrap => {
                let mut info = SHFILEINFOW::default();
                let representative: Vec<u16> = "icon.txt\0".encode_utf16().collect();
                // SAFETY: the short terminated UTF-16 representative and
                // writable info outlive this synchronous call on the
                // COM-initialized worker. USEFILEATTRIBUTES avoids file access.
                let raw = unsafe {
                    SHGetFileInfoW(
                        representative.as_ptr(),
                        FILE_ATTRIBUTE_NORMAL,
                        &mut info,
                        size_of::<SHFILEINFOW>() as u32,
                        SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON,
                    )
                };
                self.image_list = BorrowedSystemImageList::validate(raw);
                IconResult::Bootstrap(self.image_list)
            }
            RequestKey::Class(key) => {
                let Some(expected_list) = self.image_list else {
                    return IconResult::Class {
                        list: None,
                        index: I_IMAGENONE,
                    };
                };
                let text = key.lookup_text();
                // SHGetFileInfoW's representative path uses MAX_PATH storage.
                // An overlong case-folded extension safely has no image.
                if text.len() >= MAX_PATH as usize {
                    return IconResult::Class {
                        list: Some(expected_list),
                        index: I_IMAGENONE,
                    };
                }
                let mut path = text.units().to_vec();
                path.push(0);
                let mut info = SHFILEINFOW::default();
                let attributes = if matches!(key, IconCacheKey::Directory) {
                    FILE_ATTRIBUTE_DIRECTORY
                } else {
                    FILE_ATTRIBUTE_NORMAL
                };
                // SAFETY: the bounded terminated representative and writable
                // SHFILEINFOW live through this worker-only synchronous call.
                let raw = unsafe {
                    SHGetFileInfoW(
                        path.as_ptr(),
                        attributes,
                        &mut info,
                        size_of::<SHFILEINFOW>() as u32,
                        SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON,
                    )
                };
                let list = BorrowedSystemImageList::validate(raw);
                let index = if list == Some(expected_list) && info.iIcon >= 0 {
                    info.iIcon
                } else {
                    I_IMAGENONE
                };
                IconResult::Class { list, index }
            }
        }
    }
}

/// Controlled native tests exercise the real handoff and ListView update with
/// a test-owned list. COM still starts and ends on the actual worker thread.
#[cfg(test)]
pub(super) struct ControlledIconLookup {
    _com: WorkerCom,
    image_list: BorrowedSystemImageList,
}

#[cfg(test)]
impl ControlledIconLookup {
    pub(super) fn initialize(image_list: BorrowedSystemImageList) -> Option<Self> {
        Some(Self {
            _com: WorkerCom::initialize()?,
            image_list,
        })
    }

    pub(super) const fn image_list(&self) -> BorrowedSystemImageList {
        self.image_list
    }

    pub(super) fn query(&self, key: &RequestKey<IconCacheKey>) -> IconResult {
        match key {
            RequestKey::Bootstrap => IconResult::Bootstrap(Some(self.image_list)),
            RequestKey::Class(_) => IconResult::Class {
                list: Some(self.image_list),
                index: 0,
            },
        }
    }
}

fn pump_worker_messages() -> bool {
    let mut message = MSG::default();
    for _ in 0..MAX_PUMP_MESSAGES {
        // SAFETY: this worker owns its thread queue; message is writable and
        // remains live through synchronous dispatch of a copied OS message.
        if unsafe { PeekMessageW(&mut message, null_mut(), 0, 0, PM_REMOVE) } == 0 {
            break;
        }
        if message.message == WM_QUIT {
            return false;
        }
        if message.message != WM_APP_ICON_WORK {
            // SAFETY: COM-created worker windows own their own callbacks; no
            // application HWND or AppState pointer crosses this dispatch.
            unsafe {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }
    true
}

fn worker_loop<F, Q>(shared: Arc<IconShared>, initialize: F)
where
    F: FnOnce() -> Option<Q>,
    Q: FnMut(&RequestKey<IconCacheKey>) -> IconResult,
{
    struct ThreadIdClear(Arc<IconShared>);
    impl Drop for ThreadIdClear {
        fn drop(&mut self) {
            let mut wake = self
                .0
                .work_wake
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            wake.thread_id = 0;
            wake.pending = false;
        }
    }
    let _thread_id_clear = ThreadIdClear(Arc::clone(&shared));
    let mut message = MSG::default();
    // SAFETY: a benign peek creates this worker's message queue before its
    // thread ID is published for pointer-free UI-to-worker wakes.
    unsafe { PeekMessageW(&mut message, null_mut(), 0, 0, 0) };
    // SAFETY: this value is the current worker thread's ID and outlives all
    // posts because run owns its JoinHandle until terminal completion.
    {
        let mut wake = shared
            .work_wake
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        // SAFETY: the published ID is the current worker thread, whose queue
        // was created above before any UI-side post can target it.
        wake.thread_id = unsafe { GetCurrentThreadId() };
    }
    let Some(mut lookup) = initialize() else {
        shared.unavailable.store(true, Ordering::Release);
        shared.request_retire();
        shared.signal_ui();
        return;
    };
    loop {
        if !pump_worker_messages() {
            shared.request_retire();
        }
        {
            let mut wake = shared
                .work_wake
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            wake.pending = false;
        }
        if let Some(request) = shared.next_request() {
            let result = lookup(&request.key);
            let bootstrap_failed = matches!(result, IconResult::Bootstrap(None));
            shared.publish(request.token, result);
            if bootstrap_failed {
                shared.unavailable.store(true, Ordering::Release);
                shared.request_retire();
            }
            continue;
        }
        if shared.retiring.load(Ordering::Acquire) {
            break;
        }
        // SAFETY: this STA waits for messages with a finite fallback interval.
        // The zero-handle wait pumps COM-created window traffic on the next
        // iteration and catches a failed PostThreadMessageW admission wake.
        let wait = unsafe {
            MsgWaitForMultipleObjectsEx(0, null(), IDLE_WAIT_MS, QS_ALLINPUT, MWMO_INPUTAVAILABLE)
        };
        if wait == WAIT_FAILED {
            thread::sleep(std::time::Duration::from_millis(10));
        }
    }
    shared.signal_ui();
}

/// The sole JoinHandle owner stays in run scope; AppState holds only IconShared.
pub(super) struct IconRunGuardian {
    pub(super) shared: Arc<IconShared>,
    handle: Option<JoinHandle<()>>,
    _ui_thread_only: PhantomData<Rc<()>>,
}

impl IconRunGuardian {
    #[cfg(test)]
    pub(super) fn fail_next_spawn_for_test() {
        FAIL_NEXT_ICON_SPAWN.with(|failure| failure.set(true));
    }

    pub(super) fn start(ui_thread_id: u32) -> io::Result<Self> {
        Self::start_with(ui_thread_id, || {
            ShellLookup::initialize()
                .map(|mut shell| move |key: &RequestKey<IconCacheKey>| shell.query(key))
        })
    }

    pub(super) fn start_with<F, Q>(ui_thread_id: u32, initialize: F) -> io::Result<Self>
    where
        F: FnOnce() -> Option<Q> + Send + 'static,
        Q: FnMut(&RequestKey<IconCacheKey>) -> IconResult + Send + 'static,
    {
        let session = NEXT_ICON_SESSION
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
                value.checked_add(1)
            })
            .map_err(|_| io::Error::other("icon session identifiers exhausted"))?;
        let shared = Arc::new(IconShared::new(session, ui_thread_id));
        #[cfg(test)]
        if FAIL_NEXT_ICON_SPAWN.with(|failure| failure.replace(false)) {
            return Err(io::Error::other("injected icon thread spawn failure"));
        }
        let worker_shared = Arc::clone(&shared);
        let handle = thread::Builder::new()
            .name("darknamer-shell-icons".to_owned())
            .spawn(move || worker_loop(worker_shared, initialize))?;
        Ok(Self {
            shared,
            handle: Some(handle),
            _ui_thread_only: PhantomData,
        })
    }

    pub(super) fn poll_join(&mut self) -> bool {
        if self.handle.as_ref().is_some_and(JoinHandle::is_finished) {
            let Some(handle) = self.handle.take() else {
                return true;
            };
            if handle.join().is_err() {
                self.shared.unavailable.store(true, Ordering::Release);
                self.shared.request_retire();
            }
            self.shared.joined.store(true, Ordering::Release);
        }
        self.handle.is_none()
    }

    pub(super) fn retire(&self) {
        self.shared.request_retire();
    }

    /// Message-aware fallback for forced destruction or a failed GetMessageW.
    /// This has no provider deadline; only an observed finished thread is joined.
    pub(super) fn retire_and_join_responsively(&mut self) {
        self.retire();
        let mut message = MSG::default();
        while !self.poll_join() {
            for _ in 0..MAX_PUMP_MESSAGES {
                // SAFETY: run owns this UI thread; the message is writable and
                // is dispatched without any AppState or guardian borrow.
                if unsafe { PeekMessageW(&mut message, null_mut(), 0, 0, PM_REMOVE) } == 0 {
                    break;
                }
                if message.message != WM_QUIT && message.message != WM_APP_ICON_WAKE {
                    // SAFETY: copied OS message remains live for this call.
                    unsafe {
                        TranslateMessage(&message);
                        DispatchMessageW(&message);
                    }
                }
            }
            if self.poll_join() {
                break;
            }
            // SAFETY: UI input remains serviceable while the tracked worker is
            // in Shell; failed waits retry after a finite sleep without joining.
            let wait = unsafe {
                MsgWaitForMultipleObjectsEx(
                    0,
                    null(),
                    IDLE_WAIT_MS,
                    QS_ALLINPUT,
                    MWMO_INPUTAVAILABLE,
                )
            };
            if wait == WAIT_FAILED {
                thread::sleep(std::time::Duration::from_millis(10));
            }
        }
    }
}

impl Drop for IconRunGuardian {
    fn drop(&mut self) {
        if self.handle.is_some() {
            self.retire_and_join_responsively();
        }
    }
}
