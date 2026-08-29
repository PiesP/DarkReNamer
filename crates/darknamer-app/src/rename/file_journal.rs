//! Durable file journal and strict portable codec.
//!
//! On Windows, open operations retain one exclusive, final-component
//! no-follow handle. Other hosts provide codec and retained-handle validation
//! only; their ordinary file open is not a production confinement claim.

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
/// Windows retains an exclusive no-follow directory handle. Child opens still
/// use a validated full path because this crate has no handle-relative create
/// adapter yet; production activation remains gated on closing that residual.
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
        })
    }

    /// Opens, exclusively retains, decodes, and resumes an existing journal.
    pub fn open_existing(root: &JournalRoot, leaf: &str) -> Result<Self, FileJournalError> {
        let path = root.child(leaf)?;
        reject_final_link(&path)?;
        let mut file = open_existing(&root.file, &path, leaf)?;
        validate_file_type(&file)?;
        let file_len = usize::try_from(file.metadata()?.len()).map_err(|_| FileJournalError {
            kind: FileJournalErrorKind::Codec(JournalCodecErrorKind::FileTooLarge),
            os_code: None,
        })?;
        if file_len > MAX_JOURNAL_FILE_BYTES {
            return Err(FileJournalError {
                kind: FileJournalErrorKind::Codec(JournalCodecErrorKind::FileTooLarge),
                os_code: None,
            });
        }
        let mut bytes = Vec::with_capacity(file_len);
        file.seek(SeekFrom::Start(0))?;
        Read::by_ref(&mut file)
            .take((MAX_JOURNAL_FILE_BYTES as u64).saturating_add(1))
            .read_to_end(&mut bytes)?;
        if bytes.len() > MAX_JOURNAL_FILE_BYTES {
            return Err(FileJournalError {
                kind: FileJournalErrorKind::Codec(JournalCodecErrorKind::FileTooLarge),
                os_code: None,
            });
        }
        let inspection = inspect_journal_records(&bytes)?;
        let records = inspection.records;
        file.seek(SeekFrom::End(0))?;
        let generation = u64::try_from(records.len()).map_err(|_| FileJournalError {
            kind: FileJournalErrorKind::Codec(JournalCodecErrorKind::TooManyFrames),
            os_code: None,
        })?;
        Ok(Self {
            path,
            _root: root.file.try_clone()?,
            _root_identity: root.identity,
            file,
            records,
            identity: combined_identity(root.identity),
            generation,
            next_sequence: generation,
            byte_length: bytes.len(),
            torn_prefix: inspection.issue.map(|_| inspection.valid_bytes),
            tail_issue: inspection.issue,
        })
    }

    /// Returns the retained path for operator display or explicit archival.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Returns decoded append-only records. Drop never deletes the journal.
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
    /// The adapter never removes or archives a file implicitly; an operator may
    /// act explicitly only after this reports true and the handle is closed.
    #[must_use]
    pub fn is_terminal(&self) -> bool {
        matches!(self.records.last(), Some(JournalRecord::Terminal(_)))
    }

    fn append(&mut self, record: JournalRecord) -> Result<(), JournalError> {
        if self.torn_prefix.is_some() {
            return Err(JournalError { code: 7 });
        }
        if self.records.len() >= MAX_JOURNAL_FRAMES {
            return Err(JournalError { code: 3 });
        }
        let frame_index = self.records.len();
        let frame = encode_frame(self.next_sequence, &record, frame_index)
            .map_err(|_| JournalError { code: 4 })?;
        if self.byte_length.saturating_add(frame.len()) > MAX_JOURNAL_FILE_BYTES {
            return Err(JournalError { code: 5 });
        }
        self.file.write_all(&frame).map_err(journal_io_error)?;
        self.file.flush().map_err(journal_io_error)?;
        self.file.sync_all().map_err(journal_io_error)?;
        self.byte_length += frame.len();
        self.records.push(record);
        self.generation = self.generation.saturating_add(1);
        self.next_sequence = self.next_sequence.saturating_add(1);
        Ok(())
    }

    fn authorized_append(
        &mut self,
        authorization: &mut JournalAuthorization,
        record: JournalRecord,
    ) -> Result<(), JournalError> {
        if authorization.identity != self.identity || authorization.generation != self.generation {
            return Err(JournalError { code: 2 });
        }
        if let Some(valid_bytes) = self.torn_prefix {
            let length = u64::try_from(valid_bytes).map_err(|_| JournalError { code: 4 })?;
            self.file.set_len(length).map_err(journal_io_error)?;
            self.file
                .seek(SeekFrom::Start(length))
                .map_err(journal_io_error)?;
            self.file.flush().map_err(journal_io_error)?;
            self.file.sync_all().map_err(journal_io_error)?;
            self.byte_length = valid_bytes;
            self.torn_prefix = None;
            self.tail_issue = None;
            self.generation = self.generation.saturating_add(1);
            authorization.generation = self.generation;
        }
        self.append(record)?;
        authorization.generation = self.generation;
        Ok(())
    }
}

impl JournalStore for FileJournal {
    fn begin(&mut self, plan: PlanId, steps: &[JournalStep]) -> Result<(), JournalError> {
        if !self.records.is_empty() {
            return Err(JournalError { code: 1 });
        }
        self.append(JournalRecord::Intent {
            plan,
            steps: steps.into(),
        })
    }

    fn prepared(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.append(JournalRecord::Prepared { step, direction })
    }

    fn completed(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.append(JournalRecord::Completed { step, direction })
    }

    fn not_applied(
        &mut self,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.append(JournalRecord::NotApplied { step, direction })
    }

    fn terminal(&mut self, terminal: JournalTerminal) -> Result<(), JournalError> {
        self.append(JournalRecord::Terminal(terminal))
    }
}

impl AuthorizedJournal for FileJournal {
    fn authorized_snapshot(&mut self) -> Result<JournalSnapshot, JournalError> {
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

fn journal_io_error(error: io::Error) -> JournalError {
    JournalError {
        code: error
            .raw_os_error()
            .and_then(|code| u32::try_from(code).ok())
            .unwrap_or(6),
    }
}

fn next_file_identity() -> u64 {
    static NEXT_IDENTITY: AtomicU64 = AtomicU64::new(1);
    NEXT_IDENTITY.fetch_add(1, Ordering::Relaxed)
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
    super::windows_native::NativeParent::open_path_exclusive(path).map(|parent| parent.into_file())
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
