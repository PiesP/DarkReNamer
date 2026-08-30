use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::ColumnState;

const MAGIC: [u8; 8] = *b"DRCOLS\0\0";
const FORMAT_VERSION: u8 = 1;
const COLUMN_COUNT: usize = 7;
const HEADER_LEN: usize = 12;
const RECORD_LEN: usize = 6;
const CHECKSUM_LEN: usize = 4;
const SERIALIZED_LEN: usize = HEADER_LEN + COLUMN_COUNT * RECORD_LEN + CHECKSUM_LEN;
const MAX_INPUT_BYTES: usize = 256;
const MAX_WIDTH_DIP: i32 = 32_768;
const SETTINGS_LEAF: &str = "ui-columns-v1";
static NEXT_TEMP_ID: AtomicU64 = AtomicU64::new(1);

pub(crate) struct ColumnPreferencesLoad {
    pub(crate) columns: [ColumnState; 7],
    pub(crate) failure: Option<io::Error>,
}

#[derive(Clone, Copy)]
struct PreferenceRequest {
    generation: u64,
    columns: [ColumnState; COLUMN_COUNT],
}

#[derive(Default)]
struct PreferenceQueue {
    pending: Option<PreferenceRequest>,
    shutdown: bool,
}

/// Terminal or per-generation result emitted by the durable settings writer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum PreferenceWriteEvent {
    Saved { generation: u64 },
    Failed { generation: u64, error: String },
    Stopped,
    Panicked,
}

type SavePreferences =
    dyn Fn(&Path, &[ColumnState; COLUMN_COUNT]) -> io::Result<()> + Send + Sync + 'static;

/// Single durable writer that coalesces pending UI preference snapshots.
pub(crate) struct PreferencesWriter {
    queue: Arc<(Mutex<PreferenceQueue>, Condvar)>,
    events: Receiver<PreferenceWriteEvent>,
    handle: Option<JoinHandle<()>>,
    next_generation: u64,
}

impl PreferencesWriter {
    pub(crate) fn spawn(
        path: PathBuf,
        wake: impl Fn() + Send + Sync + 'static,
    ) -> io::Result<Self> {
        Self::spawn_with(path, wake, Arc::new(save))
    }

    fn spawn_with(
        path: PathBuf,
        wake: impl Fn() + Send + Sync + 'static,
        save_preferences: Arc<SavePreferences>,
    ) -> io::Result<Self> {
        let queue = Arc::new((Mutex::new(PreferenceQueue::default()), Condvar::new()));
        let worker_queue = Arc::clone(&queue);
        let wake = Arc::new(wake);
        let worker_wake = Arc::clone(&wake);
        let (sender, events) = channel();
        let handle = thread::Builder::new()
            .name("darkrenamer-preferences".to_owned())
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    loop {
                        let request = {
                            let (lock, available) = worker_queue.as_ref();
                            let mut state = lock
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner);
                            while state.pending.is_none() && !state.shutdown {
                                state = available
                                    .wait(state)
                                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                            }
                            match state.pending.take() {
                                Some(request) => request,
                                None => break,
                            }
                        };
                        let event = match save_preferences(&path, &request.columns) {
                            Ok(()) => PreferenceWriteEvent::Saved {
                                generation: request.generation,
                            },
                            Err(error) => PreferenceWriteEvent::Failed {
                                generation: request.generation,
                                error: error.to_string(),
                            },
                        };
                        let _sent = sender.send(event);
                        worker_wake();
                    }
                }));
                let terminal = if outcome.is_ok() {
                    PreferenceWriteEvent::Stopped
                } else {
                    PreferenceWriteEvent::Panicked
                };
                let _sent = sender.send(terminal);
                worker_wake();
            })?;
        Ok(Self {
            queue,
            events,
            handle: Some(handle),
            next_generation: 0,
        })
    }

    pub(crate) fn submit(&mut self, columns: [ColumnState; COLUMN_COUNT]) -> io::Result<u64> {
        if self.is_finished() {
            return Err(io::Error::other("column preference writer has stopped"));
        }
        let generation = self.next_generation.saturating_add(1);
        let (lock, available) = self.queue.as_ref();
        let mut state = lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.shutdown {
            return Err(io::Error::other(
                "column preference writer is shutting down",
            ));
        }
        self.next_generation = generation;
        state.pending = Some(PreferenceRequest {
            generation,
            columns,
        });
        available.notify_one();
        Ok(generation)
    }

    pub(crate) fn shutdown_with(
        &mut self,
        columns: [ColumnState; COLUMN_COUNT],
    ) -> io::Result<u64> {
        if self.is_finished() {
            return Err(io::Error::other("column preference writer has stopped"));
        }
        let generation = self.next_generation.saturating_add(1);
        let (lock, available) = self.queue.as_ref();
        let mut state = lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.shutdown {
            return Ok(self.next_generation);
        }
        self.next_generation = generation;
        state.pending = Some(PreferenceRequest {
            generation,
            columns,
        });
        state.shutdown = true;
        available.notify_one();
        Ok(generation)
    }

    fn request_shutdown(&mut self) {
        let (lock, available) = self.queue.as_ref();
        let mut state = lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.shutdown = true;
        available.notify_one();
    }

    pub(crate) fn drain_events(&self) -> Vec<PreferenceWriteEvent> {
        self.events.try_iter().collect()
    }

    pub(crate) fn is_finished(&self) -> bool {
        self.handle.as_ref().is_none_or(JoinHandle::is_finished)
    }

    pub(crate) fn join(&mut self) -> thread::Result<()> {
        self.request_shutdown();
        self.handle.take().map_or(Ok(()), JoinHandle::join)
    }
}

impl Drop for PreferencesWriter {
    fn drop(&mut self) {
        self.request_shutdown();
        if let Some(handle) = self.handle.take() {
            let _joined = handle.join();
        }
    }
}

pub(crate) fn path_for_journal_root(journal_root: &Path) -> PathBuf {
    journal_root
        .parent()
        .unwrap_or(journal_root)
        .join(SETTINGS_LEAF)
}

pub(crate) fn shown_columns(columns: &[ColumnState; 7]) -> [bool; 4] {
    core::array::from_fn(|index| columns[index + 3].visible)
}

pub(crate) fn load_or_default(path: &Path, defaults: [ColumnState; 7]) -> ColumnPreferencesLoad {
    match read(path) {
        Ok(Some(columns)) => ColumnPreferencesLoad {
            columns,
            failure: None,
        },
        Ok(None) => ColumnPreferencesLoad {
            columns: defaults,
            failure: None,
        },
        Err(error) => ColumnPreferencesLoad {
            columns: defaults,
            failure: Some(error),
        },
    }
}

pub(crate) fn save(path: &Path, columns: &[ColumnState; 7]) -> io::Result<()> {
    let bytes = encode(columns)?;
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "column preference path has no parent",
        )
    })?;
    fs::create_dir_all(parent)?;
    let (temporary_path, mut temporary) = create_process_temp(parent)?;
    let mut cleanup = OwnedTemp::new(temporary_path.clone());
    temporary.write_all(&bytes)?;
    temporary.flush()?;
    temporary.sync_all()?;
    drop(temporary);
    atomic_replace(&temporary_path, path)?;
    cleanup.disarm();
    sync_parent(parent)?;
    Ok(())
}

fn encode(columns: &[ColumnState; COLUMN_COUNT]) -> io::Result<[u8; SERIALIZED_LEN]> {
    let mut output = [0_u8; SERIALIZED_LEN];
    output[..MAGIC.len()].copy_from_slice(&MAGIC);
    output[8] = FORMAT_VERSION;
    output[9] = COLUMN_COUNT as u8;
    for (index, column) in columns.iter().enumerate() {
        if !(0..=MAX_WIDTH_DIP).contains(&column.width_dip) {
            return Err(invalid_data("column width is outside the supported range"));
        }
        let offset = HEADER_LEN + index * RECORD_LEN;
        output[offset] = u8::from(column.visible);
        output[offset + 1] = u8::from(column.user_resized);
        output[offset + 2..offset + RECORD_LEN].copy_from_slice(&column.width_dip.to_le_bytes());
    }
    let checksum_offset = SERIALIZED_LEN - CHECKSUM_LEN;
    let checksum = checksum(&output[..checksum_offset]);
    output[checksum_offset..].copy_from_slice(&checksum.to_le_bytes());
    Ok(output)
}

fn decode(input: &[u8]) -> io::Result<[ColumnState; COLUMN_COUNT]> {
    if input.len() != SERIALIZED_LEN {
        return Err(invalid_data("column preference length is invalid"));
    }
    if input[..MAGIC.len()] != MAGIC
        || input[8] != FORMAT_VERSION
        || usize::from(input[9]) != COLUMN_COUNT
        || input[10..HEADER_LEN] != [0, 0]
    {
        return Err(invalid_data("column preference header is invalid"));
    }
    let checksum_offset = SERIALIZED_LEN - CHECKSUM_LEN;
    let stored = u32::from_le_bytes(
        input[checksum_offset..]
            .try_into()
            .map_err(|_| invalid_data("column preference checksum is missing"))?,
    );
    if checksum(&input[..checksum_offset]) != stored {
        return Err(invalid_data("column preference checksum does not match"));
    }
    let mut columns = crate::default_column_states();
    for (index, column) in columns.iter_mut().enumerate() {
        let offset = HEADER_LEN + index * RECORD_LEN;
        column.visible = decode_flag(input[offset])?;
        column.user_resized = decode_flag(input[offset + 1])?;
        column.width_dip = i32::from_le_bytes(
            input[offset + 2..offset + RECORD_LEN]
                .try_into()
                .map_err(|_| invalid_data("column preference width is missing"))?,
        );
        if !(0..=MAX_WIDTH_DIP).contains(&column.width_dip) {
            return Err(invalid_data("column width is outside the supported range"));
        }
    }
    Ok(columns)
}

fn decode_flag(value: u8) -> io::Result<bool> {
    match value {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(invalid_data("column preference flag is invalid")),
    }
}

fn checksum(input: &[u8]) -> u32 {
    input.iter().fold(2_166_136_261_u32, |hash, byte| {
        (hash ^ u32::from(*byte)).wrapping_mul(16_777_619)
    })
}

fn read(path: &Path) -> io::Result<Option<[ColumnState; COLUMN_COUNT]>> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if !file.metadata()?.is_file() {
        return Err(invalid_data("column preference is not a regular file"));
    }
    let mut bytes = Vec::with_capacity(SERIALIZED_LEN);
    Read::by_ref(&mut file)
        .take((MAX_INPUT_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_INPUT_BYTES {
        return Err(invalid_data("column preference exceeds the size limit"));
    }
    decode(&bytes).map(Some)
}

fn create_process_temp(parent: &Path) -> io::Result<(PathBuf, File)> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    for _ in 0..16 {
        let id = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
        let leaf = format!(
            ".{SETTINGS_LEAF}.{}.{}.{}.tmp",
            std::process::id(),
            timestamp,
            id
        );
        let path = parent.join(leaf);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate a unique column preference temporary file",
    ))
}

struct OwnedTemp {
    path: PathBuf,
    armed: bool,
}

impl OwnedTemp {
    fn new(path: PathBuf) -> Self {
        Self { path, armed: true }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for OwnedTemp {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

#[cfg(windows)]
fn atomic_replace(source: &Path, destination: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    };

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(core::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(core::iter::once(0))
        .collect::<Vec<_>>();
    // SAFETY: both paths are owned, NUL-terminated UTF-16 buffers retained for
    // this synchronous call; the source is the exact same-directory temp file
    // created by this process and the destination is the settings leaf.
    if unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    } == 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn atomic_replace(source: &Path, destination: &Path) -> io::Result<()> {
    fs::rename(source, destination)
}

#[cfg(windows)]
fn sync_parent(_parent: &Path) -> io::Result<()> {
    // MOVEFILE_WRITE_THROUGH waits for the replace operation to reach storage.
    Ok(())
}

#[cfg(not(windows))]
fn sync_parent(parent: &Path) -> io::Result<()> {
    File::open(parent)?.sync_all()
}

fn invalid_data(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc;

    use super::*;
    use crate::default_column_states;

    fn customized_columns() -> [ColumnState; 7] {
        let mut columns = default_column_states();
        columns[0].record_user_resize(277, 96);
        columns[1].record_user_resize(411, 144);
        columns[2].record_user_resize(0, 96);
        columns[3].set_visible(true);
        columns[3].record_user_resize(166, 96);
        columns[4].set_visible(true);
        columns[4].record_user_resize(125, 120);
        columns[5].record_user_resize(240, 192);
        columns[6].set_visible(true);
        columns
    }

    #[test]
    fn codec_round_trip_preserves_all_seven_column_states() -> io::Result<()> {
        let columns = customized_columns();
        let encoded = encode(&columns)?;
        assert_eq!(decode(&encoded)?, columns);
        Ok(())
    }

    #[test]
    fn codec_rejects_corrupt_and_trailing_input() -> io::Result<()> {
        let columns = customized_columns();
        let mut corrupt = encode(&columns)?.to_vec();
        corrupt[16] ^= 0x40;
        assert!(matches!(
            decode(&corrupt),
            Err(error) if error.kind() == io::ErrorKind::InvalidData
        ));

        let mut trailing = encode(&columns)?.to_vec();
        trailing.push(0);
        assert!(matches!(
            decode(&trailing),
            Err(error) if error.kind() == io::ErrorKind::InvalidData
        ));
        Ok(())
    }

    #[test]
    fn corrupt_and_oversized_files_fall_back_to_safe_defaults() -> io::Result<()> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("ui-columns-v1");
        let defaults = default_column_states();

        fs::write(&path, b"not a preference file")?;
        let corrupt = load_or_default(&path, defaults);
        assert_eq!(corrupt.columns, defaults);
        assert!(corrupt.failure.is_some());

        fs::write(&path, vec![0_u8; MAX_INPUT_BYTES + 1])?;
        let oversized = load_or_default(&path, defaults);
        assert_eq!(oversized.columns, defaults);
        assert!(oversized.failure.is_some());
        Ok(())
    }

    #[test]
    fn missing_file_uses_defaults_without_a_failure() -> io::Result<()> {
        let defaults = default_column_states();
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("missing-ui-columns-v1");
        let loaded = load_or_default(&path, defaults);
        assert_eq!(loaded.columns, defaults);
        assert!(loaded.failure.is_none());
        Ok(())
    }

    #[test]
    fn durable_save_replaces_and_reloads_preferences() -> io::Result<()> {
        let directory = tempfile::tempdir()?;
        let app_root = directory.path().join("DarkReNamer");
        let journal_root = app_root.join("journal");
        let path = path_for_journal_root(&journal_root);
        assert_eq!(path, app_root.join("ui-columns-v1"));

        let first = customized_columns();
        save(&path, &first)?;
        assert_eq!(
            load_or_default(&path, default_column_states()).columns,
            first
        );

        let mut second = first;
        second[3].set_visible(false);
        second[6].record_user_resize(801, 144);
        save(&path, &second)?;
        let reloaded = load_or_default(&path, default_column_states());
        assert_eq!(reloaded.columns, second);
        assert!(reloaded.failure.is_none());
        assert_eq!(shown_columns(&reloaded.columns), [false, true, false, true]);
        Ok(())
    }

    #[test]
    fn writer_coalesces_pending_snapshots_and_flushes_latest_on_shutdown()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("ui-columns-v1");
        let writes = Arc::new(Mutex::new(Vec::new()));
        let worker_writes = Arc::clone(&writes);
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let worker_gate = Arc::clone(&gate);
        let calls = Arc::new(AtomicUsize::new(0));
        let worker_calls = Arc::clone(&calls);
        let (started_sender, started_receiver) = mpsc::channel();
        let save_preferences = Arc::new(move |_path: &Path, columns: &[ColumnState; 7]| {
            worker_writes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(*columns);
            if worker_calls.fetch_add(1, Ordering::AcqRel) == 0 {
                let _sent = started_sender.send(());
                let (lock, available) = worker_gate.as_ref();
                let mut released = lock
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                while !*released {
                    released = available
                        .wait(released)
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                }
            }
            Ok(())
        });
        let mut writer = PreferencesWriter::spawn_with(path, || {}, save_preferences)?;
        let first = customized_columns();
        let mut second = first;
        second[3].set_visible(false);
        let mut third = second;
        third[6].record_user_resize(900, 144);

        writer.submit(first)?;
        started_receiver.recv()?;
        writer.submit(second)?;
        writer.shutdown_with(third)?;
        {
            let (lock, available) = gate.as_ref();
            *lock
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = true;
            available.notify_one();
        }
        writer
            .join()
            .map_err(|_| io::Error::other("preference writer panicked"))?;

        assert_eq!(
            *writes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            vec![first, third]
        );
        Ok(())
    }

    #[test]
    fn writer_reports_failure_then_persists_final_retry() -> Result<(), Box<dyn std::error::Error>>
    {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("ui-columns-v1");
        let calls = Arc::new(AtomicUsize::new(0));
        let worker_calls = Arc::clone(&calls);
        let (wake_sender, wake_receiver) = mpsc::channel();
        let save_preferences = Arc::new(move |_path: &Path, _columns: &[ColumnState; 7]| {
            if worker_calls.fetch_add(1, Ordering::AcqRel) == 0 {
                Err(io::Error::other("injected write failure"))
            } else {
                Ok(())
            }
        });
        let mut writer = PreferencesWriter::spawn_with(
            path,
            move || {
                let _sent = wake_sender.send(());
            },
            save_preferences,
        )?;
        let first = customized_columns();
        let mut final_columns = first;
        final_columns[4].set_visible(true);

        writer.submit(first)?;
        wake_receiver.recv()?;
        assert!(matches!(
            writer.drain_events().as_slice(),
            [PreferenceWriteEvent::Failed { generation: 1, .. }]
        ));
        writer.shutdown_with(final_columns)?;
        writer
            .join()
            .map_err(|_| io::Error::other("preference writer panicked"))?;
        assert_eq!(
            writer.drain_events(),
            vec![
                PreferenceWriteEvent::Saved { generation: 2 },
                PreferenceWriteEvent::Stopped,
            ]
        );
        Ok(())
    }

    #[test]
    fn production_writer_flushes_final_snapshot_before_join() -> io::Result<()> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("ui-columns-v1");
        let mut columns = customized_columns();
        columns[5].set_visible(true);
        let mut writer = PreferencesWriter::spawn(path.clone(), || {})?;

        writer.shutdown_with(columns)?;
        writer
            .join()
            .map_err(|_| io::Error::other("preference writer panicked"))?;

        assert_eq!(
            load_or_default(&path, default_column_states()).columns,
            columns
        );
        Ok(())
    }
}
