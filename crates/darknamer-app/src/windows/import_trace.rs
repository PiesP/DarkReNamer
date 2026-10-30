//! Fixed-size, latest-operation timing evidence for a Paths import.
//!
//! Each value is a copied QPC scalar. Recording is confined to the owning UI
//! thread except for publication ticks, which are copied after joining the
//! exact worker. A zero event is unobserved, never an elapsed-time estimate.

use windows_sys::Win32::Foundation::LRESULT;

pub(super) const ACCEPTED_IMPORT_START: usize = 0;
pub(super) const READ_RESULT_PUBLISHED: usize = 1;
pub(super) const READ_OWNER_ACCEPTED: usize = 2;
pub(super) const READING_STATUS_QUEUED: usize = 3;
pub(super) const READING_STATUS_COMMITTED: usize = 4;
pub(super) const READING_STATUS_VISIBLE: usize = 5;
pub(super) const CANCEL_READY: usize = 6;
pub(super) const ADMISSION_STARTED: usize = 7;
pub(super) const ADMISSION_RESULT_PUBLISHED: usize = 8;
pub(super) const ADMISSION_OWNER_ACCEPTED: usize = 9;
pub(super) const MODEL_COMMITTED: usize = 10;
pub(super) const NATIVE_SYNC_STARTED: usize = 11;
pub(super) const NATIVE_SYNC_COMPLETED: usize = 12;
pub(super) const IMPORT_COMMAND_READY: usize = 13;
pub(super) const ICONS_SETTLED: usize = 14;
pub(super) const READING_STATUS_ATTEMPT_STARTED: usize = 15;
const EVENT_COUNT: usize = 16;

pub(super) const STATUS_QUEUED: u32 = 1;
pub(super) const STATUS_COMMITTED: u32 = 2;
pub(super) const STATUS_VISIBLE: u32 = 4;
pub(super) const STATUS_COALESCED: u32 = 8;
pub(super) const ADMISSION_ACCEPTED: u32 = 16;
pub(super) const NATIVE_SYNCHRONIZED: u32 = 32;
pub(super) const COMMAND_ENABLED: u32 = 64;
pub(super) const ICONS_OBSERVED_SETTLED: u32 = 128;

/// Its read-only selectors start at 40; split values are low word first.
pub(super) struct ImportCompletionTrace {
    revision: u64,
    generation: u64,
    session_id: u64,
    initial_model_revision: u64,
    final_model_revision: u64,
    flags: u32,
    events: [u64; EVENT_COUNT],
    status_attempt_pending: bool,
    status_attempt_uncertain: bool,
    native_sync_armed: bool,
    valid: bool,
}

impl ImportCompletionTrace {
    pub(super) const fn new(frequency: u64) -> Self {
        Self {
            revision: 0,
            generation: 0,
            session_id: 0,
            initial_model_revision: 0,
            final_model_revision: 0,
            flags: 0,
            events: [0; EVENT_COUNT],
            status_attempt_pending: false,
            status_attempt_uncertain: false,
            native_sync_armed: false,
            valid: frequency > 0,
        }
    }

    pub(super) fn begin(&mut self, session_id: u64, model_revision: u64, tick: Option<u64>) {
        let Some((generation, revision, tick)) = self
            .generation
            .checked_add(1)
            .zip(self.revision.checked_add(1))
            .zip(tick)
            .map(|((generation, revision), tick)| (generation, revision, tick))
            .filter(|(_, _, tick)| self.valid && session_id != 0 && *tick != 0)
        else {
            self.valid = false;
            return;
        };
        self.generation = generation;
        self.revision = revision;
        self.session_id = session_id;
        self.initial_model_revision = model_revision;
        self.final_model_revision = 0;
        self.flags = 0;
        self.events = [0; EVENT_COUNT];
        self.status_attempt_pending = false;
        self.status_attempt_uncertain = false;
        self.native_sync_armed = false;
        self.events[ACCEPTED_IMPORT_START] = tick;
    }

    pub(super) fn matches(&self, session_id: u64, model_revision: u64) -> bool {
        self.valid
            && self.events[ACCEPTED_IMPORT_START] != 0
            && self.session_id == session_id
            && self.initial_model_revision == model_revision
    }

    pub(super) fn generation(&self) -> u64 {
        self.generation
    }

    pub(super) fn session_id(&self) -> u64 {
        self.session_id
    }

    pub(super) fn start_revision(&self) -> u64 {
        self.initial_model_revision
    }

    pub(super) fn final_revision(&self) -> u64 {
        self.final_model_revision
    }

    pub(super) fn event(&self, index: usize) -> u64 {
        self.events.get(index).copied().unwrap_or(0)
    }

    pub(super) fn arm_native_sync(&mut self, session_id: u64, model_revision: u64) {
        self.native_sync_armed = self.matches(session_id, model_revision)
            && self.events[MODEL_COMMITTED] != 0
            && self.events[NATIVE_SYNC_STARTED] == 0;
    }

    pub(super) fn native_sync_armed(&self) -> bool {
        self.native_sync_armed
    }

    pub(super) fn disarm_native_sync(&mut self) {
        self.native_sync_armed = false;
    }

    #[cfg(test)]
    pub(super) fn flags(&self) -> u32 {
        self.flags
    }

    pub(super) fn invalidate(&mut self) {
        self.valid = false;
    }

    pub(super) fn record(
        &mut self,
        session_id: u64,
        model_revision: u64,
        event: usize,
        tick: Option<u64>,
    ) -> bool {
        if !self.matches(session_id, model_revision) || event == ACCEPTED_IMPORT_START {
            return false;
        }
        if event == READING_STATUS_COMMITTED && self.flags & STATUS_COALESCED != 0 {
            return false;
        }
        let Some(slot) = self.events.get(event).copied() else {
            self.valid = false;
            return false;
        };
        if slot != 0 {
            // Late timer or icon wake may repeat an already observed state.
            if matches!(
                event,
                READING_STATUS_COMMITTED | READING_STATUS_VISIBLE | CANCEL_READY | ICONS_SETTLED
            ) {
                return false;
            }
            self.valid = false;
            return false;
        }
        let dependency = match event {
            READ_RESULT_PUBLISHED | READING_STATUS_QUEUED => ACCEPTED_IMPORT_START,
            READ_OWNER_ACCEPTED => READ_RESULT_PUBLISHED,
            READING_STATUS_COMMITTED => READING_STATUS_ATTEMPT_STARTED,
            READING_STATUS_VISIBLE => READING_STATUS_COMMITTED,
            CANCEL_READY => READING_STATUS_QUEUED,
            ADMISSION_STARTED => READ_OWNER_ACCEPTED,
            ADMISSION_RESULT_PUBLISHED => ADMISSION_STARTED,
            ADMISSION_OWNER_ACCEPTED => ADMISSION_RESULT_PUBLISHED,
            MODEL_COMMITTED => ADMISSION_OWNER_ACCEPTED,
            NATIVE_SYNC_STARTED => MODEL_COMMITTED,
            NATIVE_SYNC_COMPLETED => NATIVE_SYNC_STARTED,
            IMPORT_COMMAND_READY => NATIVE_SYNC_COMPLETED,
            ICONS_SETTLED => IMPORT_COMMAND_READY,
            READING_STATUS_ATTEMPT_STARTED => READING_STATUS_QUEUED,
            _ => {
                self.valid = false;
                return false;
            }
        };
        let Some(tick) = tick.filter(|tick| *tick != 0 && *tick > self.events[dependency]) else {
            self.valid = false;
            return false;
        };
        if self.events[dependency] == 0 || self.revision == u64::MAX {
            self.valid = false;
            return false;
        }
        self.events[event] = tick;
        self.revision += 1;
        self.flags |= match event {
            READING_STATUS_QUEUED => STATUS_QUEUED,
            READING_STATUS_COMMITTED => STATUS_COMMITTED,
            READING_STATUS_VISIBLE => STATUS_VISIBLE,
            IMPORT_COMMAND_READY => COMMAND_ENABLED,
            ICONS_SETTLED => ICONS_OBSERVED_SETTLED,
            _ => 0,
        };
        true
    }

    pub(super) fn mark_status_coalesced(&mut self, session_id: u64, model_revision: u64) {
        if self.matches(session_id, model_revision)
            && self.flags & STATUS_QUEUED != 0
            && self.flags & (STATUS_COMMITTED | STATUS_COALESCED) == 0
            && self.events[READING_STATUS_ATTEMPT_STARTED] == 0
            && !self.status_attempt_pending
            && !self.status_attempt_uncertain
        {
            self.flags |= STATUS_COALESCED;
            self.bump_revision();
        }
    }

    pub(super) fn begin_status_attempt(
        &mut self,
        session_id: u64,
        model_revision: u64,
        tick: Option<u64>,
    ) {
        if self.matches(session_id, model_revision)
            && self.flags & STATUS_QUEUED != 0
            && self.flags & (STATUS_COMMITTED | STATUS_COALESCED) == 0
        {
            if self.events[READING_STATUS_ATTEMPT_STARTED] == 0 {
                self.record(
                    session_id,
                    model_revision,
                    READING_STATUS_ATTEMPT_STARTED,
                    tick,
                );
            }
            self.status_attempt_pending = true;
            self.bump_revision();
        }
    }

    pub(super) fn end_status_attempt(
        &mut self,
        session_id: u64,
        model_revision: u64,
        confirmed_native_text: bool,
        write_succeeded: bool,
    ) {
        if self.matches(session_id, model_revision) && self.status_attempt_pending {
            self.status_attempt_pending = false;
            if write_succeeded && !confirmed_native_text {
                self.status_attempt_uncertain = true;
            }
            self.bump_revision();
        }
    }

    pub(super) fn mark_admission_accepted(&mut self, session_id: u64, model_revision: u64) {
        if self.matches(session_id, model_revision)
            && self.events[ADMISSION_OWNER_ACCEPTED] != 0
            && self.flags & ADMISSION_ACCEPTED == 0
        {
            self.flags |= ADMISSION_ACCEPTED;
            self.bump_revision();
        }
    }

    pub(super) fn mark_native_synchronized(&mut self, session_id: u64, model_revision: u64) {
        if self.matches(session_id, model_revision)
            && self.events[NATIVE_SYNC_COMPLETED] != 0
            && self.flags & NATIVE_SYNCHRONIZED == 0
        {
            self.flags |= NATIVE_SYNCHRONIZED;
            self.bump_revision();
        }
    }

    pub(super) fn set_final_model_revision(
        &mut self,
        session_id: u64,
        model_revision: u64,
        final_revision: u64,
    ) {
        if self.matches(session_id, model_revision)
            && self.events[MODEL_COMMITTED] != 0
            && self.final_model_revision == 0
        {
            self.final_model_revision = final_revision;
            self.bump_revision();
        }
    }

    fn bump_revision(&mut self) {
        if let Some(next) = self.revision.checked_add(1) {
            self.revision = next;
        } else {
            self.valid = false;
        }
    }

    pub(super) fn selector_value(&self, selector: usize) -> Option<LRESULT> {
        if !self.valid {
            return None;
        }
        let value = match selector {
            40 => 1,
            41..=50 => {
                let value = match selector {
                    41 | 42 => self.revision,
                    43 | 44 => self.generation,
                    45 | 46 => self.session_id,
                    47 | 48 => self.initial_model_revision,
                    _ => self.final_model_revision,
                };
                split(value, selector & 1 == 0)
            }
            51 => self.flags as LRESULT,
            52..=83 => {
                let index = (selector - 52) / 2;
                split(self.events[index], selector & 1 == 1)
            }
            _ => return None,
        };
        Some(value)
    }
}

fn split(value: u64, high: bool) -> LRESULT {
    if high {
        (value >> 32) as u32 as LRESULT
    } else {
        value as u32 as LRESULT
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_rejects_stale_and_out_of_order_events_but_allows_overlapping_branches() {
        let mut trace = ImportCompletionTrace::new(10_000_000);
        trace.begin(7, 3, Some(100));
        assert!(!trace.record(8, 3, READ_RESULT_PUBLISHED, Some(120)));
        assert!(!trace.record(7, 4, READ_RESULT_PUBLISHED, Some(120)));
        assert_eq!(trace.selector_value(41), Some(1));
        assert!(trace.record(7, 3, READ_RESULT_PUBLISHED, Some(140)));
        assert!(trace.record(7, 3, READING_STATUS_QUEUED, Some(150)));
        assert!(trace.record(7, 3, READ_OWNER_ACCEPTED, Some(170)));
        trace.begin_status_attempt(7, 3, Some(175));
        assert!(trace.record(7, 3, READING_STATUS_COMMITTED, Some(180)));
        assert!(trace.record(7, 3, READING_STATUS_VISIBLE, Some(190)));
        assert!(trace.record(7, 3, CANCEL_READY, Some(160)));
        assert_eq!(
            trace.flags(),
            STATUS_QUEUED | STATUS_COMMITTED | STATUS_VISIBLE
        );
        assert_eq!(trace.event(CANCEL_READY), 160);
    }

    #[test]
    fn trace_requires_publication_and_sync_before_ready_and_preserves_coalescing() {
        let mut trace = ImportCompletionTrace::new(10_000_000);
        trace.begin(5, 0, Some(10));
        assert!(trace.record(5, 0, READING_STATUS_QUEUED, Some(12)));
        trace.mark_status_coalesced(5, 0);
        assert_eq!(trace.flags(), STATUS_QUEUED | STATUS_COALESCED);
        trace.mark_status_coalesced(5, 0);
        assert_eq!(trace.flags(), STATUS_QUEUED | STATUS_COALESCED);
        assert!(trace.record(5, 0, CANCEL_READY, Some(16)));
        assert!(trace.record(5, 0, READ_RESULT_PUBLISHED, Some(20)));
        assert!(trace.record(5, 0, READ_OWNER_ACCEPTED, Some(24)));
        assert!(trace.record(5, 0, ADMISSION_STARTED, Some(30)));
        assert!(trace.record(5, 0, ADMISSION_RESULT_PUBLISHED, Some(40)));
        assert!(trace.record(5, 0, ADMISSION_OWNER_ACCEPTED, Some(50)));
        trace.mark_admission_accepted(5, 0);
        assert!(trace.record(5, 0, MODEL_COMMITTED, Some(60)));
        trace.set_final_model_revision(5, 0, 1);
        assert!(trace.record(5, 0, NATIVE_SYNC_STARTED, Some(70)));
        assert!(trace.record(5, 0, NATIVE_SYNC_COMPLETED, Some(80)));
        trace.mark_native_synchronized(5, 0);
        assert!(trace.record(5, 0, IMPORT_COMMAND_READY, Some(90)));
        assert!(trace.record(5, 0, ICONS_SETTLED, Some(100)));
        assert_eq!(
            trace.selector_value(51),
            Some(
                STATUS_QUEUED as LRESULT
                    | STATUS_COALESCED as LRESULT
                    | ADMISSION_ACCEPTED as LRESULT
                    | NATIVE_SYNCHRONIZED as LRESULT
                    | COMMAND_ENABLED as LRESULT
                    | ICONS_OBSERVED_SETTLED as LRESULT
            )
        );
        assert_eq!(trace.selector_value(49), Some(1));
        assert_eq!(trace.selector_value(52), Some(10));
        assert_eq!(trace.selector_value(80), Some(100));
        assert_eq!(trace.selector_value(81), Some(0));
        trace.begin(6, 1, Some(110));
        assert_eq!(trace.generation(), 2);
        assert_eq!(trace.session_id(), 6);
        assert_eq!(trace.selector_value(54), Some(0));
    }

    #[test]
    fn unavailable_clock_or_duplicate_completion_invalidates_trace() {
        let mut unavailable = ImportCompletionTrace::new(0);
        unavailable.begin(1, 0, Some(1));
        assert_eq!(unavailable.selector_value(40), None);
        let mut trace = ImportCompletionTrace::new(10);
        trace.begin(1, 0, Some(1));
        assert!(trace.record(1, 0, READ_RESULT_PUBLISHED, Some(2)));
        assert!(!trace.record(1, 0, READ_RESULT_PUBLISHED, Some(3)));
        assert_eq!(trace.selector_value(41), None);
        let mut trace = ImportCompletionTrace::new(10);
        trace.begin(1, 0, Some(1));
        assert!(!trace.record(1, 0, IMPORT_COMMAND_READY, Some(2)));
        assert_eq!(trace.selector_value(40), None);
    }

    #[test]
    fn ambiguous_native_write_never_becomes_a_coalesced_status_claim() {
        let mut trace = ImportCompletionTrace::new(10);
        trace.begin(1, 0, Some(1));
        assert!(trace.record(1, 0, READING_STATUS_QUEUED, Some(2)));
        trace.begin_status_attempt(1, 0, Some(3));
        trace.mark_status_coalesced(1, 0);
        assert_eq!(trace.flags() & STATUS_COALESCED, 0);
        trace.end_status_attempt(1, 0, false, true);
        trace.mark_status_coalesced(1, 0);
        assert_eq!(trace.flags() & STATUS_COALESCED, 0);
        assert_eq!(trace.event(READING_STATUS_COMMITTED), 0);
        assert!(trace.record(1, 0, CANCEL_READY, Some(4)));
        assert_eq!(trace.selector_value(82), Some(3));
        assert_eq!(trace.selector_value(83), Some(0));
    }

    #[test]
    fn status_attempt_brackets_cancel_during_reentrant_native_write() {
        let mut trace = ImportCompletionTrace::new(10);
        trace.begin(9, 0, Some(100));
        assert!(trace.record(9, 0, READING_STATUS_QUEUED, Some(110)));
        trace.begin_status_attempt(9, 0, Some(120));
        assert!(trace.record(9, 0, CANCEL_READY, Some(130)));
        trace.end_status_attempt(9, 0, true, true);
        assert!(trace.record(9, 0, READING_STATUS_COMMITTED, Some(140)));
        assert!(trace.record(9, 0, READING_STATUS_VISIBLE, Some(150)));
        assert_eq!(trace.event(READING_STATUS_ATTEMPT_STARTED), 120);
        assert!(trace.event(READING_STATUS_ATTEMPT_STARTED) < trace.event(CANCEL_READY));
        assert!(trace.event(CANCEL_READY) < trace.event(READING_STATUS_VISIBLE));
    }
}
