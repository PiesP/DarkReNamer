use std::sync::{Mutex, MutexGuard};

use crate::rename::{ExecutionPhase, ExecutionProgress};

/// One coherent publication and its coalesced notification handoff.
pub(crate) struct ApplyProgress {
    state: Mutex<ProgressState>,
}

struct ProgressState {
    snapshot: ExecutionProgress,
    wake_pending: bool,
}

impl ApplyProgress {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(ProgressState {
                snapshot: ExecutionProgress {
                    phase: ExecutionPhase::Ready,
                    completed: 0,
                    total: 0,
                },
                wake_pending: false,
            }),
        }
    }

    /// Returns whether the caller must post a wake, after releasing the lock.
    pub(crate) fn publish(&self, snapshot: ExecutionProgress) -> bool {
        let mut state = self.lock_state();
        state.snapshot = snapshot;
        !std::mem::replace(&mut state.wake_pending, true)
    }

    pub(crate) fn snapshot(&self) -> ExecutionProgress {
        self.lock_state().snapshot
    }

    /// A concurrent publication is either included here or requests a new wake.
    pub(crate) fn take_update(&self) -> ExecutionProgress {
        let mut state = self.lock_state();
        state.wake_pending = false;
        state.snapshot
    }

    pub(crate) fn is_finishing(&self) -> bool {
        matches!(
            self.snapshot().phase,
            ExecutionPhase::Rollback | ExecutionPhase::Finalizing | ExecutionPhase::Terminal
        )
    }

    fn lock_state(&self) -> MutexGuard<'_, ProgressState> {
        // The lock only protects copied presentation data and notification state;
        // no callbacks, I/O or transaction authority enter this critical section.
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Barrier};
    use std::thread;

    use super::*;
    use crate::{CancelControlState, WorkerActivity, cancel_control_state};

    const TRANSITIONS: [ExecutionProgress; 5] = [
        ExecutionProgress {
            phase: ExecutionPhase::Ready,
            completed: 0,
            total: usize::MAX,
        },
        ExecutionProgress {
            phase: ExecutionPhase::Forward,
            completed: usize::MAX - 1,
            total: usize::MAX,
        },
        ExecutionProgress {
            phase: ExecutionPhase::Rollback,
            completed: 1,
            total: 3,
        },
        ExecutionProgress {
            phase: ExecutionPhase::Finalizing,
            completed: usize::MAX,
            total: usize::MAX,
        },
        ExecutionProgress {
            phase: ExecutionPhase::Terminal,
            completed: 3,
            total: 3,
        },
    ];

    #[test]
    fn phase_transitions_preserve_counts_and_cancel_control_state() {
        let progress = ApplyProgress::new();
        assert_eq!(
            progress.snapshot(),
            ExecutionProgress {
                phase: ExecutionPhase::Ready,
                completed: 0,
                total: 0,
            }
        );
        for (index, snapshot) in TRANSITIONS.into_iter().enumerate() {
            assert!(progress.publish(snapshot));
            assert_eq!(progress.snapshot(), snapshot);
            let finishing = index >= 2;
            assert_eq!(progress.is_finishing(), finishing);
            for cancellation_requested in [false, true] {
                let activity = WorkerActivity {
                    apply: true,
                    apply_finishing: progress.is_finishing(),
                    cancellation_requested,
                    ..WorkerActivity::default()
                };
                assert_eq!(
                    cancel_control_state(activity),
                    if finishing {
                        CancelControlState::Unavailable
                    } else if cancellation_requested {
                        CancelControlState::Requested
                    } else {
                        CancelControlState::Enabled
                    }
                );
            }
            assert_eq!(progress.take_update(), snapshot);
        }
    }

    #[test]
    fn coalesced_publications_are_read_without_consuming_wakes_from_status_reads() {
        let progress = ApplyProgress::new();
        assert!(progress.publish(TRANSITIONS[0]));
        assert_eq!(progress.snapshot(), TRANSITIONS[0]);
        assert!(!progress.is_finishing());
        assert!(!progress.publish(TRANSITIONS[1]));
        assert!(!progress.publish(TRANSITIONS[2]));
        assert_eq!(progress.take_update(), TRANSITIONS[2]);
        assert!(progress.publish(TRANSITIONS[3]));
        assert!(!progress.publish(TRANSITIONS[4]));
        assert_eq!(progress.take_update(), TRANSITIONS[4]);
    }

    #[test]
    fn concurrent_reads_only_observe_whole_publications() -> Result<(), &'static str> {
        let progress = Arc::new(ApplyProgress::new());
        assert!(progress.publish(TRANSITIONS[0]));
        let start = Arc::new(Barrier::new(2));
        let writer_progress = Arc::clone(&progress);
        let writer_start = Arc::clone(&start);
        let writer = thread::spawn(move || {
            writer_start.wait();
            for _ in 0..10_000 {
                for snapshot in TRANSITIONS {
                    let _wake = writer_progress.publish(snapshot);
                }
            }
        });
        start.wait();
        for _ in 0..50_000 {
            assert!(TRANSITIONS.contains(&progress.snapshot()));
            assert!(TRANSITIONS.contains(&progress.take_update()));
        }
        writer.join().map_err(|_| "progress writer panicked")?;
        assert_eq!(progress.snapshot(), TRANSITIONS[4]);
        Ok(())
    }

    #[test]
    fn publication_racing_with_acknowledgement_is_observed_or_gets_a_new_wake()
    -> Result<(), &'static str> {
        let progress = Arc::new(ApplyProgress::new());
        let start = Arc::new(Barrier::new(2));
        for _ in 0..1_000 {
            assert!(progress.publish(TRANSITIONS[1]));
            let writer_progress = Arc::clone(&progress);
            let writer_start = Arc::clone(&start);
            let writer = thread::spawn(move || {
                writer_start.wait();
                writer_progress.publish(TRANSITIONS[4])
            });
            start.wait();
            let observed = progress.take_update();
            let new_wake = writer.join().map_err(|_| "progress writer panicked")?;
            assert!(
                observed == TRANSITIONS[4] || new_wake,
                "the terminal publication must be observed or arrange another wake"
            );
            assert_eq!(progress.take_update(), TRANSITIONS[4]);
        }
        Ok(())
    }
}
