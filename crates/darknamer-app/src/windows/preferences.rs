use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{AppThemeMode, ColumnState, PreviewEmphasis, RailDensityPreference, UiAppearance};

#[path = "preference_lifecycle.rs"]
pub(crate) mod lifecycle;

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
const APPEARANCE_MAGIC: [u8; 8] = *b"DRAPPR\0\0";
const APPEARANCE_FORMAT_VERSION: u8 = 1;
const APPEARANCE_HEADER_LEN: usize = 12;
const APPEARANCE_PAYLOAD_LEN: usize = 8;
const APPEARANCE_CHECKSUM_LEN: usize = 4;
const APPEARANCE_SERIALIZED_LEN: usize =
    APPEARANCE_HEADER_LEN + APPEARANCE_PAYLOAD_LEN + APPEARANCE_CHECKSUM_LEN;
const APPEARANCE_MAX_INPUT_BYTES: usize = 64;
const APPEARANCE_SETTINGS_LEAF: &str = "ui-appearance-v1";
static NEXT_TEMP_ID: AtomicU64 = AtomicU64::new(1);

pub(crate) struct ColumnPreferencesLoad {
    pub(crate) columns: [ColumnState; 7],
    pub(crate) failure: Option<io::Error>,
}

pub(crate) struct AppearancePreferencesLoad {
    pub(crate) appearance: UiAppearance,
    pub(crate) failure: Option<io::Error>,
}

struct PreferenceRequest<T> {
    generation: u64,
    snapshot: T,
}

struct PreferenceQueue<T> {
    pending: Option<PreferenceRequest<T>>,
    shutdown: bool,
}

impl<T> Default for PreferenceQueue<T> {
    fn default() -> Self {
        Self {
            pending: None,
            shutdown: false,
        }
    }
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

/// Each instance owns its own queue, generation stream, worker, and results.
struct CoalescingWriter<T> {
    queue: Arc<(Mutex<PreferenceQueue<T>>, Condvar)>,
    events: Receiver<PreferenceWriteEvent>,
    handle: Option<JoinHandle<()>>,
    next_generation: u64,
}

impl<T: Send + 'static> CoalescingWriter<T> {
    fn spawn(
        path: PathBuf,
        thread_name: &'static str,
        wake: impl Fn() + Send + Sync + 'static,
        save: impl Fn(&Path, T) -> io::Result<()> + Send + Sync + 'static,
    ) -> io::Result<Self> {
        let queue = Arc::new((Mutex::new(PreferenceQueue::default()), Condvar::new()));
        let worker_queue = Arc::clone(&queue);
        let (sender, events) = channel();
        let handle = thread::Builder::new()
            .name(thread_name.to_owned())
            .spawn(move || {
                // The shipped abort profile still aborts on panic; this event is
                // observable in the unwind test profile only.
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
                        let event = match save(&path, request.snapshot) {
                            Ok(()) => PreferenceWriteEvent::Saved {
                                generation: request.generation,
                            },
                            Err(error) => PreferenceWriteEvent::Failed {
                                generation: request.generation,
                                error: error.to_string(),
                            },
                        };
                        let _sent = sender.send(event);
                        wake();
                    }
                }));
                let terminal = if outcome.is_ok() {
                    PreferenceWriteEvent::Stopped
                } else {
                    PreferenceWriteEvent::Panicked
                };
                let _sent = sender.send(terminal);
                wake();
            })?;
        Ok(Self {
            queue,
            events,
            handle: Some(handle),
            next_generation: 0,
        })
    }

    fn submit(
        &mut self,
        snapshot: T,
        stopped: &'static str,
        shutting_down: &'static str,
    ) -> io::Result<u64> {
        if self.is_finished() {
            return Err(io::Error::other(stopped));
        }
        let generation = self.next_generation.saturating_add(1);
        let (lock, available) = self.queue.as_ref();
        let mut state = lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.shutdown {
            return Err(io::Error::other(shutting_down));
        }
        self.next_generation = generation;
        state.pending = Some(PreferenceRequest {
            generation,
            snapshot,
        });
        available.notify_one();
        Ok(generation)
    }

    fn shutdown_with(&mut self, snapshot: T, stopped: &'static str) -> io::Result<u64> {
        if self.is_finished() {
            return Err(io::Error::other(stopped));
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
            snapshot,
        });
        state.shutdown = true;
        available.notify_one();
        Ok(generation)
    }

    fn drain_events(&self) -> Vec<PreferenceWriteEvent> {
        self.events.try_iter().collect()
    }

    fn is_finished(&self) -> bool {
        self.handle.as_ref().is_none_or(JoinHandle::is_finished)
    }

    fn join(&mut self) -> thread::Result<()> {
        self.request_shutdown();
        self.handle.take().map_or(Ok(()), JoinHandle::join)
    }
}

impl<T> CoalescingWriter<T> {
    fn request_shutdown(&mut self) {
        let (lock, available) = self.queue.as_ref();
        let mut state = lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.shutdown = true;
        available.notify_one();
    }
}

impl<T> Drop for CoalescingWriter<T> {
    fn drop(&mut self) {
        self.request_shutdown();
        if let Some(handle) = self.handle.take() {
            let _joined = handle.join();
        }
    }
}

/// Single durable writer that coalesces pending column snapshots.
pub(crate) struct PreferencesWriter {
    writer: CoalescingWriter<[ColumnState; COLUMN_COUNT]>,
}

impl PreferencesWriter {
    #[cfg(all(test, windows))]
    pub(crate) fn spawn_with_for_test(
        path: PathBuf,
        save: impl Fn(&Path, &[ColumnState; COLUMN_COUNT]) -> io::Result<()> + Send + Sync + 'static,
    ) -> io::Result<Self> {
        Self::spawn_with(path, || {}, Arc::new(save))
    }

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
        Ok(Self {
            writer: CoalescingWriter::spawn(
                path,
                "darkrenamer-preferences",
                wake,
                move |path, columns| save_preferences(path, &columns),
            )?,
        })
    }

    pub(crate) fn submit(&mut self, columns: [ColumnState; COLUMN_COUNT]) -> io::Result<u64> {
        self.writer.submit(
            columns,
            "column preference writer has stopped",
            "column preference writer is shutting down",
        )
    }

    pub(crate) fn shutdown_with(
        &mut self,
        columns: [ColumnState; COLUMN_COUNT],
    ) -> io::Result<u64> {
        self.writer
            .shutdown_with(columns, "column preference writer has stopped")
    }

    pub(crate) fn drain_events(&self) -> Vec<PreferenceWriteEvent> {
        self.writer.drain_events()
    }

    pub(crate) fn is_finished(&self) -> bool {
        self.writer.is_finished()
    }

    pub(crate) fn join(&mut self) -> thread::Result<()> {
        self.writer.join()
    }
}

type SaveAppearance = dyn Fn(&Path, UiAppearance) -> io::Result<()> + Send + Sync + 'static;

/// Independent durable writer for coalesced appearance snapshots.
pub(crate) struct AppearancePreferencesWriter {
    writer: CoalescingWriter<UiAppearance>,
}

impl AppearancePreferencesWriter {
    pub(crate) fn spawn(
        path: PathBuf,
        wake: impl Fn() + Send + Sync + 'static,
    ) -> io::Result<Self> {
        Self::spawn_with(path, wake, Arc::new(save_appearance))
    }

    fn spawn_with(
        path: PathBuf,
        wake: impl Fn() + Send + Sync + 'static,
        save_preferences: Arc<SaveAppearance>,
    ) -> io::Result<Self> {
        Ok(Self {
            writer: CoalescingWriter::spawn(
                path,
                "darkrenamer-appearance",
                wake,
                move |path, appearance| save_preferences(path, appearance),
            )?,
        })
    }

    pub(crate) fn submit(&mut self, appearance: UiAppearance) -> io::Result<u64> {
        self.writer.submit(
            appearance,
            "appearance preference writer has stopped",
            "appearance preference writer is shutting down",
        )
    }

    pub(crate) fn shutdown_with(&mut self, appearance: UiAppearance) -> io::Result<u64> {
        self.writer
            .shutdown_with(appearance, "appearance preference writer has stopped")
    }

    pub(crate) fn drain_events(&self) -> Vec<PreferenceWriteEvent> {
        self.writer.drain_events()
    }

    pub(crate) fn is_finished(&self) -> bool {
        self.writer.is_finished()
    }

    pub(crate) fn join(&mut self) -> thread::Result<()> {
        self.writer.join()
    }
}

pub(crate) fn path_for_journal_root(journal_root: &Path) -> PathBuf {
    journal_root
        .parent()
        .unwrap_or(journal_root)
        .join(SETTINGS_LEAF)
}

pub(crate) fn appearance_path_for_journal_root(journal_root: &Path) -> PathBuf {
    journal_root
        .parent()
        .unwrap_or(journal_root)
        .join(APPEARANCE_SETTINGS_LEAF)
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

pub(crate) fn load_appearance_or_default(path: &Path) -> AppearancePreferencesLoad {
    match read_appearance(path) {
        Ok(Some(appearance)) => AppearancePreferencesLoad {
            appearance,
            failure: None,
        },
        Ok(None) => AppearancePreferencesLoad {
            appearance: UiAppearance::default(),
            failure: None,
        },
        Err(error) => AppearancePreferencesLoad {
            appearance: UiAppearance::default(),
            failure: Some(error),
        },
    }
}

pub(crate) fn save_appearance(path: &Path, appearance: UiAppearance) -> io::Result<()> {
    let bytes = encode_appearance(appearance);
    persist_encoded(
        path,
        &bytes,
        APPEARANCE_SETTINGS_LEAF,
        "appearance preference path has no parent",
        "could not allocate a unique appearance preference temporary file",
    )
}

fn encode_appearance(appearance: UiAppearance) -> [u8; APPEARANCE_SERIALIZED_LEN] {
    let mut output = [0_u8; APPEARANCE_SERIALIZED_LEN];
    output[..APPEARANCE_MAGIC.len()].copy_from_slice(&APPEARANCE_MAGIC);
    output[8] = APPEARANCE_FORMAT_VERSION;
    output[9] = APPEARANCE_PAYLOAD_LEN as u8;
    let offset = APPEARANCE_HEADER_LEN;
    output[offset] = match appearance.theme {
        AppThemeMode::System => 0,
        AppThemeMode::Light => 1,
        AppThemeMode::Dark => 2,
    };
    output[offset + 1] = match appearance.density {
        RailDensityPreference::Automatic => 0,
        RailDensityPreference::Comfortable => 1,
        RailDensityPreference::Compact => 2,
        RailDensityPreference::MenuOnly => 3,
    };
    output[offset + 2] = match appearance.emphasis {
        PreviewEmphasis::Subtle => 0,
        PreviewEmphasis::Standard => 1,
        PreviewEmphasis::Strong => 2,
    };
    output[offset + 3] = u8::from(appearance.show_separators);
    output[offset + 4] = u8::from(appearance.show_preview_tint);
    output[offset + 5] = u8::from(appearance.show_empty_safety);
    let checksum_offset = APPEARANCE_SERIALIZED_LEN - APPEARANCE_CHECKSUM_LEN;
    let checksum = checksum(&output[..checksum_offset]);
    output[checksum_offset..].copy_from_slice(&checksum.to_le_bytes());
    output
}

fn decode_appearance(input: &[u8]) -> io::Result<UiAppearance> {
    if input.len() != APPEARANCE_SERIALIZED_LEN {
        return Err(invalid_data("appearance preference length is invalid"));
    }
    if input[..APPEARANCE_MAGIC.len()] != APPEARANCE_MAGIC
        || input[8] != APPEARANCE_FORMAT_VERSION
        || usize::from(input[9]) != APPEARANCE_PAYLOAD_LEN
        || input[10..APPEARANCE_HEADER_LEN] != [0, 0]
    {
        return Err(invalid_data("appearance preference header is invalid"));
    }
    let checksum_offset = APPEARANCE_SERIALIZED_LEN - APPEARANCE_CHECKSUM_LEN;
    let stored = u32::from_le_bytes(
        input[checksum_offset..]
            .try_into()
            .map_err(|_| invalid_data("appearance preference checksum is missing"))?,
    );
    if checksum(&input[..checksum_offset]) != stored {
        return Err(invalid_data(
            "appearance preference checksum does not match",
        ));
    }
    let offset = APPEARANCE_HEADER_LEN;
    if input[offset + 6..offset + APPEARANCE_PAYLOAD_LEN] != [0, 0] {
        return Err(invalid_data(
            "appearance preference reserved bytes are invalid",
        ));
    }
    let theme = match input[offset] {
        0 => AppThemeMode::System,
        1 => AppThemeMode::Light,
        2 => AppThemeMode::Dark,
        _ => return Err(invalid_data("appearance theme is invalid")),
    };
    let density = match input[offset + 1] {
        0 => RailDensityPreference::Automatic,
        1 => RailDensityPreference::Comfortable,
        2 => RailDensityPreference::Compact,
        3 => RailDensityPreference::MenuOnly,
        _ => return Err(invalid_data("appearance rail density is invalid")),
    };
    let emphasis = match input[offset + 2] {
        0 => PreviewEmphasis::Subtle,
        1 => PreviewEmphasis::Standard,
        2 => PreviewEmphasis::Strong,
        _ => return Err(invalid_data("appearance preview emphasis is invalid")),
    };
    Ok(UiAppearance {
        theme,
        density,
        emphasis,
        show_separators: decode_flag(input[offset + 3])?,
        show_preview_tint: decode_flag(input[offset + 4])?,
        show_empty_safety: decode_flag(input[offset + 5])?,
    })
}

fn read_appearance(path: &Path) -> io::Result<Option<UiAppearance>> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if !file.metadata()?.is_file() {
        return Err(invalid_data("appearance preference is not a regular file"));
    }
    let mut bytes = Vec::with_capacity(APPEARANCE_SERIALIZED_LEN);
    Read::by_ref(&mut file)
        .take((APPEARANCE_MAX_INPUT_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > APPEARANCE_MAX_INPUT_BYTES {
        return Err(invalid_data("appearance preference exceeds the size limit"));
    }
    decode_appearance(&bytes).map(Some)
}

pub(crate) fn save(path: &Path, columns: &[ColumnState; 7]) -> io::Result<()> {
    let bytes = encode(columns)?;
    persist_encoded(
        path,
        &bytes,
        SETTINGS_LEAF,
        "column preference path has no parent",
        "could not allocate a unique column preference temporary file",
    )
}

fn persist_encoded(
    path: &Path,
    bytes: &[u8],
    leaf: &str,
    parent_error: &'static str,
    temp_error: &'static str,
) -> io::Result<()> {
    persist_encoded_with(
        path,
        bytes,
        leaf,
        parent_error,
        temp_error,
        |temporary, bytes| temporary.write_all(bytes),
        atomic_replace,
    )
}

fn persist_encoded_with(
    path: &Path,
    bytes: &[u8],
    leaf: &str,
    parent_error: &'static str,
    temp_error: &'static str,
    write: impl FnOnce(&mut File, &[u8]) -> io::Result<()>,
    replace: impl FnOnce(&Path, &Path) -> io::Result<()>,
) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, parent_error))?;
    fs::create_dir_all(parent)?;
    let (temporary_path, mut temporary) = create_process_temp(parent, leaf, temp_error)?;
    let mut cleanup = OwnedTemp::new(temporary_path.clone());
    // Close the handle before owned cleanup on either success or failure.
    let write_result = (|| {
        write(&mut temporary, bytes)?;
        temporary.flush()?;
        temporary.sync_all()
    })();
    drop(temporary);
    write_result?;
    replace(&temporary_path, path)?;
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

fn create_process_temp(
    parent: &Path,
    leaf: &str,
    failure: &'static str,
) -> io::Result<(PathBuf, File)> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    for _ in 0..16 {
        let id = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
        let path = parent.join(format!(
            ".{leaf}.{}.{}.{}.tmp",
            std::process::id(),
            timestamp,
            id
        ));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, failure))
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
    crate::windows::atomic_replace_preferences(source, destination)
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

    #[test]
    fn terminal_event_allows_join_when_wake_arrives_before_thread_exit()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("ui-columns-v1");
        let wake_count = Arc::new(AtomicUsize::new(0));
        let worker_wake_count = Arc::clone(&wake_count);
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let worker_gate = Arc::clone(&gate);
        let (terminal_sender, terminal_receiver) = mpsc::channel();
        let mut writer = PreferencesWriter::spawn(path, move || {
            if worker_wake_count.fetch_add(1, Ordering::AcqRel) == 1 {
                let _sent = terminal_sender.send(());
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
        })?;

        writer.shutdown_with(customized_columns())?;
        terminal_receiver.recv()?;
        assert!(!writer.is_finished());
        assert!(matches!(
            writer.drain_events().as_slice(),
            [
                PreferenceWriteEvent::Saved { generation: 1 },
                PreferenceWriteEvent::Stopped
            ]
        ));
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
        Ok(())
    }

    fn customized_appearance() -> UiAppearance {
        UiAppearance {
            theme: AppThemeMode::Dark,
            density: RailDensityPreference::Compact,
            emphasis: PreviewEmphasis::Strong,
            show_separators: false,
            show_preview_tint: true,
            show_empty_safety: false,
        }
    }

    #[test]
    fn both_formats_keep_independent_golden_bytes() -> io::Result<()> {
        let directory = tempfile::tempdir()?;
        let columns_path = directory.path().join(SETTINGS_LEAF);
        let appearance_path = directory.path().join(APPEARANCE_SETTINGS_LEAF);
        save(&columns_path, &default_column_states())?;
        save_appearance(&appearance_path, customized_appearance())?;
        assert_eq!(
            fs::read(columns_path)?,
            [
                68, 82, 67, 79, 76, 83, 0, 0, 1, 7, 0, 0, 1, 0, 150, 0, 0, 0, 1, 0, 150, 0, 0, 0,
                1, 0, 100, 0, 0, 0, 0, 0, 120, 0, 0, 0, 0, 0, 80, 0, 0, 0, 0, 0, 120, 0, 0, 0, 0,
                0, 120, 0, 0, 0, 17, 12, 82, 102,
            ]
        );
        assert_eq!(
            fs::read(appearance_path)?,
            [
                68, 82, 65, 80, 80, 82, 0, 0, 1, 8, 0, 0, 2, 2, 2, 0, 1, 0, 0, 0, 254, 181, 216,
                140,
            ]
        );
        Ok(())
    }

    #[test]
    fn shared_persistence_cleans_only_its_temporary_after_write_or_replace_failure()
    -> io::Result<()> {
        for (leaf, bytes) in [
            (SETTINGS_LEAF, encode(&default_column_states())?.to_vec()),
            (
                APPEARANCE_SETTINGS_LEAF,
                encode_appearance(customized_appearance()).to_vec(),
            ),
        ] {
            let directory = tempfile::tempdir()?;
            let path = directory.path().join(leaf);
            fs::write(&path, b"previous file")?;
            let unrelated = directory.path().join("unrelated.tmp");
            fs::write(&unrelated, b"keep")?;
            let write_error = persist_encoded_with(
                &path,
                &bytes,
                leaf,
                "no parent",
                "no temp",
                |temporary, bytes| {
                    temporary.write_all(&bytes[..1])?;
                    Err(io::Error::other("injected write failure"))
                },
                atomic_replace,
            )
            .err()
            .ok_or_else(|| io::Error::other("injected write unexpectedly succeeded"))?;
            assert_eq!(write_error.to_string(), "injected write failure");
            assert_eq!(fs::read(&path)?, b"previous file");
            assert_eq!(fs::read(&unrelated)?, b"keep");
            assert_eq!(fs::read_dir(directory.path())?.count(), 2);

            let replace_error = persist_encoded_with(
                &path,
                &bytes,
                leaf,
                "no parent",
                "no temp",
                |temporary, bytes| temporary.write_all(bytes),
                |temporary, destination| {
                    assert!(temporary.exists());
                    assert_eq!(destination, path);
                    Err(io::Error::other("injected replace failure"))
                },
            )
            .err()
            .ok_or_else(|| io::Error::other("injected replace unexpectedly succeeded"))?;
            assert_eq!(replace_error.to_string(), "injected replace failure");
            assert_eq!(fs::read(&path)?, b"previous file");
            assert_eq!(fs::read(&unrelated)?, b"keep");
            assert_eq!(fs::read_dir(directory.path())?.count(), 2);
        }
        Ok(())
    }

    #[test]
    fn blocked_columns_do_not_delay_appearance_failure_recovery_or_final_flush()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let (started, first_started) = mpsc::channel();
        let (release, released) = mpsc::sync_channel(1);
        let released = Mutex::new(released);
        let column_saves = Arc::new(Mutex::new(Vec::new()));
        let observed_columns = Arc::clone(&column_saves);
        let column_save = Arc::new(move |_path: &Path, columns: &[ColumnState; 7]| {
            let mut saves = observed_columns
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let first = saves.is_empty();
            saves.push(*columns);
            drop(saves);
            if first {
                let _sent = started.send(());
                released
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .recv_timeout(std::time::Duration::from_secs(5))
                    .map_err(io::Error::other)?;
            }
            Ok(())
        });
        let mut columns = PreferencesWriter::spawn_with(
            directory.path().join(SETTINGS_LEAF),
            || {},
            column_save,
        )?;
        let (wake, woke) = mpsc::channel();
        let (release_wake, released_wake) = mpsc::sync_channel(1);
        let released_wake = Mutex::new(released_wake);
        let wake_count = AtomicUsize::new(0);
        let appearance_calls = Arc::new(AtomicUsize::new(0));
        let calls = Arc::clone(&appearance_calls);
        let appearance_saves = Arc::new(Mutex::new(Vec::new()));
        let observed_appearance = Arc::clone(&appearance_saves);
        let appearance_save = Arc::new(move |_path: &Path, appearance: UiAppearance| {
            observed_appearance
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(appearance);
            if calls.fetch_add(1, Ordering::AcqRel) == 0 {
                Err(io::Error::other("appearance first save failed"))
            } else {
                Ok(())
            }
        });
        let mut appearance = AppearancePreferencesWriter::spawn_with(
            directory.path().join(APPEARANCE_SETTINGS_LEAF),
            move || {
                if wake_count.fetch_add(1, Ordering::AcqRel) == 0 {
                    let _sent = wake.send(());
                    let _released = released_wake
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .recv_timeout(std::time::Duration::from_secs(5));
                }
            },
            appearance_save,
        )?;
        let first_columns = default_column_states();
        let mut pending_columns = first_columns;
        pending_columns[3].set_visible(true);
        let mut final_columns = pending_columns;
        final_columns[5].set_visible(true);
        let first_appearance = UiAppearance::default();
        let final_appearance = customized_appearance();
        assert_eq!(columns.submit(first_columns)?, 1);
        first_started.recv_timeout(std::time::Duration::from_secs(5))?;
        assert_eq!(appearance.submit(first_appearance)?, 1);
        woke.recv_timeout(std::time::Duration::from_secs(5))?;
        assert!(matches!(
            appearance.drain_events().as_slice(),
            [PreferenceWriteEvent::Failed { generation: 1, .. }]
        ));
        assert_eq!(columns.submit(pending_columns)?, 2);
        assert_eq!(
            appearance.submit(UiAppearance {
                theme: AppThemeMode::Light,
                ..first_appearance
            })?,
            2
        );
        assert_eq!(appearance.shutdown_with(final_appearance)?, 3);
        assert!(appearance.submit(first_appearance).is_err());
        release_wake.send(())?;
        appearance
            .join()
            .map_err(|_| io::Error::other("appearance worker panicked"))?;
        assert_eq!(
            appearance.drain_events(),
            vec![
                PreferenceWriteEvent::Saved { generation: 3 },
                PreferenceWriteEvent::Stopped
            ]
        );
        assert_eq!(
            *appearance_saves
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            vec![first_appearance, final_appearance]
        );
        assert!(!columns.is_finished());
        assert_eq!(columns.shutdown_with(final_columns)?, 3);
        assert!(columns.submit(first_columns).is_err());
        release.send(())?;
        columns
            .join()
            .map_err(|_| io::Error::other("column worker panicked"))?;
        assert_eq!(
            columns.drain_events(),
            vec![
                PreferenceWriteEvent::Saved { generation: 1 },
                PreferenceWriteEvent::Saved { generation: 3 },
                PreferenceWriteEvent::Stopped
            ]
        );
        assert_eq!(
            *column_saves
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            vec![first_columns, final_columns]
        );
        Ok(())
    }

    #[test]
    fn both_wrappers_report_unwinding_worker_failure() -> io::Result<()> {
        let directory = tempfile::tempdir()?;
        let mut columns = PreferencesWriter::spawn_with(
            directory.path().join(SETTINGS_LEAF),
            || {},
            Arc::new(|_, _| std::panic::resume_unwind(Box::new("column save panic"))),
        )?;
        let mut appearance = AppearancePreferencesWriter::spawn_with(
            directory.path().join(APPEARANCE_SETTINGS_LEAF),
            || {},
            Arc::new(|_, _| std::panic::resume_unwind(Box::new("appearance save panic"))),
        )?;
        columns.submit(default_column_states())?;
        appearance.submit(UiAppearance::default())?;
        assert!(columns.join().is_ok());
        assert!(appearance.join().is_ok());
        assert_eq!(columns.drain_events(), vec![PreferenceWriteEvent::Panicked]);
        assert_eq!(
            appearance.drain_events(),
            vec![PreferenceWriteEvent::Panicked]
        );
        assert!(columns.submit(default_column_states()).is_err());
        assert!(appearance.submit(UiAppearance::default()).is_err());
        Ok(())
    }

    fn refresh_appearance_checksum(bytes: &mut [u8]) {
        let checksum_offset = APPEARANCE_SERIALIZED_LEN - APPEARANCE_CHECKSUM_LEN;
        let updated = checksum(&bytes[..checksum_offset]);
        bytes[checksum_offset..].copy_from_slice(&updated.to_le_bytes());
    }

    #[test]
    fn appearance_codec_round_trip_is_exact_and_rejects_future_values() -> io::Result<()> {
        let appearance = customized_appearance();
        let encoded = encode_appearance(appearance);
        assert_eq!(decode_appearance(&encoded)?, appearance);

        let menu_only = UiAppearance {
            density: RailDensityPreference::MenuOnly,
            ..appearance
        };
        assert_eq!(decode_appearance(&encode_appearance(menu_only))?, menu_only);

        for (offset, value) in [
            (8, 2),
            (9, 9),
            (10, 1),
            (APPEARANCE_HEADER_LEN, 3),
            (APPEARANCE_HEADER_LEN + 1, 4),
            (APPEARANCE_HEADER_LEN + 2, 3),
            (APPEARANCE_HEADER_LEN + 3, 2),
            (APPEARANCE_HEADER_LEN + 6, 1),
        ] {
            let mut future = encoded;
            future[offset] = value;
            refresh_appearance_checksum(&mut future);
            assert!(matches!(
                decode_appearance(&future),
                Err(error) if error.kind() == io::ErrorKind::InvalidData
            ));
        }

        let mut corrupt = encoded;
        corrupt[APPEARANCE_HEADER_LEN] ^= 1;
        assert!(matches!(
            decode_appearance(&corrupt),
            Err(error) if error.kind() == io::ErrorKind::InvalidData
        ));
        let mut trailing = encoded.to_vec();
        trailing.push(0);
        assert!(matches!(
            decode_appearance(&trailing),
            Err(error) if error.kind() == io::ErrorKind::InvalidData
        ));
        Ok(())
    }

    #[test]
    fn appearance_and_column_files_fail_independently() -> io::Result<()> {
        let directory = tempfile::tempdir()?;
        let journal_root = directory.path().join("DarkReNamer").join("journal");
        let column_path = path_for_journal_root(&journal_root);
        let appearance_path = appearance_path_for_journal_root(&journal_root);
        let columns = customized_columns();
        let appearance = customized_appearance();

        save(&column_path, &columns)?;
        fs::write(&appearance_path, b"corrupt appearance")?;
        assert_eq!(
            load_or_default(&column_path, default_column_states()).columns,
            columns
        );
        let failed_appearance = load_appearance_or_default(&appearance_path);
        assert_eq!(failed_appearance.appearance, UiAppearance::default());
        assert!(failed_appearance.failure.is_some());

        save_appearance(&appearance_path, appearance)?;
        fs::write(&column_path, b"corrupt columns")?;
        let failed_columns = load_or_default(&column_path, default_column_states());
        assert_eq!(failed_columns.columns, default_column_states());
        assert!(failed_columns.failure.is_some());
        let loaded_appearance = load_appearance_or_default(&appearance_path);
        assert_eq!(loaded_appearance.appearance, appearance);
        assert!(loaded_appearance.failure.is_none());

        fs::write(&appearance_path, vec![0_u8; APPEARANCE_MAX_INPUT_BYTES + 1])?;
        let oversized = load_appearance_or_default(&appearance_path);
        assert_eq!(oversized.appearance, UiAppearance::default());
        assert!(oversized.failure.is_some());
        Ok(())
    }

    #[test]
    fn appearance_writer_coalesces_and_flushes_the_final_snapshot()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("ui-appearance-v1");
        let writes = Arc::new(Mutex::new(Vec::new()));
        let worker_writes = Arc::clone(&writes);
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let worker_gate = Arc::clone(&gate);
        let calls = Arc::new(AtomicUsize::new(0));
        let worker_calls = Arc::clone(&calls);
        let (started_sender, started_receiver) = mpsc::channel();
        let save_preferences = Arc::new(move |_path: &Path, appearance: UiAppearance| {
            worker_writes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(appearance);
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
        let mut writer = AppearancePreferencesWriter::spawn_with(path, || {}, save_preferences)?;
        let first = UiAppearance::default();
        let second = UiAppearance {
            density: RailDensityPreference::Comfortable,
            ..first
        };
        let final_appearance = customized_appearance();

        writer.submit(first)?;
        started_receiver.recv()?;
        writer.submit(second)?;
        writer.shutdown_with(final_appearance)?;
        {
            let (lock, available) = gate.as_ref();
            *lock
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = true;
            available.notify_one();
        }
        writer
            .join()
            .map_err(|_| io::Error::other("appearance preference writer panicked"))?;
        assert_eq!(
            *writes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            vec![first, final_appearance]
        );
        assert_eq!(
            writer.drain_events(),
            vec![
                PreferenceWriteEvent::Saved { generation: 1 },
                PreferenceWriteEvent::Saved { generation: 3 },
                PreferenceWriteEvent::Stopped,
            ]
        );
        Ok(())
    }

    #[test]
    fn production_appearance_writer_flushes_before_join() -> io::Result<()> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("ui-appearance-v1");
        let appearance = customized_appearance();
        let mut writer = AppearancePreferencesWriter::spawn(path.clone(), || {})?;
        writer.shutdown_with(appearance)?;
        writer
            .join()
            .map_err(|_| io::Error::other("appearance preference writer panicked"))?;
        assert_eq!(load_appearance_or_default(&path).appearance, appearance);
        Ok(())
    }

    #[test]
    fn appearance_writer_reports_failure_then_persists_final_retry()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("ui-appearance-v1");
        let calls = Arc::new(AtomicUsize::new(0));
        let worker_calls = Arc::clone(&calls);
        let (wake_sender, wake_receiver) = mpsc::channel();
        let save_preferences = Arc::new(move |_path: &Path, _appearance: UiAppearance| {
            if worker_calls.fetch_add(1, Ordering::AcqRel) == 0 {
                Err(io::Error::other("injected appearance write failure"))
            } else {
                Ok(())
            }
        });
        let mut writer = AppearancePreferencesWriter::spawn_with(
            path,
            move || {
                let _sent = wake_sender.send(());
            },
            save_preferences,
        )?;
        writer.submit(UiAppearance::default())?;
        wake_receiver.recv()?;
        assert!(matches!(
            writer.drain_events().as_slice(),
            [PreferenceWriteEvent::Failed { generation: 1, .. }]
        ));
        writer.shutdown_with(customized_appearance())?;
        writer
            .join()
            .map_err(|_| io::Error::other("appearance preference writer panicked"))?;
        assert_eq!(
            writer.drain_events(),
            vec![
                PreferenceWriteEvent::Saved { generation: 2 },
                PreferenceWriteEvent::Stopped,
            ]
        );
        Ok(())
    }
}
