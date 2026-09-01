//! Directional CPU micro-workloads for release-profile comparisons.
//!
//! These measurements do not cover admission, the production Windows backend,
//! durable Apply, worker cancellation, startup, UI response, or native acceptance.

use std::hint::black_box;
use std::time::{Duration, Instant};

use darknamer_app::rename::{
    EntryId, EntryKind, MemoryBackend, ModelRevision, PlanRequest, RenameIntent, RenamePlanner,
    preflight_plan,
};
use darknamer_core::{LegacyList, LegacyListItem, LegacyText};

const PROFILE_BENCHMARK_COUNT: usize = 10_000;
const PROFILE_BENCHMARK_INSTRUMENTATION_REVISION: &str = "profile-workloads-v1";

fn parse_source_sha(value: &str) -> Result<&str, std::io::Error> {
    if value.len() == 40
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(value)
    } else {
        Err(std::io::Error::other(
            "DARKRENAMER_PROFILE_BENCH_SOURCE_SHA must be exactly 40 lowercase hexadecimal characters",
        ))
    }
}

fn parse_iteration(value: &str) -> Result<u8, std::io::Error> {
    value
        .parse::<u8>()
        .ok()
        .filter(|iteration| *iteration <= 5)
        .ok_or_else(|| {
            std::io::Error::other("DARKRENAMER_PROFILE_BENCH_ITERATION must be from 0 through 5")
        })
}

fn print_phase(source_sha: &str, iteration: u8, phase: &str, elapsed: Duration) {
    println!(
        "darkrenamer_profile_benchmark,source_sha={source_sha},iteration={iteration},recorded={},\
         count={PROFILE_BENCHMARK_COUNT},scope=cpu-micro-workloads,selection_evidence=false,\
         backend=memory,filesystem_mutation=none,\
         instrumentation_revision={PROFILE_BENCHMARK_INSTRUMENTATION_REVISION},\
         phase={phase},elapsed_ns={}",
        iteration != 0,
        elapsed.as_nanos(),
    );
}

#[test]
fn profile_benchmark_metadata_is_strict() {
    assert_eq!(
        parse_source_sha("0123456789abcdef0123456789abcdef01234567").ok(),
        Some("0123456789abcdef0123456789abcdef01234567")
    );
    assert!(parse_source_sha("ABCDEF").is_err());
    assert!(parse_source_sha("g123456789abcdef0123456789abcdef01234567").is_err());
    assert_eq!(parse_iteration("0").ok(), Some(0));
    assert_eq!(parse_iteration("5").ok(), Some(5));
    assert!(parse_iteration("6").is_err());
    assert!(parse_iteration("warmup").is_err());
}

#[test]
#[ignore = "manual release-profile measurement; set source SHA and iteration"]
fn benchmark_release_profile() -> Result<(), Box<dyn std::error::Error>> {
    let source_sha_value = std::env::var("DARKRENAMER_PROFILE_BENCH_SOURCE_SHA")
        .map_err(|_| std::io::Error::other("DARKRENAMER_PROFILE_BENCH_SOURCE_SHA is required"))?;
    let source_sha = parse_source_sha(&source_sha_value)?;
    let iteration_value = std::env::var("DARKRENAMER_PROFILE_BENCH_ITERATION")
        .map_err(|_| std::io::Error::other("DARKRENAMER_PROFILE_BENCH_ITERATION is required"))?;
    let iteration = parse_iteration(&iteration_value)?;

    let rows = (0..PROFILE_BENCHMARK_COUNT)
        .map(|index| {
            LegacyListItem::new(
                format!(r"C:\profile-benchmark\{index:05}.txt"),
                false,
                0,
                0,
                0,
            )
        })
        .collect::<Vec<_>>();
    let mut list = LegacyList::new();

    let append_started = Instant::now();
    let appended = list.append_batch(rows)?;
    let append = append_started.elapsed();
    if appended != PROFILE_BENCHMARK_COUNT || list.len() != PROFILE_BENCHMARK_COUNT {
        return Err(std::io::Error::other("profile benchmark append result is incomplete").into());
    }

    let transform_started = Instant::now();
    let changed = list.prefix_complete_changed(&LegacyText::from("x-"))?;
    let transform = transform_started.elapsed();
    if changed.len() != PROFILE_BENCHMARK_COUNT
        || changed.first() != Some(&0)
        || changed.last() != Some(&(PROFILE_BENCHMARK_COUNT - 1))
    {
        return Err(
            std::io::Error::other("profile benchmark transform result is incomplete").into(),
        );
    }
    black_box(&list);

    let mut backend = MemoryBackend::new();
    let mut intents = Vec::with_capacity(PROFILE_BENCHMARK_COUNT);
    for index in 0..PROFILE_BENCHMARK_COUNT {
        let source = format!(r"C:\profile-benchmark\source-{index:05}.txt");
        backend.insert_file(source.as_str(), (index as u128) + 1);
        intents.push(RenameIntent::new(
            EntryId::new(index as u32),
            source,
            r"C:\profile-benchmark",
            format!("renamed-{index:05}.txt"),
            EntryKind::File,
        ));
    }

    let planning_started = Instant::now();
    let plan =
        RenamePlanner::new(&backend).plan(PlanRequest::new(ModelRevision::new(1), intents))?;
    let planning = planning_started.elapsed();
    if plan.changed_count() != PROFILE_BENCHMARK_COUNT {
        return Err(std::io::Error::other("profile benchmark plan is incomplete").into());
    }

    let preflight_started = Instant::now();
    let requirements = preflight_plan(&plan, &mut backend)?;
    let preflight = preflight_started.elapsed();
    if requirements.primitive_steps() != PROFILE_BENCHMARK_COUNT {
        return Err(std::io::Error::other("profile benchmark preflight is incomplete").into());
    }
    black_box((plan.fingerprint(), requirements.intent_frame_bytes()));

    print_phase(source_sha, iteration, "core-append", append);
    print_phase(source_sha, iteration, "core-transform", transform);
    print_phase(source_sha, iteration, "planning", planning);
    print_phase(source_sha, iteration, "preflight", preflight);
    Ok(())
}
