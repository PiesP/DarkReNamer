#![cfg(windows)]
#![allow(
    unsafe_code,
    reason = "this Windows integration target exercises the audited native backend with OS handles"
)]

#[path = "support/windows_capabilities.rs"]
mod windows_capabilities;

use std::cell::RefCell;
use std::fs;
use std::io::Write;
use std::os::windows::ffi::OsStrExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use darknamer_app::rename::{
    BackendError, EntryId, EntryKind, ExecuteErrorKind, ExecutionOutcome, FileJournal,
    FileJournalErrorKind, JournalDirection, JournalError, JournalRoot, JournalStep, JournalStore,
    JournalTerminal, MemoryJournal, ModelRevision, MutationCertainty, PathKey, PathSnapshot,
    PlanId, PlanIssueKind, PlanRequest, RenameBackend, RenameExecutor, RenameIntent,
    RenameOperation, RenamePlanner, WindowsRenameBackend, apply_execution_report,
    build_plan_request, preflight_plan, process_is_elevated,
};
use darknamer_core::{LegacyList, LegacyListItem, LegacyText};

fn legacy_path(path: &std::path::Path) -> LegacyText {
    LegacyText::from_units(path.as_os_str().encode_wide().collect::<Vec<_>>())
}

fn intent(id: u32, source: &std::path::Path, parent: &std::path::Path, leaf: &str) -> RenameIntent {
    RenameIntent::new(
        EntryId::new(id),
        legacy_path(source),
        legacy_path(parent),
        leaf,
        EntryKind::File,
    )
}

fn directory_intent(
    id: u32,
    source: &std::path::Path,
    parent: &std::path::Path,
    leaf: &str,
) -> RenameIntent {
    RenameIntent::new(
        EntryId::new(id),
        legacy_path(source),
        legacy_path(parent),
        leaf,
        EntryKind::Directory,
    )
}

#[derive(Clone, Copy, Debug, Default)]
struct TimedCallMetric {
    calls: usize,
    elapsed: Duration,
}

impl TimedCallMetric {
    fn record(&mut self, elapsed: Duration) {
        self.calls += 1;
        self.elapsed += elapsed;
    }

    fn micros(self) -> u128 {
        self.elapsed.as_micros()
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct BackendMetrics {
    validate: TimedCallMetric,
    path_key: TimedCallMetric,
    observe: TimedCallMetric,
    descendant: TimedCallMetric,
    nonce: TimedCallMetric,
    rename: TimedCallMetric,
}

// Per-call `Instant` reads and metric updates add observer overhead. These values are
// diagnostic only; compare timings only between runs using this same instrumentation.
struct TimedBackend<B> {
    inner: B,
    metrics: RefCell<BackendMetrics>,
}

impl<B> TimedBackend<B> {
    fn new(inner: B) -> Self {
        Self {
            inner,
            metrics: RefCell::new(BackendMetrics::default()),
        }
    }

    fn take_metrics(&mut self) -> BackendMetrics {
        std::mem::take(self.metrics.get_mut())
    }
}

impl<B: RenameBackend> RenameBackend for TimedBackend<B> {
    fn validate_path_environment(&self, path: &LegacyText) -> Result<(), BackendError> {
        let started = Instant::now();
        let result = self.inner.validate_path_environment(path);
        self.metrics.borrow_mut().validate.record(started.elapsed());
        result
    }

    fn path_key(&self, path: &LegacyText) -> PathKey {
        let started = Instant::now();
        let result = self.inner.path_key(path);
        self.metrics.borrow_mut().path_key.record(started.elapsed());
        result
    }

    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError> {
        let started = Instant::now();
        let result = self.inner.observe(path);
        self.metrics.borrow_mut().observe.record(started.elapsed());
        result
    }

    fn is_same_or_descendant(
        &self,
        ancestor: &LegacyText,
        candidate: &LegacyText,
    ) -> Result<bool, BackendError> {
        let started = Instant::now();
        let result = self.inner.is_same_or_descendant(ancestor, candidate);
        self.metrics
            .borrow_mut()
            .descendant
            .record(started.elapsed());
        result
    }

    fn next_transaction_nonce(&mut self) -> Result<u128, BackendError> {
        let started = Instant::now();
        let result = self.inner.next_transaction_nonce();
        self.metrics.borrow_mut().nonce.record(started.elapsed());
        result
    }

    fn rename_no_replace(&mut self, operation: &RenameOperation) -> Result<(), BackendError> {
        let started = Instant::now();
        let result = self.inner.rename_no_replace(operation);
        self.metrics.borrow_mut().rename.record(started.elapsed());
        result
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct JournalMetrics {
    begin: TimedCallMetric,
    prepared: TimedCallMetric,
    completed: TimedCallMetric,
    not_applied: TimedCallMetric,
    terminal: TimedCallMetric,
}

struct TimedJournal<J: JournalStore> {
    inner: J,
    metrics: JournalMetrics,
}

impl<J: JournalStore> TimedJournal<J> {
    fn new(inner: J) -> Self {
        Self {
            inner,
            metrics: JournalMetrics::default(),
        }
    }

    fn inner(&self) -> &J {
        &self.inner
    }

    fn inner_mut(&mut self) -> &mut J {
        &mut self.inner
    }

    fn take_metrics(&mut self) -> JournalMetrics {
        std::mem::take(&mut self.metrics)
    }
}

impl<J: JournalStore> JournalStore for TimedJournal<J> {
    fn begin(&mut self, plan: PlanId, steps: &[JournalStep]) -> Result<(), JournalError> {
        let started = Instant::now();
        let result = self.inner.begin(plan, steps);
        self.metrics.begin.record(started.elapsed());
        result
    }

    fn prepared(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        let started = Instant::now();
        let result = self.inner.prepared(step, direction);
        self.metrics.prepared.record(started.elapsed());
        result
    }

    fn completed(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        let started = Instant::now();
        let result = self.inner.completed(step, direction);
        self.metrics.completed.record(started.elapsed());
        result
    }

    fn not_applied(
        &mut self,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        let started = Instant::now();
        let result = self.inner.not_applied(step, direction);
        self.metrics.not_applied.record(started.elapsed());
        result
    }

    fn terminal(&mut self, terminal: JournalTerminal) -> Result<(), JournalError> {
        let started = Instant::now();
        let result = self.inner.terminal(terminal);
        self.metrics.terminal.record(started.elapsed());
        result
    }
}

fn assert_timed_calls(metric: TimedCallMetric, expected: usize) {
    assert_eq!(metric.calls, expected);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BenchmarkTopology {
    Same,
    Unique,
    Deep,
}

impl BenchmarkTopology {
    fn parse(value: Option<&str>) -> Result<Self, std::io::Error> {
        match value {
            Some("same-parent") | None => Ok(Self::Same),
            Some("unique-parent") => Ok(Self::Unique),
            Some("deep-parent") => Ok(Self::Deep),
            Some(_) => Err(std::io::Error::other(
                "DARKRENAMER_BENCH_TOPOLOGY must be same-parent, unique-parent, or deep-parent",
            )),
        }
    }

    fn from_environment() -> Result<Self, std::io::Error> {
        match std::env::var("DARKRENAMER_BENCH_TOPOLOGY") {
            Ok(value) => Self::parse(Some(&value)),
            Err(std::env::VarError::NotPresent) => Self::parse(None),
            Err(std::env::VarError::NotUnicode(_)) => Err(std::io::Error::other(
                "DARKRENAMER_BENCH_TOPOLOGY must be valid Unicode",
            )),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Same => "same-parent",
            Self::Unique => "unique-parent",
            Self::Deep => "deep-parent",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EnvironmentInput<'a> {
    Missing,
    Unicode(&'a str),
    NonUnicode,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BenchmarkEvidenceClass {
    Physical,
    DirectionalHosted,
}

impl BenchmarkEvidenceClass {
    fn parse(value: EnvironmentInput<'_>) -> Result<Self, std::io::Error> {
        match value {
            EnvironmentInput::Missing | EnvironmentInput::Unicode("physical") => Ok(Self::Physical),
            EnvironmentInput::Unicode("directional-hosted") => Ok(Self::DirectionalHosted),
            EnvironmentInput::Unicode(_) => Err(std::io::Error::other(
                "DARKRENAMER_BENCH_EVIDENCE_CLASS must be physical or directional-hosted",
            )),
            EnvironmentInput::NonUnicode => Err(std::io::Error::other(
                "DARKRENAMER_BENCH_EVIDENCE_CLASS must be valid Unicode",
            )),
        }
    }

    fn from_environment() -> Result<Self, std::io::Error> {
        match std::env::var("DARKRENAMER_BENCH_EVIDENCE_CLASS") {
            Ok(value) => Self::parse(EnvironmentInput::Unicode(&value)),
            Err(std::env::VarError::NotPresent) => Self::parse(EnvironmentInput::Missing),
            Err(std::env::VarError::NotUnicode(_)) => Self::parse(EnvironmentInput::NonUnicode),
        }
    }

    fn validate_media(self, media: &str) -> Result<(), std::io::Error> {
        match (self, media) {
            (Self::Physical, "ssd" | "hdd") | (Self::DirectionalHosted, "virtual") => Ok(()),
            (Self::Physical, _) => Err(std::io::Error::other(
                "physical evidence requires DARKRENAMER_BENCH_MEDIA=ssd or hdd",
            )),
            (Self::DirectionalHosted, _) => Err(std::io::Error::other(
                "directional-hosted evidence requires DARKRENAMER_BENCH_MEDIA=virtual",
            )),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Physical => "physical",
            Self::DirectionalHosted => "directional-hosted",
        }
    }

    const fn runs_execution(self) -> bool {
        matches!(self, Self::Physical)
    }

    const fn scope(self) -> &'static str {
        match self {
            Self::Physical => "durable",
            Self::DirectionalHosted => "planning-only",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct BenchmarkIteration(u8);

impl BenchmarkIteration {
    fn parse(value: EnvironmentInput<'_>) -> Result<Self, std::io::Error> {
        match value {
            EnvironmentInput::Missing => Ok(Self(1)),
            EnvironmentInput::Unicode(value) => value
                .parse::<u8>()
                .ok()
                .filter(|iteration| *iteration <= 5)
                .map(Self)
                .ok_or_else(|| {
                    std::io::Error::other("DARKRENAMER_BENCH_ITERATION must be from 0 through 5")
                }),
            EnvironmentInput::NonUnicode => Err(std::io::Error::other(
                "DARKRENAMER_BENCH_ITERATION must be valid Unicode",
            )),
        }
    }

    fn from_environment() -> Result<Self, std::io::Error> {
        match std::env::var("DARKRENAMER_BENCH_ITERATION") {
            Ok(value) => Self::parse(EnvironmentInput::Unicode(&value)),
            Err(std::env::VarError::NotPresent) => Self::parse(EnvironmentInput::Missing),
            Err(std::env::VarError::NotUnicode(_)) => Self::parse(EnvironmentInput::NonUnicode),
        }
    }

    const fn value(self) -> u8 {
        self.0
    }

    const fn recorded(self) -> bool {
        self.0 != 0
    }
}

const DEEP_PARENT_EXTRA_DEPTH: usize = 8;

fn parse_private_root_acknowledgment(value: Option<&str>) -> Result<(), std::io::Error> {
    match value {
        Some("1") => Ok(()),
        Some(_) | None => Err(std::io::Error::other(
            "DARKRENAMER_BENCH_ROOT_PRIVATE must be set to 1",
        )),
    }
}

fn private_root_acknowledged_from_environment() -> Result<(), std::io::Error> {
    match std::env::var("DARKRENAMER_BENCH_ROOT_PRIVATE") {
        Ok(value) => parse_private_root_acknowledgment(Some(&value)),
        Err(std::env::VarError::NotPresent) => parse_private_root_acknowledgment(None),
        Err(std::env::VarError::NotUnicode(_)) => Err(std::io::Error::other(
            "DARKRENAMER_BENCH_ROOT_PRIVATE must be valid Unicode",
        )),
    }
}

fn prepare_benchmark_parents(
    root: &std::path::Path,
    topology: BenchmarkTopology,
    count: usize,
) -> Result<Vec<PathBuf>, std::io::Error> {
    match topology {
        BenchmarkTopology::Same => Ok(vec![root.to_path_buf(); count]),
        BenchmarkTopology::Unique => {
            let mut parents = Vec::with_capacity(count);
            for index in 0..count {
                let parent = root.join(format!("parent-{index:05}"));
                fs::create_dir(&parent).map_err(|_| {
                    std::io::Error::other("failed to create a unique benchmark parent")
                })?;
                parents.push(parent);
            }
            Ok(parents)
        }
        BenchmarkTopology::Deep => {
            let mut parent = root.to_path_buf();
            for depth in 0..DEEP_PARENT_EXTRA_DEPTH {
                parent = parent.join(format!("level-{depth:02}"));
                fs::create_dir(&parent).map_err(|_| {
                    std::io::Error::other("failed to create the deep benchmark parent")
                })?;
            }
            Ok(vec![parent; count])
        }
    }
}

fn create_benchmark_source(path: &std::path::Path) -> Result<(), std::io::Error> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|_| std::io::Error::other("failed to create a benchmark source fixture"))?;
    file.write_all(b"benchmark")
        .map_err(|_| std::io::Error::other("failed to write a benchmark source fixture"))
}

#[derive(Clone, Copy)]
struct BenchmarkMetadata<'a> {
    media: &'a str,
    count: usize,
    topology: BenchmarkTopology,
    evidence_class: BenchmarkEvidenceClass,
    iteration: BenchmarkIteration,
}

fn print_backend_metrics(metadata: BenchmarkMetadata<'_>, phase: &str, metrics: BackendMetrics) {
    let BenchmarkMetadata {
        media,
        count,
        topology,
        evidence_class,
        iteration,
    } = metadata;
    println!(
        "darkrenamer_benchmark_backend,media={media},count={count},topology={},evidence_class={},\
         iteration={},recorded={},scope={},phase={phase},validate_calls={},validate_us={},\
         path_key_calls={},path_key_us={},observe_calls={},observe_us={},descendant_calls={},\
         descendant_us={},nonce_calls={},nonce_us={},rename_calls={},rename_us={}",
        topology.as_str(),
        evidence_class.as_str(),
        iteration.value(),
        iteration.recorded(),
        evidence_class.scope(),
        metrics.validate.calls,
        metrics.validate.micros(),
        metrics.path_key.calls,
        metrics.path_key.micros(),
        metrics.observe.calls,
        metrics.observe.micros(),
        metrics.descendant.calls,
        metrics.descendant.micros(),
        metrics.nonce.calls,
        metrics.nonce.micros(),
        metrics.rename.calls,
        metrics.rename.micros(),
    );
}

fn print_journal_metrics(metadata: BenchmarkMetadata<'_>, metrics: JournalMetrics) {
    let BenchmarkMetadata {
        media,
        count,
        topology,
        evidence_class,
        iteration,
    } = metadata;
    println!(
        "darkrenamer_benchmark_journal,media={media},count={count},topology={},evidence_class={},\
         iteration={},recorded={},scope={},phase=execution,begin_calls={},begin_us={},\
         prepared_calls={},prepared_us={},completed_calls={},completed_us={},not_applied_calls={},\
         not_applied_us={},terminal_calls={},terminal_us={}",
        topology.as_str(),
        evidence_class.as_str(),
        iteration.value(),
        iteration.recorded(),
        evidence_class.scope(),
        metrics.begin.calls,
        metrics.begin.micros(),
        metrics.prepared.calls,
        metrics.prepared.micros(),
        metrics.completed.calls,
        metrics.completed.micros(),
        metrics.not_applied.calls,
        metrics.not_applied.micros(),
        metrics.terminal.calls,
        metrics.terminal.micros(),
    );
}

struct DurableBenchmarkMetrics {
    execution: Duration,
    backend: BackendMetrics,
    journal: JournalMetrics,
}

fn print_benchmark_summary(
    metadata: BenchmarkMetadata<'_>,
    planning: Duration,
    preflight: Duration,
    durable: Option<&DurableBenchmarkMetrics>,
) {
    let BenchmarkMetadata {
        media,
        count,
        topology,
        evidence_class,
        iteration,
    } = metadata;
    match durable {
        Some(durable) => println!(
            "darkrenamer_benchmark,media={media},count={count},topology={},evidence_class={},\
             iteration={},recorded={},scope={},planning_ms={},execution_ms={},planning_us={},\
             preflight_us={},execution_us={}",
            topology.as_str(),
            evidence_class.as_str(),
            iteration.value(),
            iteration.recorded(),
            evidence_class.scope(),
            planning.as_millis(),
            durable.execution.as_millis(),
            planning.as_micros(),
            preflight.as_micros(),
            durable.execution.as_micros(),
        ),
        None => println!(
            "darkrenamer_benchmark,media={media},count={count},topology={},evidence_class={},\
             iteration={},recorded={},scope={},planning_ms={},planning_us={},preflight_us={}",
            topology.as_str(),
            evidence_class.as_str(),
            iteration.value(),
            iteration.recorded(),
            evidence_class.scope(),
            planning.as_millis(),
            planning.as_micros(),
            preflight.as_micros(),
        ),
    }
}

fn case_query_supported(parent: &std::path::Path) -> Result<bool, Box<dyn std::error::Error>> {
    let backend = WindowsRenameBackend;
    match backend.validate_path_environment(&legacy_path(&parent.join("case-query-probe"))) {
        Ok(()) => Ok(true),
        Err(error) if matches!(error.code, 87 | 120) => {
            windows_capabilities::unavailable(
                "case-sensitive-query",
                Some(error.code as i32),
                "unsupported",
            )?;
            Ok(false)
        }
        Err(error) => Err(error.into()),
    }
}

#[test]
fn journal_root_rejects_unc_before_filesystem_access() {
    let error = JournalRoot::open("\\\\server\\share\\journal-root")
        .err()
        .and_then(|error| error.os_code);
    assert_eq!(error, Some(53));
}

#[test]
fn occupied_destination_and_relative_path_are_rejected() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source = directory.path().join("a.txt");
    let occupied = directory.path().join("b.txt");
    fs::write(&source, b"a")?;
    fs::write(&occupied, b"b")?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let backend = WindowsRenameBackend;
    let request = PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &source, directory.path(), "b.txt")],
    );
    let error = RenamePlanner::new(&backend)
        .plan(request)
        .err()
        .ok_or_else(|| std::io::Error::other("occupied destination was accepted"))?;
    assert_eq!(error.issues()[0].kind, PlanIssueKind::DestinationOccupied);
    assert!(backend.observe(&LegacyText::from("relative.txt")).is_err());
    Ok(())
}

#[test]
fn case_only_and_swap_execute_through_handle_relative_moves()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source = directory.path().join("A.TXT");
    fs::write(&source, b"case")?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let mut backend = WindowsRenameBackend;
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &source, directory.path(), "a.txt")],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    let names = fs::read_dir(directory.path())?
        .filter_map(Result::ok)
        .map(|entry| entry.file_name())
        .collect::<Vec<_>>();
    assert!(names.iter().any(|name| name == "a.txt"));

    let left = directory.path().join("left.txt");
    let right = directory.path().join("right.txt");
    fs::write(&left, b"left")?;
    fs::write(&right, b"right")?;
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(2),
        vec![
            intent(1, &left, directory.path(), "right.txt"),
            intent(2, &right, directory.path(), "left.txt"),
        ],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert_eq!(fs::read(&left)?, b"right");
    assert_eq!(fs::read(&right)?, b"left");
    Ok(())
}

#[test]
fn stale_source_and_replaced_parent_fail_before_mutation() -> Result<(), Box<dyn std::error::Error>>
{
    let directory = tempfile::tempdir()?;
    let parent = directory.path().join("work");
    fs::create_dir(&parent)?;
    let source = parent.join("a.txt");
    fs::write(&source, b"old")?;
    if !case_query_supported(&parent)? {
        return Ok(());
    }
    let mut backend = WindowsRenameBackend;
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &source, &parent, "b.txt")],
    ))?;
    fs::rename(&source, parent.join("displaced.txt"))?;
    fs::write(&source, b"replacement")?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let error = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)
        .err()
        .ok_or_else(|| std::io::Error::other("stale source was executed"))?;
    assert_eq!(error.kind, ExecuteErrorKind::StaleSource);
    assert!(!parent.join("b.txt").exists());

    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(2),
        vec![intent(1, &source, &parent, "c.txt")],
    ))?;
    let moved_parent = directory.path().join("old-work");
    fs::rename(&parent, &moved_parent)?;
    fs::create_dir(&parent)?;
    fs::write(parent.join("a.txt"), b"new-parent")?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let error = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)
        .err()
        .ok_or_else(|| std::io::Error::other("replaced parent was executed"))?;
    assert_eq!(error.kind, ExecuteErrorKind::StaleParent);
    assert!(!parent.join("c.txt").exists());
    Ok(())
}

#[test]
fn directory_normal_and_case_only_renames_use_the_same_safe_executor()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source = directory.path().join("Folder");
    fs::create_dir(&source)?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let mut backend = WindowsRenameBackend;
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![directory_intent(0, &source, directory.path(), "Renamed")],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);

    let renamed = directory.path().join("Renamed");
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(2),
        vec![directory_intent(1, &renamed, directory.path(), "RENAMED")],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert!(
        fs::read_dir(directory.path())?
            .filter_map(Result::ok)
            .any(|entry| entry.file_name() == "RENAMED")
    );
    Ok(())
}

#[test]
fn hard_link_destination_is_never_replaced() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source = directory.path().join("source.txt");
    let hard_link = directory.path().join("hard-link.txt");
    fs::write(&source, b"source")?;
    fs::hard_link(&source, &hard_link)?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let mut backend = WindowsRenameBackend;
    let source_snapshot = backend.observe(&legacy_path(&source))?;
    let destination_snapshot = backend.observe(&legacy_path(&hard_link))?;
    let source_entry = source_snapshot
        .entry
        .ok_or_else(|| std::io::Error::other("source identity missing"))?;
    let operation = RenameOperation::new(
        legacy_path(&source),
        legacy_path(&hard_link),
        source_entry.identity,
        source_snapshot.parent,
        destination_snapshot.parent,
    );
    let error = backend
        .rename_no_replace(&operation)
        .err()
        .ok_or_else(|| std::io::Error::other("hard-link destination was replaced"))?;
    assert_eq!(error.certainty, MutationCertainty::NotApplied);
    assert_eq!(fs::read(&source)?, b"source");
    assert_eq!(fs::read(&hard_link)?, b"source");
    Ok(())
}

#[test]
fn intermediate_reparse_and_unsupported_prefix_are_rejected_when_available()
-> Result<(), Box<dyn std::error::Error>> {
    use std::os::windows::fs::symlink_dir;

    let directory = tempfile::tempdir()?;
    let target = directory.path().join("target-parent");
    fs::create_dir(&target)?;
    fs::write(target.join("a.txt"), b"a")?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let link = directory.path().join("junction");
    if let Err(error) = symlink_dir(&target, &link) {
        if windows_capabilities::is_symlink_creation_capability_error(&error) {
            windows_capabilities::unavailable(
                "symlink-creation",
                error.raw_os_error(),
                "permission-denied-or-privilege-not-held",
            )?;
            return Ok(());
        }
        return Err(error.into());
    }
    let backend = WindowsRenameBackend;
    assert!(backend.observe(&legacy_path(&link.join("a.txt"))).is_err());
    assert!(JournalRoot::open(&link).is_err());
    let unc_error = backend
        .validate_path_environment(&LegacyText::from("\\\\server\\share\\folder\\child.txt"))
        .err()
        .ok_or_else(|| std::io::Error::other("UNC path was accepted"))?;
    assert_eq!(unc_error.code, 53);
    assert!(
        backend
            .observe(&LegacyText::from("\\\\.\\C:\\unsupported.txt"))
            .is_err()
    );
    Ok(())
}

fn set_directory_case_sensitive(path: &std::path::Path, enabled: bool) -> std::io::Result<()> {
    use std::mem::size_of;
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_CASE_SENSITIVE_INFO, FILE_FLAG_BACKUP_SEMANTICS, FILE_READ_ATTRIBUTES,
        FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_WRITE_ATTRIBUTES,
        FileCaseSensitiveInfo, SetFileInformationByHandle,
    };
    use windows_sys::Win32::System::SystemServices::FILE_CS_FLAG_CASE_SENSITIVE_DIR;

    let file = fs::OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)?;
    let info = FILE_CASE_SENSITIVE_INFO {
        Flags: if enabled {
            FILE_CS_FLAG_CASE_SENSITIVE_DIR
        } else {
            0
        },
    };
    let size = u32::try_from(size_of::<FILE_CASE_SENSITIVE_INFO>())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    // SAFETY: file is a live directory handle and info is a correctly aligned,
    // fully initialized buffer of the exact checked size for this synchronous call.
    let success = unsafe {
        SetFileInformationByHandle(
            file.as_raw_handle(),
            FileCaseSensitiveInfo,
            std::ptr::from_ref(&info).cast(),
            size,
        )
    };
    if success == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

struct CaseSensitiveFixtureGuard {
    path: Option<std::path::PathBuf>,
}

impl CaseSensitiveFixtureGuard {
    fn new(path: &std::path::Path) -> Self {
        Self {
            path: Some(path.to_path_buf()),
        }
    }

    fn cleanup(&mut self) -> std::io::Result<()> {
        let Some(path) = self.path.as_deref() else {
            return Ok(());
        };
        empty_directory(path)?;
        fs::remove_dir(path)?;
        self.path = None;
        Ok(())
    }
}

impl Drop for CaseSensitiveFixtureGuard {
    fn drop(&mut self) {
        if let Some(path) = self.path.as_deref() {
            let _ = empty_directory(path);
            let _ = fs::remove_dir(path);
        }
    }
}

fn empty_directory(path: &std::path::Path) -> std::io::Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        if metadata.is_dir() && !metadata.file_type().is_symlink() {
            fs::remove_dir_all(entry.path())?;
        } else {
            fs::remove_file(entry.path())?;
        }
    }
    Ok(())
}

#[test]
fn case_sensitive_parent_is_explicitly_unsupported_when_platform_allows_fixture()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let parent = directory.path().join("case-sensitive");
    let unrelated = directory.path().join("unrelated.txt");
    fs::create_dir(&parent)?;
    fs::write(&unrelated, b"keep")?;
    let source = parent.join("a.txt");
    if let Err(error) = set_directory_case_sensitive(&parent, true) {
        if matches!(error.raw_os_error(), Some(5 | 50 | 87)) {
            windows_capabilities::unavailable(
                "case-sensitive-directory-fixture",
                error.raw_os_error(),
                "fixture-setup-failed",
            )?;
            return Ok(());
        }
        return Err(error.into());
    }
    let mut fixture = CaseSensitiveFixtureGuard::new(&parent);
    fs::write(&source, b"a")?;

    let backend = WindowsRenameBackend;
    let environment_error = backend
        .validate_path_environment(&legacy_path(&source))
        .err();
    let request = PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &source, &parent, "b.txt")],
    );
    let plan_error = RenamePlanner::new(&backend).plan(request).err();
    let root_error = JournalRoot::open(&parent).err();
    fixture.cleanup()?;

    assert!(!parent.exists());
    assert_eq!(fs::read(&unrelated)?, b"keep");
    assert!(directory.path().is_dir());

    assert_eq!(environment_error.map(|error| error.code), Some(50));
    assert!(plan_error.is_some_and(|error| {
        error
            .issues()
            .iter()
            .any(|issue| issue.kind == PlanIssueKind::UnsupportedCaseSensitiveParent)
    }));
    assert!(root_error.is_some_and(|error| {
        error.kind == FileJournalErrorKind::Io && error.os_code == Some(50)
    }));
    Ok(())
}

#[test]
fn final_reparse_and_journal_root_reparse_are_rejected_when_fixture_is_available()
-> Result<(), Box<dyn std::error::Error>> {
    use std::os::windows::fs::{symlink_dir, symlink_file};

    let directory = tempfile::tempdir()?;
    let target = directory.path().join("target.txt");
    let link = directory.path().join("link.txt");
    fs::write(&target, b"target")?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    if let Err(error) = symlink_file(&target, &link) {
        if windows_capabilities::is_symlink_creation_capability_error(&error) {
            windows_capabilities::unavailable(
                "symlink-creation",
                error.raw_os_error(),
                "permission-denied-or-privilege-not-held",
            )?;
            return Ok(());
        }
        return Err(error.into());
    }
    let backend = WindowsRenameBackend;
    let request = PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &link, directory.path(), "renamed.txt")],
    );
    let error = RenamePlanner::new(&backend)
        .plan(request)
        .err()
        .ok_or_else(|| std::io::Error::other("final reparse was accepted"))?;
    assert!(matches!(
        error.issues()[0].kind,
        PlanIssueKind::ReparseSource | PlanIssueKind::MissingSource
    ));

    let root_target = directory.path().join("journal-root");
    let root_link = directory.path().join("journal-link");
    fs::create_dir(&root_target)?;
    if let Err(error) = symlink_dir(&root_target, &root_link) {
        if windows_capabilities::is_symlink_creation_capability_error(&error) {
            windows_capabilities::unavailable(
                "symlink-creation",
                error.raw_os_error(),
                "permission-denied-or-privilege-not-held",
            )?;
            return Ok(());
        }
        return Err(error.into());
    }
    assert!(JournalRoot::open(root_link).is_err());
    Ok(())
}

#[test]
fn journal_child_handle_is_exclusive_and_relative_to_retained_root()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let root = JournalRoot::open(directory.path())?;
    let mut journal = FileJournal::create_new(&root, "exclusive.drj")?;
    let competing = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(directory.path().join("exclusive.drj"));
    assert!(competing.is_err());
    assert!(
        fs::rename(
            directory.path().join("exclusive.drj"),
            directory.path().join("substituted.drj"),
        )
        .is_err()
    );
    journal.mark_delete_if_safe()?;
    assert!(fs::write(directory.path().join("exclusive.drj"), b"replacement").is_err());
    drop(journal);
    assert!(!directory.path().join("exclusive.drj").exists());
    fs::write(directory.path().join("exclusive.drj"), b"replacement")?;
    assert_eq!(
        fs::read(directory.path().join("exclusive.drj"))?,
        b"replacement"
    );
    Ok(())
}

#[test]
fn planner_file_journal_backend_and_model_complete_one_production_path()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let source = directory.path().join("before.txt");
    fs::write(&source, b"content")?;
    let mut model = LegacyList::new();
    assert_eq!(
        model.append(LegacyListItem::new(legacy_path(&source), false, 7, 8, 9,)),
        Ok(true)
    );
    assert_eq!(model.manual_change(0, "after.txt"), Ok(true));
    let mut backend = WindowsRenameBackend;
    let root = JournalRoot::open(directory.path())?;
    let substituted_root = directory.path().with_extension("substituted-root");
    if fs::rename(directory.path(), &substituted_root).is_ok() {
        let _ = fs::rename(&substituted_root, directory.path());
        return Err(std::io::Error::other("retained journal root was substituted").into());
    }
    let candidate_path = directory.path().join("candidate.drj");
    let active_path = directory.path().join("active.drj");
    let mut journal = FileJournal::create_candidate(&root, "candidate.drj", "active.drj")?;
    assert!(
        fs::rename(&candidate_path, directory.path().join("substituted.drj")).is_err(),
        "exclusive candidate journal was substituted"
    );
    let plan =
        RenamePlanner::new(&backend).plan(build_plan_request(&model, ModelRevision::new(1)))?;
    let id = plan.id();
    let revision = plan.revision();

    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;

    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert!(!candidate_path.exists());
    assert!(active_path.exists());
    assert_eq!(journal.path(), active_path);
    assert!(apply_execution_report(&mut model, &report));
    assert_eq!(
        model.items()[0].source_path(),
        &legacy_path(&directory.path().join("after.txt"))
    );
    assert!(journal.is_terminal());
    Ok(())
}

#[test]
fn benchmark_topology_parser_accepts_documented_values_and_rejects_unknown_values() {
    assert_eq!(
        BenchmarkTopology::parse(None).ok(),
        Some(BenchmarkTopology::Same)
    );
    assert_eq!(
        BenchmarkTopology::parse(Some("same-parent")).ok(),
        Some(BenchmarkTopology::Same)
    );
    assert_eq!(
        BenchmarkTopology::parse(Some("unique-parent")).ok(),
        Some(BenchmarkTopology::Unique)
    );
    assert_eq!(
        BenchmarkTopology::parse(Some("deep-parent")).ok(),
        Some(BenchmarkTopology::Deep)
    );
    assert!(BenchmarkTopology::parse(Some("shared-deep")).is_err());
    assert!(BenchmarkTopology::parse(Some("unknown")).is_err());
}

#[test]
fn benchmark_evidence_class_parser_and_media_pairings_are_strict() {
    assert_eq!(
        BenchmarkEvidenceClass::parse(EnvironmentInput::Missing).ok(),
        Some(BenchmarkEvidenceClass::Physical)
    );
    assert_eq!(
        BenchmarkEvidenceClass::parse(EnvironmentInput::Unicode("physical")).ok(),
        Some(BenchmarkEvidenceClass::Physical)
    );
    assert_eq!(
        BenchmarkEvidenceClass::parse(EnvironmentInput::Unicode("directional-hosted")).ok(),
        Some(BenchmarkEvidenceClass::DirectionalHosted)
    );
    assert!(BenchmarkEvidenceClass::parse(EnvironmentInput::Unicode("directional")).is_err());
    assert!(BenchmarkEvidenceClass::parse(EnvironmentInput::NonUnicode).is_err());

    assert!(
        BenchmarkEvidenceClass::Physical
            .validate_media("ssd")
            .is_ok()
    );
    assert!(
        BenchmarkEvidenceClass::Physical
            .validate_media("hdd")
            .is_ok()
    );
    assert!(
        BenchmarkEvidenceClass::Physical
            .validate_media("virtual")
            .is_err()
    );
    assert!(
        BenchmarkEvidenceClass::DirectionalHosted
            .validate_media("virtual")
            .is_ok()
    );
    assert!(
        BenchmarkEvidenceClass::DirectionalHosted
            .validate_media("ssd")
            .is_err()
    );
    assert!(
        BenchmarkEvidenceClass::DirectionalHosted
            .validate_media("hdd")
            .is_err()
    );
    assert!(BenchmarkEvidenceClass::Physical.runs_execution());
    assert!(!BenchmarkEvidenceClass::DirectionalHosted.runs_execution());
    assert_eq!(BenchmarkEvidenceClass::Physical.scope(), "durable");
    assert_eq!(
        BenchmarkEvidenceClass::DirectionalHosted.scope(),
        "planning-only"
    );
}

#[test]
fn benchmark_iteration_parser_distinguishes_warmup_and_recorded_runs()
-> Result<(), Box<dyn std::error::Error>> {
    let default = BenchmarkIteration::parse(EnvironmentInput::Missing)?;
    assert_eq!(default.value(), 1);
    assert!(default.recorded());

    let warmup = BenchmarkIteration::parse(EnvironmentInput::Unicode("0"))?;
    assert_eq!(warmup.value(), 0);
    assert!(!warmup.recorded());

    for value in ["1", "2", "3", "4", "5"] {
        let iteration = BenchmarkIteration::parse(EnvironmentInput::Unicode(value))?;
        assert!(iteration.recorded());
    }
    assert!(BenchmarkIteration::parse(EnvironmentInput::Unicode("6")).is_err());
    assert!(BenchmarkIteration::parse(EnvironmentInput::Unicode("-1")).is_err());
    assert!(BenchmarkIteration::parse(EnvironmentInput::Unicode("invalid")).is_err());
    assert!(BenchmarkIteration::parse(EnvironmentInput::NonUnicode).is_err());
    Ok(())
}

#[test]
fn private_root_acknowledgment_requires_exact_opt_in() {
    assert!(parse_private_root_acknowledgment(Some("1")).is_ok());
    assert!(parse_private_root_acknowledgment(None).is_err());
    assert!(parse_private_root_acknowledgment(Some("0")).is_err());
    assert!(parse_private_root_acknowledgment(Some("true")).is_err());
}

#[test]
fn benchmark_parent_preparation_preserves_each_topology() -> Result<(), Box<dyn std::error::Error>>
{
    let directory = tempfile::tempdir()?;
    let same_root = directory.path().join("same");
    let unique_root = directory.path().join("unique");
    let deep_root = directory.path().join("deep");
    fs::create_dir(&same_root)?;
    fs::create_dir(&unique_root)?;
    fs::create_dir(&deep_root)?;

    let same = prepare_benchmark_parents(&same_root, BenchmarkTopology::Same, 2)?;
    assert_eq!(same[0], same[1]);
    assert_eq!(same[0], same_root);

    let unique = prepare_benchmark_parents(&unique_root, BenchmarkTopology::Unique, 2)?;
    assert_ne!(unique[0], unique[1]);
    assert!(unique.iter().all(|parent| parent.starts_with(&unique_root)));

    let deep = prepare_benchmark_parents(&deep_root, BenchmarkTopology::Deep, 2)?;
    assert_eq!(deep[0], deep[1]);
    assert_eq!(
        deep[0].strip_prefix(&deep_root)?.components().count(),
        DEEP_PARENT_EXTRA_DEPTH
    );
    Ok(())
}

#[test]
fn direct_plan_reports_phase_separated_backend_and_journal_counts()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let first_source = directory.path().join("first-source.txt");
    let second_source = directory.path().join("second-source.txt");
    let first_destination = directory.path().join("first-renamed.txt");
    let second_destination = directory.path().join("second-renamed.txt");
    fs::write(&first_source, b"first")?;
    fs::write(&second_source, b"second")?;

    let mut backend = TimedBackend::new(WindowsRenameBackend);
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![
            intent(0, &first_source, directory.path(), "first-renamed.txt"),
            intent(1, &second_source, directory.path(), "second-renamed.txt"),
        ],
    ))?;
    let planning = backend.take_metrics();
    assert_timed_calls(planning.validate, 4);
    assert_timed_calls(planning.observe, 4);
    assert_timed_calls(planning.rename, 0);

    let _requirements = preflight_plan(&plan, &mut backend)?;
    let preflight = backend.take_metrics();
    assert_timed_calls(preflight.validate, 0);
    assert_timed_calls(preflight.path_key, 4);
    assert_timed_calls(preflight.observe, 0);
    assert_timed_calls(preflight.descendant, 0);
    assert_timed_calls(preflight.nonce, 0);
    assert_timed_calls(preflight.rename, 0);

    let id = plan.id();
    let revision = plan.revision();
    let mut journal = TimedJournal::new(MemoryJournal::new());
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    let execution = backend.take_metrics();
    let journal_metrics = journal.take_metrics();
    assert_timed_calls(execution.validate, 0);
    assert_timed_calls(execution.path_key, 4);
    assert_timed_calls(execution.observe, 4);
    assert_timed_calls(execution.descendant, 0);
    assert_timed_calls(execution.nonce, 0);
    assert_timed_calls(execution.rename, 2);
    assert_timed_calls(journal_metrics.begin, 1);
    assert_timed_calls(journal_metrics.prepared, 2);
    assert_timed_calls(journal_metrics.completed, 2);
    assert_timed_calls(journal_metrics.not_applied, 0);
    assert_timed_calls(journal_metrics.terminal, 1);

    let reset_backend = backend.take_metrics();
    assert_timed_calls(reset_backend.validate, 0);
    assert_timed_calls(reset_backend.path_key, 0);
    assert_timed_calls(reset_backend.observe, 0);
    assert_timed_calls(reset_backend.descendant, 0);
    assert_timed_calls(reset_backend.nonce, 0);
    assert_timed_calls(reset_backend.rename, 0);
    let reset_journal = journal.take_metrics();
    assert_timed_calls(reset_journal.begin, 0);
    assert_timed_calls(reset_journal.prepared, 0);
    assert_timed_calls(reset_journal.completed, 0);
    assert_timed_calls(reset_journal.not_applied, 0);
    assert_timed_calls(reset_journal.terminal, 0);

    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert!(!first_source.exists());
    assert!(!second_source.exists());
    assert_eq!(fs::read(first_destination)?, b"first");
    assert_eq!(fs::read(second_destination)?, b"second");
    Ok(())
}

#[test]
#[ignore = "manual benchmark; set DARKRENAMER_BENCH_ROOT and DARKRENAMER_BENCH_COUNT"]
fn benchmark_durable_production_path() -> Result<(), Box<dyn std::error::Error>> {
    let benchmark_root = std::env::var_os("DARKRENAMER_BENCH_ROOT")
        .map(PathBuf::from)
        .ok_or_else(|| std::io::Error::other("DARKRENAMER_BENCH_ROOT is required"))?;
    let count = std::env::var("DARKRENAMER_BENCH_COUNT")
        .map_err(|_| std::io::Error::other("DARKRENAMER_BENCH_COUNT is required"))?
        .parse::<usize>()?;
    if !matches!(count, 100 | 1_000 | 10_000) {
        return Err(
            std::io::Error::other("DARKRENAMER_BENCH_COUNT must be 100, 1000, or 10000").into(),
        );
    }
    let media = std::env::var("DARKRENAMER_BENCH_MEDIA")
        .map_err(|_| std::io::Error::other("DARKRENAMER_BENCH_MEDIA is required"))?;
    let evidence_class = BenchmarkEvidenceClass::from_environment()?;
    evidence_class.validate_media(&media)?;
    let iteration = BenchmarkIteration::from_environment()?;
    let topology = BenchmarkTopology::from_environment()?;
    // This explicit operator acknowledgment is a defensive fixture precondition,
    // not proof that the selected root's ACL excludes other users or processes.
    private_root_acknowledged_from_environment()?;
    if evidence_class == BenchmarkEvidenceClass::Physical
        && process_is_elevated()
            .map_err(|_| std::io::Error::other("failed to query benchmark process elevation"))?
    {
        return Err(std::io::Error::other(
            "the physical-volume benchmark must run without elevation",
        )
        .into());
    }
    // Directional hosted evidence may be elevated only because the workflow supplies
    // an ephemeral runner-owned root; the explicit private-root acknowledgment and
    // retained-root confinement remain mandatory.
    if !benchmark_root.is_absolute() || !benchmark_root.is_dir() {
        return Err(std::io::Error::other(
            "DARKRENAMER_BENCH_ROOT must be an existing absolute directory",
        )
        .into());
    }
    let benchmark_root_handle = JournalRoot::open(&benchmark_root)?;

    let fixture = tempfile::Builder::new()
        .prefix("darkrenamer-benchmark-")
        .tempdir_in(&benchmark_root)?;
    if !case_query_supported(fixture.path())? {
        return Err(std::io::Error::other(
            "the selected volume does not support the required Windows path capability",
        )
        .into());
    }

    let parents = prepare_benchmark_parents(fixture.path(), topology, count)?;
    let mut intents = Vec::with_capacity(count);
    let mut fixture_paths = Vec::with_capacity(count);
    for (index, parent) in parents.into_iter().enumerate() {
        let source = parent.join(format!("source-{index:05}.txt"));
        let destination = parent.join(format!("renamed-{index:05}.txt"));
        create_benchmark_source(&source)?;
        intents.push(intent(
            u32::try_from(index)?,
            &source,
            &parent,
            &format!("renamed-{index:05}.txt"),
        ));
        fixture_paths.push((source, destination));
    }

    let mut backend = TimedBackend::new(WindowsRenameBackend);
    let planning_started = Instant::now();
    let plan =
        RenamePlanner::new(&backend).plan(PlanRequest::new(ModelRevision::new(1), intents))?;
    let planning = planning_started.elapsed();
    let planning_backend = backend.take_metrics();

    let preflight_started = Instant::now();
    let _requirements = preflight_plan(&plan, &mut backend)?;
    let preflight = preflight_started.elapsed();
    let preflight_backend = backend.take_metrics();

    let durable = if evidence_class.runs_execution() {
        let id = plan.id();
        let revision = plan.revision();
        let fixture_root = JournalRoot::open(fixture.path())?;
        let journal = FileJournal::create_candidate(&fixture_root, "candidate.drj", "active.drj")?;
        let mut journal = TimedJournal::new(journal);

        let execution_started = Instant::now();
        let report = RenameExecutor::new(&mut backend, &mut journal)
            .execute(plan.confirm_presented(id, revision)?)?;
        let execution = execution_started.elapsed();
        let execution_backend = backend.take_metrics();
        let execution_journal = journal.take_metrics();
        assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
        assert!(journal.inner().is_terminal());
        journal.inner_mut().mark_delete_if_safe()?;
        drop(journal);
        drop(fixture_root);

        for (source, destination) in &fixture_paths {
            assert!(destination.is_file());
            assert!(!source.exists());
        }
        Some(DurableBenchmarkMetrics {
            execution,
            backend: execution_backend,
            journal: execution_journal,
        })
    } else {
        for (source, destination) in &fixture_paths {
            assert!(source.is_file());
            assert!(!destination.exists());
        }
        None
    };
    drop(benchmark_root_handle);
    fixture
        .close()
        .map_err(|_| std::io::Error::other("failed to clean up the benchmark fixture"))?;

    let metadata = BenchmarkMetadata {
        media: media.as_str(),
        count,
        topology,
        evidence_class,
        iteration,
    };
    print_benchmark_summary(metadata, planning, preflight, durable.as_ref());
    print_backend_metrics(metadata, "planning", planning_backend);
    print_backend_metrics(metadata, "preflight", preflight_backend);
    if let Some(durable) = durable {
        print_backend_metrics(metadata, "execution", durable.backend);
        print_journal_metrics(metadata, durable.journal);
    }
    Ok(())
}
