use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use crate::filesystem::{EntryKind, FileIdentity, Fingerprint};
use crate::{
    Generation, PlatformError, SourceId, TransactionId, TransactionKind, io_error,
    validate_persisted_path,
};

const MAGIC: &[u8; 8] = b"DRJNL001";
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
}

#[derive(Debug)]
pub(crate) struct JournalStore {
    root: PathBuf,
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

    pub(crate) fn create(
        &self,
        header: &JournalHeader,
    ) -> Result<TransactionJournal, PlatformError> {
        let path = self
            .root
            .join(format!("{:016x}.drj", header.transaction_id.0));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .map_err(|error| io_error("create transaction journal", error))?;
        file.write_all(MAGIC)
            .map_err(|error| io_error("write journal magic", error))?;
        file.sync_data()
            .map_err(|error| io_error("sync journal magic", error))?;
        sync_directory(&self.root)?;
        let _ = path;
        let mut journal = TransactionJournal { file };
        journal.append(&Event::Header(header.clone()))?;
        Ok(journal)
    }

    fn scan(&self) -> Result<JournalScan, PlatformError> {
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
        for path in paths {
            if let Some(value) = path
                .file_stem()
                .and_then(|value| value.to_str())
                .and_then(|value| u64::from_str_radix(value, 16).ok())
            {
                maximum_transaction_id = maximum_transaction_id.max(value);
            }
            match parse_journal(&path) {
                Ok(ParseOutcome::Committed(transaction)) => {
                    let is_newer = latest.as_ref().is_none_or(|current| {
                        transaction.header.transaction_id.0 > current.header.transaction_id.0
                    });
                    if is_newer {
                        latest = Some(transaction);
                    }
                }
                Ok(ParseOutcome::Aborted) => {}
                Ok(ParseOutcome::Incomplete) | Err(()) => recovery_required = true,
            }
        }
        Ok(JournalScan {
            recovery_required,
            latest,
            maximum_transaction_id,
        })
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
        if payload.len() > MAX_FRAME_SIZE {
            return Err(PlatformError::BoundExceeded {
                field: "journal frame",
                maximum: MAX_FRAME_SIZE,
            });
        }
        let length =
            u32::try_from(payload.len()).map_err(|_error| PlatformError::BoundExceeded {
                field: "journal frame",
                maximum: MAX_FRAME_SIZE,
            })?;
        self.file
            .write_all(&length.to_le_bytes())
            .and_then(|()| self.file.write_all(&checksum(&payload).to_le_bytes()))
            .and_then(|()| self.file.write_all(&payload))
            .map_err(|error| io_error("append transaction journal", error))?;
        self.file
            .sync_data()
            .map_err(|error| io_error("sync transaction journal", error))
    }
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
    Incomplete,
}

fn parse_journal(path: &Path) -> Result<ParseOutcome, ()> {
    let metadata = fs::metadata(path).map_err(|_error| ())?;
    if metadata.len() > MAX_JOURNAL_SIZE {
        return Err(());
    }
    let mut bytes = Vec::with_capacity(usize::try_from(metadata.len()).map_err(|_error| ())?);
    File::open(path)
        .and_then(|mut file| file.read_to_end(&mut bytes))
        .map_err(|_error| ())?;
    if bytes.len() < MAGIC.len() || &bytes[..MAGIC.len()] != MAGIC {
        return Err(());
    }

    let mut cursor = MAGIC.len();
    let mut events = Vec::new();
    while cursor < bytes.len() {
        if bytes.len() - cursor < 12 {
            return Ok(ParseOutcome::Incomplete);
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
            return Ok(ParseOutcome::Incomplete);
        }
        let payload = &bytes[cursor..cursor + length];
        if checksum(payload) != expected_checksum {
            return Err(());
        }
        events.push(decode_event(payload)?);
        cursor += length;
    }
    validate_events(events)
}

fn validate_events(events: Vec<Event>) -> Result<ParseOutcome, ()> {
    let mut events = events.into_iter();
    let Some(Event::Header(header)) = events.next() else {
        return Err(());
    };
    let mut pending = None;
    let mut terminal = None;
    for event in events {
        if terminal.is_some() {
            return Err(());
        }
        match event {
            Event::MoveIntent { ordinal, .. } if pending.is_none() => pending = Some(ordinal),
            Event::MoveComplete { ordinal } if pending == Some(ordinal) => pending = None,
            Event::MoveFailed { ordinal } if pending == Some(ordinal) => pending = None,
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
    match terminal {
        Some(true) => Ok(ParseOutcome::Committed(CompletedTransaction { header })),
        Some(false) => Ok(ParseOutcome::Aborted),
        None => Ok(ParseOutcome::Incomplete),
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
            put_u64(&mut bytes, identity.file);
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
            Event::Header(JournalHeader {
                transaction_id,
                kind,
                generation,
                items: items.into(),
            })
        }
        2 => Event::MoveIntent {
            ordinal: reader.u32()?,
            from: reader.path()?,
            to: reader.path()?,
            identity: FileIdentity {
                volume: reader.u64()?,
                file: reader.u64()?,
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
    put_u64(bytes, fingerprint.identity.file);
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

    fn path(&mut self) -> Result<PathBuf, ()> {
        let length = usize::try_from(self.u32()?).map_err(|_error| ())?;
        if length > 4_096 {
            return Err(());
        }
        let value = std::str::from_utf8(self.take(length)?).map_err(|_error| ())?;
        Ok(PathBuf::from(value))
    }

    fn fingerprint(&mut self) -> Result<Fingerprint, ()> {
        let identity = FileIdentity {
            volume: self.u64()?,
            file: self.u64()?,
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
