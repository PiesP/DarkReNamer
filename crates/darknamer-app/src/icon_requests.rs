//! Bounded, nonblocking state for owned Shell-icon requests.
//!
//! The caller derives canonical icon-class keys before submission and owns the
//! worker, wake mechanism, completed-icon cache, and native delivery checks.

use std::collections::VecDeque;

/// Maximum unique requests across queued, in-flight, and undrained results.
pub const MAX_PENDING_ICON_REQUESTS: usize = 64;

/// The image-list bootstrap uses the same capacity as ordinary icon classes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RequestKey<K> {
    Bootstrap,
    Class(K),
}

/// Identifies one dispatch within an application session and generation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RequestToken {
    session: u64,
    generation: u64,
    serial: u64,
}

impl RequestToken {
    /// Session supplied by the application when it created this state.
    #[must_use]
    pub const fn session(self) -> u64 {
        self.session
    }

    /// Request generation current when this dispatch was admitted.
    #[must_use]
    pub const fn generation(self) -> u64 {
        self.generation
    }
}

/// Owned request copied to the single worker when dispatched.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Request<K> {
    pub token: RequestToken,
    pub key: RequestKey<K>,
}

/// Result held until the UI drains it; payload interpretation stays with the caller.
#[derive(Debug, Eq, PartialEq)]
pub struct Completion<K, R> {
    pub request: Request<K>,
    pub result: R,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SubmitDisposition {
    Queued,
    Coalesced,
    /// A key is held by an older in-flight generation; retry after it finishes.
    DeferredStaleInFlight,
    /// No overflow list is retained; a bounded UI demand scan can retry later.
    Saturated,
    IdentifierExhausted,
    Retired,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CompletionDisposition {
    Published,
    /// A matching in-flight call ended after generation change or retirement.
    Discarded,
    /// The token does not identify the current in-flight call.
    Unexpected,
}

/// Request slots only; this state does not own or observe the worker thread.
pub struct IconRequests<K, R> {
    session: u64,
    generation: u64,
    next_serial: u64,
    queued: VecDeque<Request<K>>,
    in_flight: Option<Request<K>>,
    completed: VecDeque<Completion<K, R>>,
    retired: bool,
}

impl<K: Clone + Eq, R> IconRequests<K, R> {
    /// The caller must supply a session value that is not reused while old work
    /// can still report a result. No worker is started by this constructor.
    #[must_use]
    pub fn new(session: u64) -> Self {
        Self {
            session,
            generation: 0,
            next_serial: 0,
            queued: VecDeque::new(),
            in_flight: None,
            completed: VecDeque::new(),
            retired: false,
        }
    }

    /// Submit one owned canonical key without waiting or storing overflow demand.
    pub fn submit(&mut self, key: RequestKey<K>) -> SubmitDisposition {
        if self.retired {
            return SubmitDisposition::Retired;
        }
        if let Some(in_flight) = &self.in_flight
            && in_flight.key == key
        {
            return if in_flight.token.generation == self.generation {
                SubmitDisposition::Coalesced
            } else {
                SubmitDisposition::DeferredStaleInFlight
            };
        }
        if self.queued.iter().any(|request| request.key == key)
            || self
                .completed
                .iter()
                .any(|completion| completion.request.key == key)
        {
            return SubmitDisposition::Coalesced;
        }
        if self.pending_count() == MAX_PENDING_ICON_REQUESTS {
            return SubmitDisposition::Saturated;
        }
        let Some(serial) = self.next_serial.checked_add(1) else {
            return SubmitDisposition::IdentifierExhausted;
        };
        self.next_serial = serial;
        self.queued.push_back(Request {
            token: RequestToken {
                session: self.session,
                generation: self.generation,
                serial,
            },
            key,
        });
        SubmitDisposition::Queued
    }

    /// Move one queued request into the sole in-flight slot.
    #[must_use]
    pub fn take_next(&mut self) -> Option<Request<K>> {
        if self.retired || self.in_flight.is_some() {
            return None;
        }
        let request = self.queued.pop_front()?;
        self.in_flight = Some(request.clone());
        Some(request)
    }

    /// Publish a matching result or discard it after invalidation.
    /// A published result does not prove that the worker thread has terminated.
    pub fn complete(&mut self, token: RequestToken, result: R) -> CompletionDisposition {
        if self.in_flight.as_ref().map(|request| request.token) != Some(token) {
            return CompletionDisposition::Unexpected;
        }
        let Some(request) = self.in_flight.take() else {
            return CompletionDisposition::Unexpected;
        };
        if self.retired || request.token.generation != self.generation {
            return CompletionDisposition::Discarded;
        }
        self.completed.push_back(Completion { request, result });
        CompletionDisposition::Published
    }

    /// Free one completion slot for the caller's bounded UI reconciliation.
    #[must_use]
    pub fn pop_completion(&mut self) -> Option<Completion<K, R>> {
        self.completed.pop_front()
    }

    /// Invalidate queued and undrained work while preserving the actual call's
    /// occupied slot until its matching result is reported.
    /// Returns false and retires on identifier exhaustion.
    pub fn advance_generation(&mut self) -> bool {
        if self.retired {
            return false;
        }
        let Some(next) = self.generation.checked_add(1) else {
            self.retire();
            return false;
        };
        self.generation = next;
        self.queued.clear();
        self.completed.clear();
        true
    }

    /// Stop admissions and delivery; an in-flight native call remains tracked.
    pub fn retire(&mut self) {
        self.retired = true;
        self.queued.clear();
        self.completed.clear();
    }

    /// Slots occupied by queued, in-flight, or undrained work.
    #[must_use]
    pub fn pending_count(&self) -> usize {
        self.queued.len() + self.in_flight_count() + self.completed.len()
    }

    #[must_use]
    pub fn in_flight_count(&self) -> usize {
        usize::from(self.in_flight.is_some())
    }

    #[must_use]
    pub fn completed_count(&self) -> usize {
        self.completed.len()
    }
}
