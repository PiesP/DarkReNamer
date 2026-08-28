use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use crate::filesystem::{EntryKind, FileIdentity, Fingerprint};
use crate::{
    Generation, PlatformError, SourceId, TransactionId, TransactionKind, io_error,
    validate_persisted_path,
};

const MAGIC: &[u8; 8] = b"DRJNL002";
const MAX_FRAME_SIZE: usize = 1_048_576;
const MAX_JOURNAL_SIZE: u64 = 16 * 1_048_576;

#[derive(Clone, Debug)]
pub(crate) struct JournalItem {
    pub(crate) source_id: SourceId,
    pub(crate) original: PathBuf,
    pub(crate) final_path: PathBuf,
    pub(crate) fingerprint: Fingerprint,
    pub(crate) parent_fingerprint: Fingerprint,
}

#[derive(Clone, Debug)]
pub(crate) struct JournalHeader {
    pub(crate) transaction_id: TransactionId,
    pub(crate) kind: TransactionKind,
    pub(crate) generation: Generation,
    pub(crate) items: Box<[JournalItem]>,
}

#[derive(Clone, Debug)]
pub(crate) struct CompletedTransaction {
    pub(crate) header: JournalHeader,
}

#[derive(Debug)]
pub(crate) struct JournalScan {
    pub(crate) recovery_required: bool,
    pub(crate) latest: Option<CompletedTransaction>,
    pub(crate) maximum_transaction_id: u64,
    pub(crate) incomplete: Option<IncompleteTransaction>,
    pub(crate) corrupt: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub(crate) struct PendingMove {
    pub(crate) ordinal: u32,
    pub(crate) from: PathBuf,
    pub(crate) to: PathBuf,
    pub(crate) identity: FileIdentity,
}

#[derive(Clone, Debug)]
pub(crate) struct IncompleteTransaction {
    pub(crate) path: PathBuf,
    pub(crate) header: JournalHeader,
    pub(crate) pending: Option<PendingMove>,
    pub(crate) known_paths: Box<[PathBuf]>,
    pub(crate) completed_move_count: usize,
    pub(crate) next_ordinal: u32,
    pub(crate) state_checksum: u64,
    pub(crate) valid_length: u64,
    pub(crate) file_length: u64,
    pub(crate) journal_identity: JournalFileIdentity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct JournalFileIdentity {
    pub(crate) volume: u64,
    pub(crate) file: u64,
}

#[derive(Debug)]
pub(crate) struct JournalStore {
    root: PathBuf,
}

#[derive(Debug)]
pub(crate) struct PreparedJournalHeader {
    header: JournalHeader,
    payload: Vec<u8>,
}

#[derive(Debug)]
pub(crate) struct JournalCreateError {
    pub(crate) error: PlatformError,
    pub(crate) may_have_partial_journal: bool,
}

impl JournalStore {
    pub(crate) fn open(root: &Path) -> Result<(Self, JournalScan), PlatformError> {
        fs::create_dir_all(root).map_err(|error| io_error("create journal root", error))?;
        let metadata =
            fs::symlink_metadata(root).map_err(|error| io_error("inspect journal root", error))?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(PlatformError::Unsupported {
                operation: "journal root must be a real directory",
            });
        }
        let store = Self {
            root: root.to_path_buf(),
        };
        let scan = store.scan()?;
        Ok((store, scan))
    }

    pub(crate) fn prepare(
        &self,
        header: &JournalHeader,
    ) -> Result<PreparedJournalHeader, PlatformError> {
        // Validate and bound the complete authority-bearing header before
        // creating a filename that startup would interpret as a transaction.
        if !validate_header_authority(header) {
            return Err(PlatformError::Unsupported {
                operation: "journal header path authority",
            });
        }
        let header_payload = encode_event(&Event::Header(header.clone()))?;
        validate_frame_size(&header_payload)?;
        Ok(PreparedJournalHeader {
            header: header.clone(),
            payload: header_payload,
        })
    }

    pub(crate) fn create(
        &self,
        prepared: &PreparedJournalHeader,
    ) -> Result<TransactionJournal, JournalCreateError> {
        let path = self
            .root
            .join(format!("{:016x}.drj", prepared.header.transaction_id.0));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .map_err(|error| JournalCreateError {
                error: io_error("create transaction journal", error),
                may_have_partial_journal: false,
            })?;
        file.write_all(MAGIC).map_err(|error| JournalCreateError {
            error: io_error("write journal magic", error),
            may_have_partial_journal: true,
        })?;
        file.sync_data().map_err(|error| JournalCreateError {
            error: io_error("sync journal magic", error),
            may_have_partial_journal: true,
        })?;
        sync_directory(&self.root).map_err(|error| JournalCreateError {
            error,
            may_have_partial_journal: true,
        })?;
        let mut journal = TransactionJournal { file };
        journal
            .append_payload(&prepared.payload)
            .map_err(|error| JournalCreateError {
                error,
                may_have_partial_journal: true,
            })?;
        Ok(journal)
    }

    pub(crate) fn scan(&self) -> Result<JournalScan, PlatformError> {
        let entries =
            fs::read_dir(&self.root).map_err(|error| io_error("scan journal root", error))?;
        let mut paths = Vec::new();
        for entry in entries {
            let path = entry
                .map_err(|error| io_error("read journal root entry", error))?
                .path();
            if path.extension().is_some_and(|extension| extension == "drj") {
                paths.push(path);
            }
        }
        paths.sort();

        let mut recovery_required = false;
        let mut latest: Option<CompletedTransaction> = None;
        let mut maximum_transaction_id = 0;
        let mut transaction_ids = BTreeSet::new();
        let mut incomplete = None;
        let mut corrupt = None;
        for path in paths {
            let Ok(filename_id) = canonical_filename_id(&path) else {
                recovery_required = true;
                corrupt.get_or_insert(path);
                continue;
            };
            maximum_transaction_id = maximum_transaction_id.max(filename_id);
            if !transaction_ids.insert(filename_id) {
                recovery_required = true;
                corrupt.get_or_insert(path);
                continue;
            }
            match parse_journal(&path, filename_id) {
                Ok(ParseOutcome::Committed(transaction)) => {
                    let is_newer = latest.as_ref().is_none_or(|current| {
                        transaction.header.transaction_id.0 > current.header.transaction_id.0
                    });
                    if is_newer {
                        latest = Some(transaction);
                    }
                }
                Ok(ParseOutcome::Aborted) => {}
                Ok(ParseOutcome::Incomplete(transaction)) => {
                    recovery_required = true;
                    if incomplete.is_some() {
                        corrupt.get_or_insert(path);
                    } else {
                        incomplete = Some(transaction);
                    }
                }
                Err(()) => {
                    recovery_required = true;
                    corrupt.get_or_insert(path);
                }
            }
        }
        Ok(JournalScan {
            recovery_required,
            latest,
            maximum_transaction_id,
            incomplete,
            corrupt,
        })
    }

    pub(crate) fn resume(
        &self,
        transaction: &IncompleteTransaction,
    ) -> Result<TransactionJournal, PlatformError> {
        let mut file = open_journal_file(&transaction.path, true)
            .map_err(|()| PlatformError::StaleRecovery)?;
        let current = parse_journal_file(
            &transaction.path,
            transaction.header.transaction_id.0,
            &mut file,
        )
        .map_err(|()| PlatformError::StaleRecovery)?;
        let ParseOutcome::Incomplete(current) = current else {
            return Err(PlatformError::StaleRecovery);
        };
        if current.state_checksum != transaction.state_checksum
            || current.file_length != transaction.file_length
            || current.journal_identity != transaction.journal_identity
        {
            return Err(PlatformError::StaleRecovery);
        }
        if transaction.valid_length != transaction.file_length {
            file.set_len(transaction.valid_length)
                .and_then(|()| file.sync_data())
                .map_err(|error| io_error("truncate torn journal tail", error))?;
        }
        file.seek(SeekFrom::End(0))
            .map_err(|error| io_error("seek recovered journal tail", error))?;
        Ok(TransactionJournal { file })
    }
}

fn sync_directory(path: &Path) -> Result<(), PlatformError> {
    #[cfg(unix)]
    {
        File::open(path)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| io_error("sync journal directory", error))
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

#[derive(Debug)]
pub(crate) struct TransactionJournal {
    file: File,
}

impl TransactionJournal {
    pub(crate) fn intent(
        &mut self,
        ordinal: u32,
        from: &Path,
        to: &Path,
        identity: FileIdentity,
    ) -> Result<(), PlatformError> {
        validate_persisted_path(from)?;
        validate_persisted_path(to)?;
        self.append(&Event::MoveIntent {
            ordinal,
            from: from.to_path_buf(),
            to: to.to_path_buf(),
            identity,
        })
    }

    pub(crate) fn complete(&mut self, ordinal: u32) -> Result<(), PlatformError> {
        self.append(&Event::MoveComplete { ordinal })
    }

    pub(crate) fn failed(&mut self, ordinal: u32) -> Result<(), PlatformError> {
        self.append(&Event::MoveFailed { ordinal })
    }

    pub(crate) fn commit(&mut self) -> Result<(), PlatformError> {
        self.append(&Event::Commit)
    }

    pub(crate) fn abort(&mut self) -> Result<(), PlatformError> {
        self.append(&Event::Abort)
    }

    fn append(&mut self, event: &Event) -> Result<(), PlatformError> {
        let payload = encode_event(event)?;
        validate_frame_size(&payload)?;
        self.append_payload(&payload)
    }

    fn append_payload(&mut self, payload: &[u8]) -> Result<(), PlatformError> {
        let length =
            u32::try_from(payload.len()).map_err(|_error| PlatformError::BoundExceeded {
                field: "journal frame",
                maximum: MAX_FRAME_SIZE,
            })?;
        self.file
            .write_all(&length.to_le_bytes())
            .and_then(|()| self.file.write_all(&checksum(payload).to_le_bytes()))
            .and_then(|()| self.file.write_all(payload))
            .map_err(|error| io_error("append transaction journal", error))?;
        self.file
            .sync_data()
            .map_err(|error| io_error("sync transaction journal", error))
    }
}

fn validate_frame_size(payload: &[u8]) -> Result<(), PlatformError> {
    if payload.len() > MAX_FRAME_SIZE {
        return Err(PlatformError::BoundExceeded {
            field: "journal frame",
            maximum: MAX_FRAME_SIZE,
        });
    }
    Ok(())
}

#[derive(Clone, Debug)]
enum Event {
    Header(JournalHeader),
    MoveIntent {
        ordinal: u32,
        from: PathBuf,
        to: PathBuf,
        identity: FileIdentity,
    },
    MoveComplete {
        ordinal: u32,
    },
    MoveFailed {
        ordinal: u32,
    },
    Commit,
    Abort,
}

enum ParseOutcome {
    Committed(CompletedTransaction),
    Aborted,
    Incomplete(IncompleteTransaction),
}

fn canonical_filename_id(path: &Path) -> Result<u64, ()> {
    let value = path
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or(())?;
    if value.len() != 16
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(());
    }
    u64::from_str_radix(value, 16).map_err(|_error| ())
}

fn parse_journal(path: &Path, filename_id: u64) -> Result<ParseOutcome, ()> {
    let mut file = open_journal_file(path, false)?;
    parse_journal_file(path, filename_id, &mut file)
}

fn parse_journal_file(path: &Path, filename_id: u64, file: &mut File) -> Result<ParseOutcome, ()> {
    let metadata = file.metadata().map_err(|_error| ())?;
    if !metadata.is_file() {
        return Err(());
    }
    if metadata.len() > MAX_JOURNAL_SIZE {
        return Err(());
    }
    let mut bytes = Vec::with_capacity(usize::try_from(metadata.len()).map_err(|_error| ())?);
    file.seek(SeekFrom::Start(0)).map_err(|_error| ())?;
    file.read_to_end(&mut bytes).map_err(|_error| ())?;
    if bytes.len() < MAGIC.len() || &bytes[..MAGIC.len()] != MAGIC {
        return Err(());
    }

    let mut cursor = MAGIC.len();
    let mut events = Vec::new();
    let mut torn_tail = false;
    while cursor < bytes.len() {
        if bytes.len() - cursor < 12 {
            torn_tail = true;
            break;
        }
        let length =
            u32::from_le_bytes(bytes[cursor..cursor + 4].try_into().map_err(|_error| ())?) as usize;
        let expected_checksum = u64::from_le_bytes(
            bytes[cursor + 4..cursor + 12]
                .try_into()
                .map_err(|_error| ())?,
        );
        if length > MAX_FRAME_SIZE {
            return Err(());
        }
        cursor += 12;
        if bytes.len() - cursor < length {
            cursor -= 12;
            torn_tail = true;
            break;
        }
        let payload = &bytes[cursor..cursor + length];
        if checksum(payload) != expected_checksum {
            return Err(());
        }
        events.push(decode_event(payload)?);
        cursor += length;
    }
    match events.first() {
        Some(Event::Header(header)) if header.transaction_id.0 == filename_id => {}
        _ => return Err(()),
    }
    validate_events(
        events,
        path,
        checksum(&bytes),
        u64::try_from(cursor).map_err(|_error| ())?,
        metadata.len(),
        torn_tail,
        journal_file_identity(&metadata),
    )
}

#[cfg(unix)]
fn open_journal_file(path: &Path, writable: bool) -> Result<File, ()> {
    use rustix::fs::{Mode, OFlags, open};

    let access = if writable {
        OFlags::RDWR | OFlags::APPEND
    } else {
        OFlags::RDONLY
    };
    open(
        path,
        access | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map(File::from)
    .map_err(|_error| ())
}

#[cfg(not(unix))]
fn open_journal_file(path: &Path, writable: bool) -> Result<File, ()> {
    let mut options = OpenOptions::new();
    options.read(true).append(writable);
    options.open(path).map_err(|_error| ())
}

#[cfg(unix)]
fn journal_file_identity(metadata: &fs::Metadata) -> JournalFileIdentity {
    use std::os::unix::fs::MetadataExt;

    JournalFileIdentity {
        volume: metadata.dev(),
        file: metadata.ino(),
    }
}

#[cfg(not(unix))]
fn journal_file_identity(metadata: &fs::Metadata) -> JournalFileIdentity {
    use std::hash::{Hash, Hasher};

    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    metadata.len().hash(&mut hasher);
    metadata.modified().ok().hash(&mut hasher);
    JournalFileIdentity {
        volume: 0,
        file: hasher.finish(),
    }
}

fn validate_events(
    events: Vec<Event>,
    path: &Path,
    state_checksum: u64,
    valid_length: u64,
    file_length: u64,
    torn_tail: bool,
    journal_identity: JournalFileIdentity,
) -> Result<ParseOutcome, ()> {
    let mut events = events.into_iter();
    let Some(Event::Header(header)) = events.next() else {
        return Err(());
    };
    let mut pending: Option<PendingMove> = None;
    let mut terminal = None;
    let mut next_ordinal = 0_u32;
    let mut completed_move_count = 0_usize;
    let mut known_paths = BTreeSet::new();
    let mut locations: BTreeMap<FileIdentity, PathBuf> = header
        .items
        .iter()
        .map(|item| (item.fingerprint.identity, item.original.clone()))
        .collect();
    for event in events {
        if terminal.is_some() {
            return Err(());
        }
        match event {
            Event::MoveIntent {
                ordinal,
                from,
                to,
                identity,
            } if pending.is_none()
                && ordinal == next_ordinal
                && is_authorized_journal_move(&header, identity, &from, &to)
                && locations.get(&identity) == Some(&from)
                && !locations.values().any(|location| location == &to) =>
            {
                known_paths.insert(from.clone());
                known_paths.insert(to.clone());
                next_ordinal = next_ordinal.saturating_add(1);
                pending = Some(PendingMove {
                    ordinal,
                    from,
                    to,
                    identity,
                });
            }
            Event::MoveComplete { ordinal }
                if pending
                    .as_ref()
                    .is_some_and(|move_| move_.ordinal == ordinal) =>
            {
                if let Some(move_) = &pending {
                    locations.insert(move_.identity, move_.to.clone());
                }
                pending = None;
                completed_move_count = completed_move_count.saturating_add(1);
            }
            Event::MoveFailed { ordinal }
                if pending
                    .as_ref()
                    .is_some_and(|move_| move_.ordinal == ordinal) =>
            {
                pending = None;
            }
            Event::Commit if pending.is_none() => terminal = Some(true),
            Event::Abort if pending.is_none() => terminal = Some(false),
            Event::Header(_)
            | Event::MoveIntent { .. }
            | Event::MoveComplete { .. }
            | Event::MoveFailed { .. }
            | Event::Commit
            | Event::Abort => return Err(()),
        }
    }
    if torn_tail && terminal.is_some() {
        return Err(());
    }
    match terminal {
        Some(true)
            if header.items.iter().all(|item| {
                locations.get(&item.fingerprint.identity) == Some(&item.final_path)
            }) =>
        {
            Ok(ParseOutcome::Committed(CompletedTransaction { header }))
        }
        Some(false)
            if header
                .items
                .iter()
                .all(|item| locations.get(&item.fingerprint.identity) == Some(&item.original)) =>
        {
            Ok(ParseOutcome::Aborted)
        }
        Some(_) => Err(()),
        None => Ok(ParseOutcome::Incomplete(IncompleteTransaction {
            path: path.to_path_buf(),
            header,
            pending,
            known_paths: known_paths.into_iter().collect(),
            completed_move_count,
            next_ordinal,
            state_checksum,
            valid_length,
            file_length,
            journal_identity,
        })),
    }
}

fn checksum(bytes: &[u8]) -> u64 {
    let mut value = 0xcbf2_9ce4_8422_2325_u64;
    for byte in bytes {
        value ^= u64::from(*byte);
        value = value.wrapping_mul(0x0000_0100_0000_01b3);
    }
    value
}

fn validate_header_authority(header: &JournalHeader) -> bool {
    if header.items.is_empty() || header.items.len() > crate::MAX_SOURCES {
        return false;
    }
    let mut source_ids = BTreeSet::new();
    let mut identities = BTreeSet::new();
    let mut originals = BTreeSet::new();
    let mut finals = BTreeSet::new();
    header.items.iter().all(|item| {
        item.original.is_absolute()
            && item.final_path.is_absolute()
            && item.original.file_name().is_some()
            && item.final_path.file_name().is_some()
            && item.original.parent() == item.final_path.parent()
            && item.original != item.final_path
            && item.fingerprint.kind == EntryKind::RegularFile
            && item.parent_fingerprint.kind == EntryKind::Directory
            && source_ids.insert(item.source_id)
            && identities.insert(item.fingerprint.identity)
            && originals.insert(item.original.clone())
            && finals.insert(item.final_path.clone())
    })
}

fn is_authorized_journal_move(
    header: &JournalHeader,
    identity: FileIdentity,
    from: &Path,
    to: &Path,
) -> bool {
    header
        .items
        .iter()
        .enumerate()
        .find(|(_index, item)| item.fingerprint.identity == identity)
        .is_some_and(|(index, item)| {
            let Some(parent) = item.original.parent() else {
                return false;
            };
            let temporary = parent.join(format!(
                ".dark-renamer-{:016x}-{index:04x}.tmp",
                header.transaction_id.0
            ));
            let recovery_temporary = parent.join(format!(
                ".dark-renamer-recovery-{:016x}-{index:04x}.tmp",
                header.transaction_id.0
            ));
            let normal = (from == item.original && to == temporary)
                || (from == temporary && to == item.final_path)
                || (from == item.final_path && to == temporary)
                || (from == temporary && to == item.original);
            let into_recovery = to == recovery_temporary
                && from != recovery_temporary
                && (from == item.original || from == item.final_path || from == temporary);
            let out_of_recovery =
                from == recovery_temporary && (to == item.original || to == item.final_path);
            normal || into_recovery || out_of_recovery
        })
}

fn encode_event(event: &Event) -> Result<Vec<u8>, PlatformError> {
    let mut bytes = Vec::new();
    match event {
        Event::Header(header) => {
            bytes.push(1);
            put_u64(&mut bytes, header.transaction_id.0);
            bytes.push(match header.kind {
                TransactionKind::Apply => 1,
                TransactionKind::Undo => 2,
            });
            put_u64(&mut bytes, header.generation.0);
            put_u32(
                &mut bytes,
                u32::try_from(header.items.len()).map_err(|_error| {
                    PlatformError::BoundExceeded {
                        field: "journal item count",
                        maximum: crate::MAX_SOURCES,
                    }
                })?,
            );
            for item in &header.items {
                put_u64(&mut bytes, item.source_id.0);
                put_path(&mut bytes, &item.original)?;
                put_path(&mut bytes, &item.final_path)?;
                put_fingerprint(&mut bytes, item.fingerprint);
                put_fingerprint(&mut bytes, item.parent_fingerprint);
            }
        }
        Event::MoveIntent {
            ordinal,
            from,
            to,
            identity,
        } => {
            bytes.push(2);
            put_u32(&mut bytes, *ordinal);
            put_path(&mut bytes, from)?;
            put_path(&mut bytes, to)?;
            put_u64(&mut bytes, identity.volume);
            bytes.extend_from_slice(&identity.file);
        }
        Event::MoveComplete { ordinal } => {
            bytes.push(3);
            put_u32(&mut bytes, *ordinal);
        }
        Event::Commit => bytes.push(4),
        Event::Abort => bytes.push(5),
        Event::MoveFailed { ordinal } => {
            bytes.push(6);
            put_u32(&mut bytes, *ordinal);
        }
    }
    Ok(bytes)
}

fn decode_event(bytes: &[u8]) -> Result<Event, ()> {
    let mut reader = Reader::new(bytes);
    let tag = reader.u8()?;
    let event = match tag {
        1 => {
            let transaction_id = TransactionId(reader.u64()?);
            let kind = match reader.u8()? {
                1 => TransactionKind::Apply,
                2 => TransactionKind::Undo,
                _ => return Err(()),
            };
            let generation = Generation(reader.u64()?);
            let count = usize::try_from(reader.u32()?).map_err(|_error| ())?;
            if count > crate::MAX_SOURCES {
                return Err(());
            }
            let mut items = Vec::with_capacity(count);
            for _ in 0..count {
                items.push(JournalItem {
                    source_id: SourceId(reader.u64()?),
                    original: reader.path()?,
                    final_path: reader.path()?,
                    fingerprint: reader.fingerprint()?,
                    parent_fingerprint: reader.fingerprint()?,
                });
            }
            let header = JournalHeader {
                transaction_id,
                kind,
                generation,
                items: items.into(),
            };
            if !validate_header_authority(&header) {
                return Err(());
            }
            Event::Header(header)
        }
        2 => Event::MoveIntent {
            ordinal: reader.u32()?,
            from: reader.path()?,
            to: reader.path()?,
            identity: FileIdentity {
                volume: reader.u64()?,
                file: reader.file_id()?,
            },
        },
        3 => Event::MoveComplete {
            ordinal: reader.u32()?,
        },
        4 => Event::Commit,
        5 => Event::Abort,
        6 => Event::MoveFailed {
            ordinal: reader.u32()?,
        },
        _ => return Err(()),
    };
    if reader.remaining() != 0 {
        return Err(());
    }
    Ok(event)
}

fn put_u32(bytes: &mut Vec<u8>, value: u32) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn put_u64(bytes: &mut Vec<u8>, value: u64) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn put_u128(bytes: &mut Vec<u8>, value: u128) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn put_path(bytes: &mut Vec<u8>, path: &Path) -> Result<(), PlatformError> {
    validate_persisted_path(path)?;
    let value = path.to_str().ok_or(PlatformError::Unsupported {
        operation: "persist non-Unicode path",
    })?;
    put_u32(
        bytes,
        u32::try_from(value.len()).map_err(|_error| PlatformError::BoundExceeded {
            field: "path",
            maximum: 4_096,
        })?,
    );
    bytes.extend_from_slice(value.as_bytes());
    Ok(())
}

fn put_fingerprint(bytes: &mut Vec<u8>, fingerprint: Fingerprint) {
    put_u64(bytes, fingerprint.identity.volume);
    bytes.extend_from_slice(&fingerprint.identity.file);
    bytes.push(match fingerprint.kind {
        EntryKind::RegularFile => 1,
        EntryKind::Directory => 2,
        EntryKind::SymbolicLink => 3,
        EntryKind::Other => 4,
    });
    put_u64(bytes, fingerprint.length);
    put_u128(bytes, fingerprint.modified_nanos);
}

struct Reader<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> Reader<'a> {
    const fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, cursor: 0 }
    }

    const fn remaining(&self) -> usize {
        self.bytes.len() - self.cursor
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], ()> {
        let end = self.cursor.checked_add(length).ok_or(())?;
        let value = self.bytes.get(self.cursor..end).ok_or(())?;
        self.cursor = end;
        Ok(value)
    }

    fn u8(&mut self) -> Result<u8, ()> {
        self.take(1)?.first().copied().ok_or(())
    }

    fn u32(&mut self) -> Result<u32, ()> {
        Ok(u32::from_le_bytes(
            self.take(4)?.try_into().map_err(|_error| ())?,
        ))
    }

    fn u64(&mut self) -> Result<u64, ()> {
        Ok(u64::from_le_bytes(
            self.take(8)?.try_into().map_err(|_error| ())?,
        ))
    }

    fn u128(&mut self) -> Result<u128, ()> {
        Ok(u128::from_le_bytes(
            self.take(16)?.try_into().map_err(|_error| ())?,
        ))
    }

    fn file_id(&mut self) -> Result<[u8; 16], ()> {
        self.take(16)?.try_into().map_err(|_error| ())
    }

    fn path(&mut self) -> Result<PathBuf, ()> {
        let length = usize::try_from(self.u32()?).map_err(|_error| ())?;
        if length > 4_096 {
            return Err(());
        }
        let value = std::str::from_utf8(self.take(length)?).map_err(|_error| ())?;
        let path = PathBuf::from(value);
        if !path.is_absolute() {
            return Err(());
        }
        Ok(path)
    }

    fn fingerprint(&mut self) -> Result<Fingerprint, ()> {
        let identity = FileIdentity {
            volume: self.u64()?,
            file: self.file_id()?,
        };
        let kind = match self.u8()? {
            1 => EntryKind::RegularFile,
            2 => EntryKind::Directory,
            3 => EntryKind::SymbolicLink,
            4 => EntryKind::Other,
            _ => return Err(()),
        };
        Ok(Fingerprint {
            identity,
            kind,
            length: self.u64()?,
            modified_nanos: self.u128()?,
        })
    }
}

#[cfg(test)]
pub(crate) fn journal_has_pending_intent(path: &Path) -> bool {
    let Ok(mut file) = File::open(path) else {
        return false;
    };
    let mut bytes = Vec::new();
    if file.read_to_end(&mut bytes).is_err() || bytes.len() < MAGIC.len() {
        return false;
    }
    let mut cursor = MAGIC.len();
    let mut pending = false;
    while bytes.len().saturating_sub(cursor) >= 12 {
        let Ok(length_bytes) = bytes[cursor..cursor + 4].try_into() else {
            return false;
        };
        let length = u32::from_le_bytes(length_bytes) as usize;
        cursor += 12;
        let Some(payload) = bytes.get(cursor..cursor.saturating_add(length)) else {
            return false;
        };
        match decode_event(payload) {
            Ok(Event::MoveIntent { .. }) => pending = true,
            Ok(Event::MoveComplete { .. }) => pending = false,
            Ok(Event::MoveFailed { .. }) => pending = false,
            Ok(_) => {}
            Err(()) => return false,
        }
        cursor += length;
    }
    pending
}

#[cfg(test)]
pub(crate) fn write_unchecked_journal_fixture(
    path: &Path,
    header: &JournalHeader,
    moves: &[(u32, PathBuf, PathBuf, FileIdentity)],
) -> Result<(), PlatformError> {
    let mut payloads = vec![encode_header_unchecked(header)?];
    for (ordinal, from, to, identity) in moves {
        payloads.push(encode_event(&Event::MoveIntent {
            ordinal: *ordinal,
            from: from.clone(),
            to: to.clone(),
            identity: *identity,
        })?);
    }
    let mut bytes = MAGIC.to_vec();
    for payload in payloads {
        validate_frame_size(&payload)?;
        let length =
            u32::try_from(payload.len()).map_err(|_error| PlatformError::BoundExceeded {
                field: "journal frame",
                maximum: MAX_FRAME_SIZE,
            })?;
        bytes.extend_from_slice(&length.to_le_bytes());
        bytes.extend_from_slice(&checksum(&payload).to_le_bytes());
        bytes.extend_from_slice(&payload);
    }
    fs::write(path, bytes).map_err(|error| io_error("write unchecked journal fixture", error))
}

#[cfg(test)]
fn encode_header_unchecked(header: &JournalHeader) -> Result<Vec<u8>, PlatformError> {
    let mut bytes = Vec::new();
    bytes.push(1);
    put_u64(&mut bytes, header.transaction_id.0);
    bytes.push(match header.kind {
        TransactionKind::Apply => 1,
        TransactionKind::Undo => 2,
    });
    put_u64(&mut bytes, header.generation.0);
    put_u32(
        &mut bytes,
        u32::try_from(header.items.len()).map_err(|_error| PlatformError::BoundExceeded {
            field: "journal item count",
            maximum: crate::MAX_SOURCES,
        })?,
    );
    for item in &header.items {
        put_u64(&mut bytes, item.source_id.0);
        put_path_unchecked(&mut bytes, &item.original)?;
        put_path_unchecked(&mut bytes, &item.final_path)?;
        put_fingerprint(&mut bytes, item.fingerprint);
        put_fingerprint(&mut bytes, item.parent_fingerprint);
    }
    Ok(bytes)
}

#[cfg(test)]
fn put_path_unchecked(bytes: &mut Vec<u8>, path: &Path) -> Result<(), PlatformError> {
    let value = path.to_str().ok_or(PlatformError::Unsupported {
        operation: "encode unchecked non-Unicode test path",
    })?;
    put_u32(
        bytes,
        u32::try_from(value.len()).map_err(|_error| PlatformError::BoundExceeded {
            field: "path",
            maximum: 4_096,
        })?,
    );
    bytes.extend_from_slice(value.as_bytes());
    Ok(())
}
