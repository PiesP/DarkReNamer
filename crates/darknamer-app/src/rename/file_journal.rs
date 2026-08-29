//! Durable file journal and strict portable codec.
//!
//! On Windows, the root is retained without delete sharing and journal files use
//! exclusive final-component no-follow handles. Other hosts provide codec and
//! retained-handle validation only; their ordinary file open is not a production
//! confinement claim.

use std::fmt;
use std::fs::File;
#[cfg(not(windows))]
use std::fs::OpenOptions;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use darknamer_core::{LegacyText, validate_windows_leaf_name};

use super::{
    AuthorizedJournal, EntryId, EntryIdentity, JournalAuthorization, JournalDirection,
    JournalError, JournalRecord, JournalSnapshot, JournalStep, JournalStore, JournalTerminal,
    PlanId, RecoveryReason, RecoveryState, TemporaryPhase, replay_journal,
};

const MAGIC: [u8; 4] = *b"DRJ1";
const VERSION: u16 = 1;
const HEADER_BYTES: usize = 24;
const FLAGS_NONE: u8 = 0;

/// Maximum primitive steps stored in one intent manifest.
pub const MAX_JOURNAL_STEPS: usize = 10_000;
/// Maximum append-only frames in one transaction.
pub const MAX_JOURNAL_FRAMES: usize = MAX_JOURNAL_STEPS * 4 + 4;
/// Maximum payload bytes in one frame.
pub const MAX_JOURNAL_FRAME_BYTES: usize = 16 * 1024 * 1024;
/// Maximum complete journal bytes accepted or produced.
pub const MAX_JOURNAL_FILE_BYTES: usize = 64 * 1024 * 1024;
/// Maximum UTF-16 code units in one exact journal path.
pub const MAX_PATH_UNITS: usize = 32_767;

/// Strict codec failure kind.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalCodecErrorKind {
    /// File exceeds its total byte limit.
    FileTooLarge,
    /// More frames than allowed were supplied.
    TooManyFrames,
    /// Intent contains too many primitive steps.
    TooManySteps,
    /// An exact UTF-16 path exceeds its unit limit.
    PathTooLong,
    /// Frame header or payload is torn.
    TruncatedFrame,
    /// Frame magic does not match.
    InvalidMagic,
    /// Schema version is unsupported.
    UnsupportedVersion,
    /// Reserved frame flags are nonzero.
    InvalidFlags,
    /// Frame sequence is not contiguous from zero.
    SequenceMismatch,
    /// Declared payload exceeds the frame limit.
    FrameTooLarge,
    /// Frame checksum does not match its header and payload.
    ChecksumMismatch,
    /// Record kind is unknown.
    UnknownRecordKind,
    /// Record fields contain an unknown enum value.
    UnknownFieldValue,
    /// Record payload has trailing or structurally invalid data.
    InvalidPayload,
    /// Decoded records violate the strict journal state machine.
    InvalidTransitions,
    /// A numeric length cannot be represented safely.
    IntegerOutOfRange,
}

/// Strict codec error with the failing zero-based frame index.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct JournalCodecError {
    /// Failing frame index.
    pub frame: usize,
    /// Structured failure kind.
    pub kind: JournalCodecErrorKind,
}

impl JournalCodecError {
    const fn new(frame: usize, kind: JournalCodecErrorKind) -> Self {
        Self { frame, kind }
    }
}

impl fmt::Display for JournalCodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "journal frame {}: {:?}", self.frame, self.kind)
    }
}

impl std::error::Error for JournalCodecError {}

/// Recoverable issue limited to the final partially written frame.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalTailIssue {
    /// The final frame header is incomplete.
    TruncatedHeader,
    /// The final frame payload is incomplete.
    TruncatedPayload,
}

/// Complete valid prefix plus an optional recoverable final torn frame.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JournalInspection {
    records: Vec<JournalRecord>,
    issue: Option<JournalTailIssue>,
    valid_bytes: usize,
}

impl JournalInspection {
    /// Returns the strictly decoded complete-frame prefix.
    #[must_use]
    pub fn records(&self) -> &[JournalRecord] {
        &self.records
    }

    /// Returns the final torn-frame issue, if present.
    #[must_use]
    pub const fn issue(&self) -> Option<JournalTailIssue> {
        self.issue
    }

    /// Returns the exact byte length of the complete valid prefix.
    #[must_use]
    pub const fn valid_bytes(&self) -> usize {
        self.valid_bytes
    }
}

/// File adapter construction or resume failure kind.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FileJournalErrorKind {
    /// Operating-system file operation failed.
    Io,
    /// Existing bytes failed strict decoding.
    Codec(JournalCodecErrorKind),
    /// Opened target is not a regular non-reparse file.
    InvalidFileType,
    /// Journal root is relative.
    RelativeRoot,
    /// Journal root is missing, non-directory, symlinked, or reparsed.
    InvalidRoot,
    /// Journal leaf is not one valid Windows filename component.
    InvalidLeaf,
    /// Journal is incomplete or corrupt and cannot be deleted.
    UnsafeCleanupState,
    /// A pre-activation candidate contains execution or terminal records.
    InvalidCandidateState,
}

/// File journal error retaining a native code when available.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FileJournalError {
    /// Structured failure kind.
    pub kind: FileJournalErrorKind,
    /// Native OS code, when supplied by the platform.
    pub os_code: Option<i32>,
}

impl fmt::Display for FileJournalError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "file journal error: {:?}", self.kind)
    }
}

impl std::error::Error for FileJournalError {}

/// Stage at which an existing journal could not become recoverable.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalOpenStage {
    /// The exact journal leaf could not be opened.
    Open,
    /// The opened object or its metadata was invalid.
    Validate,
    /// The retained file could not be read completely.
    Read,
    /// Retained bytes failed strict journal decoding.
    Decode,
}

/// Structured failure retained for recovery diagnostics.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct JournalOpenFailure {
    /// Failed stage.
    pub stage: JournalOpenStage,
    /// Structured file-journal failure kind.
    pub kind: FileJournalErrorKind,
    /// Native operating-system code, when available.
    pub os_code: Option<i32>,
    /// Zero-based codec frame, when decoding identified one.
    pub codec_frame: Option<usize>,
}

impl JournalOpenFailure {
    fn from_file_error(stage: JournalOpenStage, error: FileJournalError) -> Self {
        Self {
            stage,
            kind: error.kind,
            os_code: error.os_code,
            codec_frame: None,
        }
    }

    fn from_codec(error: JournalCodecError) -> Self {
        Self {
            stage: JournalOpenStage::Decode,
            kind: FileJournalErrorKind::Codec(error.kind),
            os_code: None,
            codec_frame: Some(error.frame),
        }
    }

    fn as_file_error(self) -> FileJournalError {
        FileJournalError {
            kind: self.kind,
            os_code: self.os_code,
        }
    }
}

/// Exact retained journal bytes that could not be decoded for recovery.
#[derive(Debug)]
pub struct RecoveryJournalEvidence {
    path: PathBuf,
    file: File,
    byte_len: u64,
    failure: JournalOpenFailure,
}

impl RecoveryJournalEvidence {
    /// Returns the operator-facing path associated with the retained handle.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Returns the retained file length observed when opening failed.
    #[must_use]
    pub const fn byte_len(&self) -> u64 {
        self.byte_len
    }

    /// Returns the structured failure that prevented recovery.
    #[must_use]
    pub const fn failure(&self) -> JournalOpenFailure {
        self.failure
    }

    /// Copies the exact retained bytes into a newly created destination.
    ///
    /// # Errors
    ///
    /// Returns an error when the retained evidence is oversized, cannot be
    /// reread exactly, or the destination already exists or cannot be synced.
    pub fn copy_exact_to_new(&mut self, destination: &Path) -> io::Result<u64> {
        if self.byte_len > MAX_JOURNAL_FILE_BYTES as u64 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "journal evidence exceeds the bounded copy limit",
            ));
        }
        let expected = usize::try_from(self.byte_len)
            .map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
        self.file.seek(SeekFrom::Start(0))?;
        let mut bytes = Vec::with_capacity(expected);
        Read::by_ref(&mut self.file)
            .take(self.byte_len.saturating_add(1))
            .read_to_end(&mut bytes)?;
        if bytes.len() != expected {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "retained journal evidence changed length",
            ));
        }
        let mut output = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(destination)?;
        let copy_result = output
            .write_all(&bytes)
            .and_then(|()| output.flush())
            .and_then(|()| output.sync_all());
        drop(output);
        if let Err(error) = copy_result {
            return Err(io::Error::other(format!(
                "evidence copy failed ({error}); partial destination was retained"
            )));
        }
        Ok(self.byte_len)
    }
}

/// Existing-journal failure with retained evidence whenever open succeeded.
#[derive(Debug)]
pub struct ExistingJournalOpenError {
    path: PathBuf,
    failure: JournalOpenFailure,
    evidence: Option<Box<RecoveryJournalEvidence>>,
}

impl ExistingJournalOpenError {
    /// Returns the operator-facing journal path.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Returns why the journal could not become recoverable.
    #[must_use]
    pub const fn failure(&self) -> JournalOpenFailure {
        self.failure
    }

    /// Returns whether no file existed at the retained journal leaf.
    #[must_use]
    pub fn is_not_found(&self) -> bool {
        self.evidence.is_none() && matches!(self.failure.os_code, Some(2 | 3))
    }

    /// Takes the exact retained evidence, when the file was opened.
    #[must_use]
    pub fn into_evidence(self) -> Option<RecoveryJournalEvidence> {
        self.evidence.map(|evidence| *evidence)
    }
}

impl fmt::Display for ExistingJournalOpenError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "existing journal {:?} failed at {:?}",
            self.failure.kind, self.failure.stage
        )
    }
}

impl std::error::Error for ExistingJournalOpenError {}

impl From<io::Error> for FileJournalError {
    fn from(error: io::Error) -> Self {
        Self {
            kind: FileJournalErrorKind::Io,
            os_code: error.raw_os_error(),
        }
    }
}

impl From<JournalCodecError> for FileJournalError {
    fn from(error: JournalCodecError) -> Self {
        Self {
            kind: FileJournalErrorKind::Codec(error.kind),
            os_code: None,
        }
    }
}

/// Retained authority for one validated absolute journal directory.
///
/// Windows retains a component-traversed, non-reparse directory handle with
/// read/write sharing but no delete sharing, then creates or opens each validated
/// journal leaf relative to it with an exclusive `NtCreateFile`. Safe v1 rejects
/// UNC/SMB and device-namespace roots.
#[derive(Debug)]
pub struct JournalRoot {
    path: PathBuf,
    file: File,
    identity: u64,
}

impl JournalRoot {
    /// Opens and retains an existing absolute non-reparse directory.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, FileJournalError> {
        let path = path.as_ref().to_path_buf();
        if !path.is_absolute() {
            return Err(FileJournalError {
                kind: FileJournalErrorKind::RelativeRoot,
                os_code: None,
            });
        }
        #[cfg(windows)]
        super::windows_native::validate_safe_local_root(&path)?;
        validate_root_components(&path)?;
        let file = open_root(&path)?;
        let metadata = file.metadata()?;
        if !metadata.is_dir() || metadata_is_reparse(&metadata) {
            return Err(FileJournalError {
                kind: FileJournalErrorKind::InvalidRoot,
                os_code: None,
            });
        }
        Ok(Self {
            path,
            file,
            identity: next_file_identity(),
        })
    }

    /// Returns the retained root path for operator display.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    fn child(&self, leaf: &str) -> Result<PathBuf, FileJournalError> {
        if validate_windows_leaf_name(&LegacyText::from(leaf)).is_err() {
            return Err(FileJournalError {
                kind: FileJournalErrorKind::InvalidLeaf,
                os_code: None,
            });
        }
        Ok(self.path.join(leaf))
    }
}

/// Encodes a complete bounded append-only record stream.
pub fn encode_journal_records(records: &[JournalRecord]) -> Result<Vec<u8>, JournalCodecError> {
    if records.len() > MAX_JOURNAL_FRAMES {
        return Err(JournalCodecError::new(
            MAX_JOURNAL_FRAMES,
            JournalCodecErrorKind::TooManyFrames,
        ));
    }
    let mut bytes = Vec::new();
    for (index, record) in records.iter().enumerate() {
        let sequence = u64::try_from(index)
            .map_err(|_| JournalCodecError::new(index, JournalCodecErrorKind::IntegerOutOfRange))?;
        let frame = encode_frame(sequence, record, index)?;
        if bytes.len().saturating_add(frame.len()) > MAX_JOURNAL_FILE_BYTES {
            return Err(JournalCodecError::new(
                index,
                JournalCodecErrorKind::FileTooLarge,
            ));
        }
        bytes.extend_from_slice(&frame);
    }
    Ok(bytes)
}

/// Decodes and strictly validates a complete bounded record stream.
pub fn decode_journal_records(bytes: &[u8]) -> Result<Vec<JournalRecord>, JournalCodecError> {
    let inspection = inspect_journal_records(bytes)?;
    if inspection.issue.is_some() {
        return Err(JournalCodecError::new(
            inspection.records.len(),
            JournalCodecErrorKind::TruncatedFrame,
        ));
    }
    Ok(inspection.records)
}

/// Inspects a strict complete prefix while distinguishing only a final torn frame.
pub fn inspect_journal_records(bytes: &[u8]) -> Result<JournalInspection, JournalCodecError> {
    if bytes.len() > MAX_JOURNAL_FILE_BYTES {
        return Err(JournalCodecError::new(
            0,
            JournalCodecErrorKind::FileTooLarge,
        ));
    }
    let mut records = Vec::new();
    let mut offset = 0_usize;
    while offset < bytes.len() {
        let frame = records.len();
        if frame >= MAX_JOURNAL_FRAMES {
            return Err(JournalCodecError::new(
                frame,
                JournalCodecErrorKind::TooManyFrames,
            ));
        }
        let header_end = offset.checked_add(HEADER_BYTES).ok_or_else(|| {
            JournalCodecError::new(frame, JournalCodecErrorKind::IntegerOutOfRange)
        })?;
        let Some(header) = bytes.get(offset..header_end) else {
            return finish_inspection(records, Some(JournalTailIssue::TruncatedHeader), offset);
        };
        if header[..4] != MAGIC {
            return Err(JournalCodecError::new(
                frame,
                JournalCodecErrorKind::InvalidMagic,
            ));
        }
        if u16::from_le_bytes([header[4], header[5]]) != VERSION {
            return Err(JournalCodecError::new(
                frame,
                JournalCodecErrorKind::UnsupportedVersion,
            ));
        }
        let kind = header[6];
        if !(1..=5).contains(&kind) {
            return Err(JournalCodecError::new(
                frame,
                JournalCodecErrorKind::UnknownRecordKind,
            ));
        }
        if header[7] != FLAGS_NONE {
            return Err(JournalCodecError::new(
                frame,
                JournalCodecErrorKind::InvalidFlags,
            ));
        }
        let sequence = read_fixed_u64(&header[8..16], frame)?;
        let expected = u64::try_from(frame)
            .map_err(|_| JournalCodecError::new(frame, JournalCodecErrorKind::IntegerOutOfRange))?;
        if sequence != expected {
            return Err(JournalCodecError::new(
                frame,
                JournalCodecErrorKind::SequenceMismatch,
            ));
        }
        let payload_len = read_fixed_u32(&header[16..20], frame)? as usize;
        if payload_len > MAX_JOURNAL_FRAME_BYTES {
            return Err(JournalCodecError::new(
                frame,
                JournalCodecErrorKind::FrameTooLarge,
            ));
        }
        let frame_end = header_end.checked_add(payload_len).ok_or_else(|| {
            JournalCodecError::new(frame, JournalCodecErrorKind::IntegerOutOfRange)
        })?;
        let Some(payload) = bytes.get(header_end..frame_end) else {
            return finish_inspection(records, Some(JournalTailIssue::TruncatedPayload), offset);
        };
        let checksum = read_fixed_u32(&header[20..24], frame)?;
        if checksum != crc32_parts(&[&header[4..20], payload]) {
            return Err(JournalCodecError::new(
                frame,
                JournalCodecErrorKind::ChecksumMismatch,
            ));
        }
        records.push(decode_record(kind, payload, frame)?);
        offset = frame_end;
    }
    finish_inspection(records, None, offset)
}

fn finish_inspection(
    records: Vec<JournalRecord>,
    issue: Option<JournalTailIssue>,
    valid_bytes: usize,
) -> Result<JournalInspection, JournalCodecError> {
    if issue.is_some() && records.is_empty() {
        return Err(JournalCodecError::new(
            0,
            JournalCodecErrorKind::TruncatedFrame,
        ));
    }
    if matches!(
        replay_journal(&records),
        RecoveryState::RecoveryRequired {
            reason: RecoveryReason::Corrupt(_),
            ..
        }
    ) {
        return Err(JournalCodecError::new(
            records.len().saturating_sub(1),
            JournalCodecErrorKind::InvalidTransitions,
        ));
    }
    Ok(JournalInspection {
        records,
        issue,
        valid_bytes,
    })
}

fn encode_frame(
    sequence: u64,
    record: &JournalRecord,
    frame: usize,
) -> Result<Vec<u8>, JournalCodecError> {
    let mut payload = Vec::new();
    let kind = encode_record(record, &mut payload, frame)?;
    if payload.len() > MAX_JOURNAL_FRAME_BYTES {
        return Err(JournalCodecError::new(
            frame,
            JournalCodecErrorKind::FrameTooLarge,
        ));
    }
    let payload_len = u32::try_from(payload.len())
        .map_err(|_| JournalCodecError::new(frame, JournalCodecErrorKind::IntegerOutOfRange))?;
    let mut encoded = Vec::with_capacity(HEADER_BYTES + payload.len());
    encoded.extend_from_slice(&MAGIC);
    encoded.extend_from_slice(&VERSION.to_le_bytes());
    encoded.push(kind);
    encoded.push(FLAGS_NONE);
    encoded.extend_from_slice(&sequence.to_le_bytes());
    encoded.extend_from_slice(&payload_len.to_le_bytes());
    encoded.extend_from_slice(&0_u32.to_le_bytes());
    encoded.extend_from_slice(&payload);
    let checksum = crc32_parts(&[&encoded[4..20], &encoded[HEADER_BYTES..]]);
    encoded[20..24].copy_from_slice(&checksum.to_le_bytes());
    Ok(encoded)
}

fn encode_record(
    record: &JournalRecord,
    payload: &mut Vec<u8>,
    frame: usize,
) -> Result<u8, JournalCodecError> {
    match record {
        JournalRecord::Intent { plan, steps } => {
            if steps.len() > MAX_JOURNAL_STEPS {
                return Err(JournalCodecError::new(
                    frame,
                    JournalCodecErrorKind::TooManySteps,
                ));
            }
            put_u64(payload, plan.fingerprint());
            put_u32_len(payload, steps.len(), frame)?;
            for step in steps {
                put_u32(payload, step.entry().value());
                put_text(payload, step.source(), frame)?;
                put_text(payload, step.destination(), frame)?;
                put_identity(payload, step.expected_source());
                put_identity(payload, step.expected_source_parent());
                put_identity(payload, step.expected_destination_parent());
                payload.push(encode_phase(step.temporary_phase()));
                if payload.len() > MAX_JOURNAL_FRAME_BYTES {
                    return Err(JournalCodecError::new(
                        frame,
                        JournalCodecErrorKind::FrameTooLarge,
                    ));
                }
            }
            Ok(1)
        }
        JournalRecord::Prepared { step, direction } => {
            put_u32_len(payload, *step, frame)?;
            payload.push(encode_direction(*direction));
            Ok(2)
        }
        JournalRecord::Completed { step, direction } => {
            put_u32_len(payload, *step, frame)?;
            payload.push(encode_direction(*direction));
            Ok(3)
        }
        JournalRecord::NotApplied { step, direction } => {
            put_u32_len(payload, *step, frame)?;
            payload.push(encode_direction(*direction));
            Ok(4)
        }
        JournalRecord::Terminal(terminal) => {
            payload.push(match terminal {
                JournalTerminal::Committed => 0,
                JournalTerminal::RolledBack => 1,
            });
            Ok(5)
        }
    }
}

fn decode_record(
    kind: u8,
    payload: &[u8],
    frame: usize,
) -> Result<JournalRecord, JournalCodecError> {
    let mut decoder = Decoder::new(payload, frame);
    let record = match kind {
        1 => {
            let plan = PlanId::from_fingerprint(decoder.u64()?);
            let count = decoder.usize_u32()?;
            if count > MAX_JOURNAL_STEPS {
                return Err(JournalCodecError::new(
                    frame,
                    JournalCodecErrorKind::TooManySteps,
                ));
            }
            let mut steps = Vec::with_capacity(count);
            for _ in 0..count {
                let entry = EntryId::new(decoder.u32()?);
                let source = decoder.text()?;
                let destination = decoder.text()?;
                let expected_source = decoder.identity()?;
                let expected_source_parent = decoder.identity()?;
                let expected_destination_parent = decoder.identity()?;
                let temporary_phase = decode_phase(decoder.u8()?, frame)?;
                steps.push(JournalStep::new(
                    entry,
                    source,
                    destination,
                    expected_source,
                    expected_source_parent,
                    expected_destination_parent,
                    temporary_phase,
                ));
            }
            JournalRecord::Intent {
                plan,
                steps: steps.into_boxed_slice(),
            }
        }
        2 => JournalRecord::Prepared {
            step: decoder.usize_u32()?,
            direction: decode_direction(decoder.u8()?, frame)?,
        },
        3 => JournalRecord::Completed {
            step: decoder.usize_u32()?,
            direction: decode_direction(decoder.u8()?, frame)?,
        },
        4 => JournalRecord::NotApplied {
            step: decoder.usize_u32()?,
            direction: decode_direction(decoder.u8()?, frame)?,
        },
        5 => JournalRecord::Terminal(match decoder.u8()? {
            0 => JournalTerminal::Committed,
            1 => JournalTerminal::RolledBack,
            _ => {
                return Err(JournalCodecError::new(
                    frame,
                    JournalCodecErrorKind::UnknownFieldValue,
                ));
            }
        }),
        _ => {
            return Err(JournalCodecError::new(
                frame,
                JournalCodecErrorKind::UnknownRecordKind,
            ));
        }
    };
    decoder.finish()?;
    Ok(record)
}

struct Decoder<'a> {
    bytes: &'a [u8],
    offset: usize,
    frame: usize,
}

impl<'a> Decoder<'a> {
    const fn new(bytes: &'a [u8], frame: usize) -> Self {
        Self {
            bytes,
            offset: 0,
            frame,
        }
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], JournalCodecError> {
        let end = self.offset.checked_add(count).ok_or_else(|| {
            JournalCodecError::new(self.frame, JournalCodecErrorKind::IntegerOutOfRange)
        })?;
        let bytes = self.bytes.get(self.offset..end).ok_or_else(|| {
            JournalCodecError::new(self.frame, JournalCodecErrorKind::InvalidPayload)
        })?;
        self.offset = end;
        Ok(bytes)
    }

    fn u8(&mut self) -> Result<u8, JournalCodecError> {
        Ok(self.take(1)?[0])
    }

    fn u32(&mut self) -> Result<u32, JournalCodecError> {
        read_fixed_u32(self.take(4)?, self.frame)
    }

    fn usize_u32(&mut self) -> Result<usize, JournalCodecError> {
        Ok(self.u32()? as usize)
    }

    fn u64(&mut self) -> Result<u64, JournalCodecError> {
        read_fixed_u64(self.take(8)?, self.frame)
    }

    fn u128(&mut self) -> Result<u128, JournalCodecError> {
        let bytes: [u8; 16] = self.take(16)?.try_into().map_err(|_| {
            JournalCodecError::new(self.frame, JournalCodecErrorKind::InvalidPayload)
        })?;
        Ok(u128::from_le_bytes(bytes))
    }

    fn identity(&mut self) -> Result<EntryIdentity, JournalCodecError> {
        Ok(EntryIdentity::new(self.u64()?, self.u128()?))
    }

    fn text(&mut self) -> Result<LegacyText, JournalCodecError> {
        let units = self.usize_u32()?;
        if units > MAX_PATH_UNITS {
            return Err(JournalCodecError::new(
                self.frame,
                JournalCodecErrorKind::PathTooLong,
            ));
        }
        let byte_count = units.checked_mul(2).ok_or_else(|| {
            JournalCodecError::new(self.frame, JournalCodecErrorKind::IntegerOutOfRange)
        })?;
        let bytes = self.take(byte_count)?;
        let units = bytes
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect::<Vec<_>>();
        Ok(LegacyText::from_units(units))
    }

    fn finish(self) -> Result<(), JournalCodecError> {
        if self.offset == self.bytes.len() {
            Ok(())
        } else {
            Err(JournalCodecError::new(
                self.frame,
                JournalCodecErrorKind::InvalidPayload,
            ))
        }
    }
}

fn put_u32(payload: &mut Vec<u8>, value: u32) {
    payload.extend_from_slice(&value.to_le_bytes());
}

fn put_u32_len(payload: &mut Vec<u8>, value: usize, frame: usize) -> Result<(), JournalCodecError> {
    let value = u32::try_from(value)
        .map_err(|_| JournalCodecError::new(frame, JournalCodecErrorKind::IntegerOutOfRange))?;
    put_u32(payload, value);
    Ok(())
}

fn put_u64(payload: &mut Vec<u8>, value: u64) {
    payload.extend_from_slice(&value.to_le_bytes());
}

fn put_identity(payload: &mut Vec<u8>, identity: EntryIdentity) {
    payload.extend_from_slice(&identity.volume().to_le_bytes());
    payload.extend_from_slice(&identity.file_id().to_le_bytes());
}

fn put_text(
    payload: &mut Vec<u8>,
    text: &LegacyText,
    frame: usize,
) -> Result<(), JournalCodecError> {
    if text.len() > MAX_PATH_UNITS {
        return Err(JournalCodecError::new(
            frame,
            JournalCodecErrorKind::PathTooLong,
        ));
    }
    let encoded_units = text
        .len()
        .checked_mul(2)
        .ok_or_else(|| JournalCodecError::new(frame, JournalCodecErrorKind::IntegerOutOfRange))?;
    let prospective = payload
        .len()
        .checked_add(4)
        .and_then(|length| length.checked_add(encoded_units))
        .ok_or_else(|| JournalCodecError::new(frame, JournalCodecErrorKind::IntegerOutOfRange))?;
    if prospective > MAX_JOURNAL_FRAME_BYTES {
        return Err(JournalCodecError::new(
            frame,
            JournalCodecErrorKind::FrameTooLarge,
        ));
    }
    put_u32_len(payload, text.len(), frame)?;
    for unit in text.units() {
        payload.extend_from_slice(&unit.to_le_bytes());
    }
    Ok(())
}

const fn encode_direction(direction: JournalDirection) -> u8 {
    match direction {
        JournalDirection::Forward => 0,
        JournalDirection::Rollback => 1,
    }
}

fn decode_direction(value: u8, frame: usize) -> Result<JournalDirection, JournalCodecError> {
    match value {
        0 => Ok(JournalDirection::Forward),
        1 => Ok(JournalDirection::Rollback),
        _ => Err(JournalCodecError::new(
            frame,
            JournalCodecErrorKind::UnknownFieldValue,
        )),
    }
}

const fn encode_phase(phase: TemporaryPhase) -> u8 {
    match phase {
        TemporaryPhase::None => 0,
        TemporaryPhase::IntoTemporary => 1,
        TemporaryPhase::FromTemporary => 2,
    }
}

fn decode_phase(value: u8, frame: usize) -> Result<TemporaryPhase, JournalCodecError> {
    match value {
        0 => Ok(TemporaryPhase::None),
        1 => Ok(TemporaryPhase::IntoTemporary),
        2 => Ok(TemporaryPhase::FromTemporary),
        _ => Err(JournalCodecError::new(
            frame,
            JournalCodecErrorKind::UnknownFieldValue,
        )),
    }
}

fn read_fixed_u32(bytes: &[u8], frame: usize) -> Result<u32, JournalCodecError> {
    let bytes: [u8; 4] = bytes
        .try_into()
        .map_err(|_| JournalCodecError::new(frame, JournalCodecErrorKind::InvalidPayload))?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_fixed_u64(bytes: &[u8], frame: usize) -> Result<u64, JournalCodecError> {
    let bytes: [u8; 8] = bytes
        .try_into()
        .map_err(|_| JournalCodecError::new(frame, JournalCodecErrorKind::InvalidPayload))?;
    Ok(u64::from_le_bytes(bytes))
}

fn crc32_parts(parts: &[&[u8]]) -> u32 {
    let mut crc = u32::MAX;
    for part in parts {
        for byte in *part {
            crc ^= u32::from(*byte);
            for _ in 0..8 {
                let mask = 0_u32.wrapping_sub(crc & 1);
                crc = (crc >> 1) ^ (0xedb8_8320 & mask);
            }
        }
    }
    !crc
}

/// Durable append-only file journal retaining one owned file capability.
#[derive(Debug)]
pub struct FileJournal {
    path: PathBuf,
    _root: File,
    _root_identity: u64,
    file: File,
    records: Vec<JournalRecord>,
    identity: u64,
    generation: u64,
    next_sequence: u64,
    byte_length: usize,
    torn_prefix: Option<usize>,
    tail_issue: Option<JournalTailIssue>,
    poisoned: bool,
    phase: FileJournalPhase,
}

#[derive(Debug)]
enum FileJournalPhase {
    Active,
    Candidate {
        active_path: PathBuf,
        active_leaf: String,
    },
    PromotionUncertain,
}

impl FileJournal {
    /// Creates and exclusively retains a new empty journal.
    pub fn create_new(root: &JournalRoot, leaf: &str) -> Result<Self, FileJournalError> {
        let path = root.child(leaf)?;
        let file = open_create_new(&root.file, &path, leaf)?;
        validate_file_type(&file)?;
        Ok(Self {
            path,
            _root: root.file.try_clone()?,
            _root_identity: root.identity,
            file,
            records: Vec::new(),
            identity: combined_identity(root.identity),
            generation: 0,
            next_sequence: 0,
            byte_length: 0,
            torn_prefix: None,
            tail_issue: None,
            poisoned: false,
            phase: FileJournalPhase::Active,
        })
    }

    /// Creates and retains a candidate that becomes active only after its
    /// Intent record is durable.
    pub fn create_candidate(
        root: &JournalRoot,
        candidate_leaf: &str,
        active_leaf: &str,
    ) -> Result<Self, FileJournalError> {
        let candidate_path = root.child(candidate_leaf)?;
        let active_path = root.child(active_leaf)?;
        if candidate_path == active_path {
            return Err(FileJournalError {
                kind: FileJournalErrorKind::InvalidLeaf,
                os_code: None,
            });
        }
        let file = open_create_new(&root.file, &candidate_path, candidate_leaf)?;
        validate_file_type(&file)?;
        Ok(Self {
            path: candidate_path,
            _root: root.file.try_clone()?,
            _root_identity: root.identity,
            file,
            records: Vec::new(),
            identity: combined_identity(root.identity),
            generation: 0,
            next_sequence: 0,
            byte_length: 0,
            torn_prefix: None,
            tail_issue: None,
            poisoned: false,
            phase: FileJournalPhase::Candidate {
                active_path,
                active_leaf: active_leaf.to_owned(),
            },
        })
    }

    /// Opens, exclusively retains, decodes, and resumes an existing journal.
    pub fn open_existing(root: &JournalRoot, leaf: &str) -> Result<Self, FileJournalError> {
        Self::open_existing_retained(root, leaf).map_err(|error| error.failure.as_file_error())
    }

    /// Opens an existing journal while retaining exact evidence on post-open
    /// validation, read, or decode failure.
    pub fn open_existing_retained(
        root: &JournalRoot,
        leaf: &str,
    ) -> Result<Self, ExistingJournalOpenError> {
        let path = root.child(leaf).map_err(|error| ExistingJournalOpenError {
            path: root.path.join(leaf),
            failure: JournalOpenFailure::from_file_error(JournalOpenStage::Validate, error),
            evidence: None,
        })?;
        reject_final_link(&path).map_err(|error| ExistingJournalOpenError {
            path: path.clone(),
            failure: JournalOpenFailure::from_file_error(JournalOpenStage::Validate, error),
            evidence: None,
        })?;
        let mut file =
            open_existing(&root.file, &path, leaf).map_err(|error| ExistingJournalOpenError {
                path: path.clone(),
                failure: JournalOpenFailure::from_file_error(JournalOpenStage::Open, error.into()),
                evidence: None,
            })?;
        let metadata = match file.metadata() {
            Ok(metadata) => metadata,
            Err(error) => {
                return Err(existing_evidence_error(
                    path,
                    file,
                    0,
                    JournalOpenFailure::from_file_error(JournalOpenStage::Validate, error.into()),
                ));
            }
        };
        let byte_len = metadata.len();
        if !metadata.is_file() || metadata_is_reparse(&metadata) {
            return Err(existing_evidence_error(
                path,
                file,
                byte_len,
                JournalOpenFailure::from_file_error(
                    JournalOpenStage::Validate,
                    FileJournalError {
                        kind: FileJournalErrorKind::InvalidFileType,
                        os_code: None,
                    },
                ),
            ));
        }
        let file_len = match usize::try_from(byte_len) {
            Ok(length) if length <= MAX_JOURNAL_FILE_BYTES => length,
            _ => {
                return Err(existing_evidence_error(
                    path,
                    file,
                    byte_len,
                    JournalOpenFailure::from_file_error(
                        JournalOpenStage::Validate,
                        FileJournalError {
                            kind: FileJournalErrorKind::Codec(JournalCodecErrorKind::FileTooLarge),
                            os_code: None,
                        },
                    ),
                ));
            }
        };
        let mut bytes = Vec::with_capacity(file_len);
        if let Err(error) = file.seek(SeekFrom::Start(0)).and_then(|_| {
            Read::by_ref(&mut file)
                .take((MAX_JOURNAL_FILE_BYTES as u64).saturating_add(1))
                .read_to_end(&mut bytes)
                .map(|_| ())
        }) {
            return Err(existing_evidence_error(
                path,
                file,
                byte_len,
                JournalOpenFailure::from_file_error(JournalOpenStage::Read, error.into()),
            ));
        }
        if bytes.len() > MAX_JOURNAL_FILE_BYTES {
            return Err(existing_evidence_error(
                path,
                file,
                byte_len,
                JournalOpenFailure::from_file_error(
                    JournalOpenStage::Validate,
                    FileJournalError {
                        kind: FileJournalErrorKind::Codec(JournalCodecErrorKind::FileTooLarge),
                        os_code: None,
                    },
                ),
            ));
        }
        let inspection = match inspect_journal_records(&bytes) {
            Ok(inspection) => inspection,
            Err(error) => {
                return Err(existing_evidence_error(
                    path,
                    file,
                    byte_len,
                    JournalOpenFailure::from_codec(error),
                ));
            }
        };
        let records = inspection.records;
        if let Err(error) = file.seek(SeekFrom::End(0)) {
            return Err(existing_evidence_error(
                path,
                file,
                byte_len,
                JournalOpenFailure::from_file_error(JournalOpenStage::Read, error.into()),
            ));
        }
        let generation = match u64::try_from(records.len()) {
            Ok(generation) => generation,
            Err(_error) => {
                return Err(existing_evidence_error(
                    path,
                    file,
                    byte_len,
                    JournalOpenFailure::from_file_error(
                        JournalOpenStage::Decode,
                        FileJournalError {
                            kind: FileJournalErrorKind::Codec(JournalCodecErrorKind::TooManyFrames),
                            os_code: None,
                        },
                    ),
                ));
            }
        };
        let retained_root = match root.file.try_clone() {
            Ok(root) => root,
            Err(error) => {
                return Err(existing_evidence_error(
                    path,
                    file,
                    byte_len,
                    JournalOpenFailure::from_file_error(JournalOpenStage::Validate, error.into()),
                ));
            }
        };
        Ok(Self {
            path,
            _root: retained_root,
            _root_identity: root.identity,
            file,
            records,
            identity: combined_identity(root.identity),
            generation,
            next_sequence: generation,
            byte_length: bytes.len(),
            torn_prefix: inspection.issue.map(|_| inspection.valid_bytes),
            tail_issue: inspection.issue,
            poisoned: false,
            phase: FileJournalPhase::Active,
        })
    }

    /// Opens an abandoned pre-activation candidate without treating it as an
    /// active transaction.
    pub fn open_candidate_existing(
        root: &JournalRoot,
        candidate_leaf: &str,
        active_leaf: &str,
    ) -> Result<Self, FileJournalError> {
        Self::open_candidate_existing_retained(root, candidate_leaf, active_leaf)
            .map_err(|error| error.failure.as_file_error())
    }

    /// Opens a candidate while retaining exact evidence when its bytes are
    /// corrupt or contain post-activation transitions.
    pub fn open_candidate_existing_retained(
        root: &JournalRoot,
        candidate_leaf: &str,
        active_leaf: &str,
    ) -> Result<Self, ExistingJournalOpenError> {
        let active_path = root
            .child(active_leaf)
            .map_err(|error| ExistingJournalOpenError {
                path: root.path.join(active_leaf),
                failure: JournalOpenFailure::from_file_error(JournalOpenStage::Validate, error),
                evidence: None,
            })?;
        let mut journal = Self::open_existing_retained(root, candidate_leaf)?;
        let valid_candidate = journal.records.is_empty()
            || matches!(journal.records.as_slice(), [JournalRecord::Intent { .. }]);
        if !valid_candidate {
            return Err(
                journal.into_existing_error(JournalOpenFailure::from_file_error(
                    JournalOpenStage::Validate,
                    FileJournalError {
                        kind: FileJournalErrorKind::InvalidCandidateState,
                        os_code: None,
                    },
                )),
            );
        }
        journal.phase = FileJournalPhase::Candidate {
            active_path,
            active_leaf: active_leaf.to_owned(),
        };
        Ok(journal)
    }

    /// Returns the retained path for operator display or explicit archival.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Returns whether this retained file has not been promoted to active.
    #[must_use]
    pub const fn is_candidate(&self) -> bool {
        matches!(&self.phase, FileJournalPhase::Candidate { .. })
    }

    fn into_existing_error(self, failure: JournalOpenFailure) -> ExistingJournalOpenError {
        let path = self.path;
        let byte_len = self.byte_length as u64;
        ExistingJournalOpenError {
            path: path.clone(),
            failure,
            evidence: Some(Box::new(RecoveryJournalEvidence {
                path,
                file: self.file,
                byte_len,
                failure,
            })),
        }
    }

    /// Returns decoded append-only records.
    ///
    /// Dropping the value does not request deletion. If
    /// [`Self::mark_delete_if_safe`] previously succeeded, closing the retained
    /// handle during drop completes that explicit delete disposition.
    #[must_use]
    pub fn records(&self) -> &[JournalRecord] {
        &self.records
    }

    /// Returns the explicit recoverable final torn-frame issue retained on resume.
    #[must_use]
    pub const fn tail_issue(&self) -> Option<JournalTailIssue> {
        self.tail_issue
    }

    /// Returns whether the retained journal has an explicit terminal record.
    ///
    /// The adapter never requests removal or archival implicitly; an operator
    /// may explicitly call [`Self::mark_delete_if_safe`] after this reports true.
    #[must_use]
    pub fn is_terminal(&self) -> bool {
        matches!(self.records.last(), Some(JournalRecord::Terminal(_)))
    }

    /// Marks a verified empty or terminal journal for deletion by retained handle.
    ///
    /// The caller must keep this value on failure; successful deletion completes
    /// when the owned file handle is dropped.
    pub fn mark_delete_if_safe(&mut self) -> Result<(), FileJournalError> {
        let safe = !self.poisoned
            && match &self.phase {
                FileJournalPhase::Active => {
                    self.records.is_empty()
                        || self.is_terminal()
                            && replay_journal(&self.records) == RecoveryState::Clean
                }
                FileJournalPhase::Candidate { .. } => self.records.is_empty(),
                FileJournalPhase::PromotionUncertain => false,
            };
        if !safe {
            return Err(FileJournalError {
                kind: FileJournalErrorKind::UnsafeCleanupState,
                os_code: None,
            });
        }
        mark_retained_file_delete(&self.file)?;
        Ok(())
    }

    fn append(&mut self, record: JournalRecord) -> Result<(), JournalError> {
        if self.poisoned {
            return Err(JournalError::may_have_appended(8));
        }
        if self.torn_prefix.is_some() {
            return Err(JournalError::not_appended(7));
        }
        if self.records.len() >= MAX_JOURNAL_FRAMES {
            return Err(JournalError::not_appended(3));
        }
        let frame_index = self.records.len();
        let frame = encode_frame(self.next_sequence, &record, frame_index)
            .map_err(|_| JournalError::not_appended(4))?;
        if self.byte_length.saturating_add(frame.len()) > MAX_JOURNAL_FILE_BYTES {
            return Err(JournalError::not_appended(5));
        }
        self.poisoned = true;
        self.file
            .write_all(&frame)
            .map_err(journal_io_may_have_appended)?;
        self.file.flush().map_err(journal_io_may_have_appended)?;
        self.file.sync_all().map_err(journal_io_may_have_appended)?;
        self.byte_length += frame.len();
        self.records.push(record);
        self.generation = self.generation.saturating_add(1);
        self.next_sequence = self.next_sequence.saturating_add(1);
        self.poisoned = false;
        Ok(())
    }

    fn promote_candidate(&mut self) -> Result<(), JournalError> {
        let FileJournalPhase::Candidate {
            active_path,
            active_leaf,
        } = &self.phase
        else {
            return Ok(());
        };
        let active_path = active_path.clone();
        let active_leaf = active_leaf.clone();
        self.poisoned = true;
        if let Err(error) = promote_file_noreplace(
            &self.file,
            &self._root,
            &self.path,
            &active_path,
            &active_leaf,
        ) {
            self.phase = FileJournalPhase::PromotionUncertain;
            return Err(journal_io_may_have_appended(error));
        }
        self.path = active_path;
        self.phase = FileJournalPhase::Active;
        self.poisoned = false;
        Ok(())
    }

    fn require_active(&self) -> Result<(), JournalError> {
        if self.poisoned {
            return Err(JournalError::may_have_appended(8));
        }
        if !matches!(&self.phase, FileJournalPhase::Active) {
            return Err(JournalError::not_appended(9));
        }
        Ok(())
    }

    fn authorized_append(
        &mut self,
        authorization: &mut JournalAuthorization,
        record: JournalRecord,
    ) -> Result<(), JournalError> {
        if self.poisoned {
            return Err(JournalError::may_have_appended(8));
        }
        self.require_active()?;
        if authorization.identity != self.identity || authorization.generation != self.generation {
            return Err(JournalError::not_appended(2));
        }
        if let Some(valid_bytes) = self.torn_prefix {
            let length = u64::try_from(valid_bytes).map_err(|_| JournalError::not_appended(4))?;
            self.poisoned = true;
            self.file
                .set_len(length)
                .map_err(journal_io_may_have_appended)?;
            self.file
                .seek(SeekFrom::Start(length))
                .map_err(journal_io_may_have_appended)?;
            self.file.flush().map_err(journal_io_may_have_appended)?;
            self.file.sync_all().map_err(journal_io_may_have_appended)?;
            self.byte_length = valid_bytes;
            self.torn_prefix = None;
            self.tail_issue = None;
            self.generation = self.generation.saturating_add(1);
            authorization.generation = self.generation;
            self.poisoned = false;
        }
        self.append(record)?;
        authorization.generation = self.generation;
        Ok(())
    }
}

impl JournalStore for FileJournal {
    fn begin(&mut self, plan: PlanId, steps: &[JournalStep]) -> Result<(), JournalError> {
        if self.poisoned {
            return Err(JournalError::may_have_appended(8));
        }
        if !self.records.is_empty() {
            return Err(JournalError::not_appended(1));
        }
        self.append(JournalRecord::Intent {
            plan,
            steps: steps.into(),
        })?;
        #[cfg(test)]
        super::failpoint::hit("staged-intent-synced");
        self.promote_candidate()?;
        #[cfg(test)]
        super::failpoint::hit("active-intent-promoted");
        Ok(())
    }

    fn prepared(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.require_active()?;
        self.append(JournalRecord::Prepared { step, direction })
    }

    fn completed(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.require_active()?;
        self.append(JournalRecord::Completed { step, direction })
    }

    fn not_applied(
        &mut self,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.require_active()?;
        self.append(JournalRecord::NotApplied { step, direction })
    }

    fn terminal(&mut self, terminal: JournalTerminal) -> Result<(), JournalError> {
        self.require_active()?;
        self.append(JournalRecord::Terminal(terminal))
    }
}

impl AuthorizedJournal for FileJournal {
    fn authorized_snapshot(&mut self) -> Result<JournalSnapshot, JournalError> {
        self.require_active()?;
        Ok(JournalSnapshot {
            records: self.records.clone().into_boxed_slice(),
            authorization: JournalAuthorization {
                identity: self.identity,
                generation: self.generation,
            },
        })
    }

    fn authorized_prepared(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.authorized_append(authorization, JournalRecord::Prepared { step, direction })
    }

    fn authorized_completed(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.authorized_append(authorization, JournalRecord::Completed { step, direction })
    }

    fn authorized_not_applied(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.authorized_append(authorization, JournalRecord::NotApplied { step, direction })
    }

    fn authorized_terminal(
        &mut self,
        authorization: &mut JournalAuthorization,
        terminal: JournalTerminal,
    ) -> Result<(), JournalError> {
        self.authorized_append(authorization, JournalRecord::Terminal(terminal))
    }
}

fn journal_io_may_have_appended(error: io::Error) -> JournalError {
    JournalError::may_have_appended(
        error
            .raw_os_error()
            .and_then(|code| u32::try_from(code).ok())
            .unwrap_or(6),
    )
}

fn existing_evidence_error(
    path: PathBuf,
    file: File,
    byte_len: u64,
    failure: JournalOpenFailure,
) -> ExistingJournalOpenError {
    ExistingJournalOpenError {
        path: path.clone(),
        failure,
        evidence: Some(Box::new(RecoveryJournalEvidence {
            path,
            file,
            byte_len,
            failure,
        })),
    }
}

#[cfg(windows)]
fn promote_file_noreplace(
    file: &File,
    root: &File,
    _candidate_path: &Path,
    _active_path: &Path,
    active_leaf: &str,
) -> io::Result<()> {
    let active_leaf = active_leaf.encode_utf16().collect::<Vec<_>>();
    super::windows_native::rename_noreplace(file, root, &active_leaf)
}

#[cfg(not(windows))]
fn promote_file_noreplace(
    _file: &File,
    _root: &File,
    _candidate_path: &Path,
    _active_path: &Path,
    _active_leaf: &str,
) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "candidate promotion is available only on Windows",
    ))
}

fn next_file_identity() -> u64 {
    static NEXT_IDENTITY: AtomicU64 = AtomicU64::new(1);
    NEXT_IDENTITY.fetch_add(1, Ordering::Relaxed)
}

#[cfg(windows)]
fn mark_retained_file_delete(file: &File) -> io::Result<()> {
    super::windows_native::mark_file_delete(file)
}

#[cfg(not(windows))]
fn mark_retained_file_delete(_file: &File) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "retained-handle deletion is available only on Windows",
    ))
}

fn combined_identity(root_identity: u64) -> u64 {
    next_file_identity() ^ root_identity.rotate_left(29)
}

fn validate_root_components(path: &Path) -> Result<(), FileJournalError> {
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        if !current.is_absolute() {
            continue;
        }
        let metadata = std::fs::symlink_metadata(&current)?;
        if metadata.file_type().is_symlink() || metadata_is_reparse(&metadata) {
            return Err(FileJournalError {
                kind: FileJournalErrorKind::InvalidRoot,
                os_code: None,
            });
        }
    }
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.is_dir() {
        return Err(FileJournalError {
            kind: FileJournalErrorKind::InvalidRoot,
            os_code: None,
        });
    }
    Ok(())
}

fn reject_final_link(path: &Path) -> Result<(), FileJournalError> {
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || metadata_is_reparse(&metadata) {
        return Err(FileJournalError {
            kind: FileJournalErrorKind::InvalidFileType,
            os_code: None,
        });
    }
    Ok(())
}

#[cfg(windows)]
fn open_root(path: &Path) -> io::Result<File> {
    super::windows_native::NativeParent::open_path_without_delete_share(path)
        .map(|parent| parent.into_file())
}

#[cfg(not(windows))]
fn open_root(path: &Path) -> io::Result<File> {
    File::open(path)
}

#[cfg(windows)]
fn open_create_new(root: &File, _path: &Path, leaf: &str) -> io::Result<File> {
    super::windows_native::create_file_relative_exclusive(root, leaf)
}

#[cfg(not(windows))]
fn open_create_new(_root: &File, path: &Path, _leaf: &str) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .append(true)
        .create_new(true)
        .open(path)
}

#[cfg(windows)]
fn open_existing(root: &File, _path: &Path, leaf: &str) -> io::Result<File> {
    super::windows_native::open_file_relative_exclusive(root, leaf)
}

#[cfg(not(windows))]
fn open_existing(_root: &File, path: &Path, _leaf: &str) -> io::Result<File> {
    OpenOptions::new().read(true).append(true).open(path)
}

fn validate_file_type(file: &File) -> Result<(), FileJournalError> {
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata_is_reparse(&metadata) {
        return Err(FileJournalError {
            kind: FileJournalErrorKind::InvalidFileType,
            os_code: None,
        });
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod unix_fault_tests {
    use std::fs::{self, OpenOptions};
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> io::Result<Self> {
            static NEXT_ID: AtomicU64 = AtomicU64::new(1);
            let path = std::env::temp_dir().join(format!(
                "darkrenamer-file-journal-{}-{}",
                std::process::id(),
                NEXT_ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path)?;
            Ok(Self(path))
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn write_started_error_poisons_journal_and_forbids_cleanup_or_more_appends()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = TestDirectory::new()?;
        let root = JournalRoot::open(&directory.0)?;
        let mut journal = FileJournal::create_new(&root, "active.drj")?;
        journal.file = OpenOptions::new().write(true).open("/dev/full")?;

        let first = journal
            .terminal(JournalTerminal::Committed)
            .err()
            .ok_or_else(|| io::Error::other("/dev/full unexpectedly accepted a frame"))?;
        let second = journal
            .terminal(JournalTerminal::Committed)
            .err()
            .ok_or_else(|| io::Error::other("poisoned journal accepted another frame"))?;

        assert_eq!(
            first.certainty,
            super::super::AppendCertainty::MayHaveAppended
        );
        assert_eq!(second, JournalError::may_have_appended(8));
        assert_eq!(journal.records(), &[]);
        assert!(matches!(
            journal.mark_delete_if_safe(),
            Err(FileJournalError {
                kind: FileJournalErrorKind::UnsafeCleanupState,
                ..
            })
        ));
        Ok(())
    }
}

#[cfg(windows)]
fn metadata_is_reparse(metadata: &std::fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
const fn metadata_is_reparse(_metadata: &std::fs::Metadata) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_step() -> JournalStep {
        JournalStep::new(
            EntryId::new(0),
            LegacyText::from("C:\\a"),
            LegacyText::from("C:\\b"),
            EntryIdentity::new(1, 2),
            EntryIdentity::new(1, 1),
            EntryIdentity::new(1, 1),
            TemporaryPhase::None,
        )
    }

    #[test]
    fn authorized_append_rejects_generation_drift() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let root = JournalRoot::open(directory.path())?;
        let mut journal = FileJournal::create_new(&root, "authorization.drj")?;
        journal.begin(PlanId::from_fingerprint(1), &[test_step()])?;
        let snapshot = journal.authorized_snapshot()?;
        let (_records, mut authorization) = snapshot.into_parts();
        journal.prepared(0, JournalDirection::Forward)?;
        assert!(
            journal
                .authorized_completed(&mut authorization, 0, JournalDirection::Forward,)
                .is_err()
        );
        Ok(())
    }

    #[test]
    fn authorization_from_another_file_capability_is_rejected()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let root = JournalRoot::open(directory.path())?;
        let mut first = FileJournal::create_new(&root, "first.drj")?;
        let mut second = FileJournal::create_new(&root, "second.drj")?;
        first.begin(PlanId::from_fingerprint(1), &[test_step()])?;
        second.begin(PlanId::from_fingerprint(1), &[test_step()])?;
        let snapshot = first.authorized_snapshot()?;
        let (_records, mut authorization) = snapshot.into_parts();

        assert!(
            second
                .authorized_prepared(&mut authorization, 0, JournalDirection::Forward,)
                .is_err()
        );
        assert_eq!(second.records().len(), 1);
        Ok(())
    }
}
