#[path = "support/windows_capabilities.rs"]
mod windows_capabilities;

use std::ffi::OsStr;
use std::io;

use windows_capabilities::{GateMode, gate_mode_from, unavailable_in_mode};

fn normalize_workflow_source(source: &str) -> String {
    source.replace("\r\n", "\n")
}

#[test]
fn privilege_not_held_is_a_symlink_creation_capability_error() {
    let error = io::Error::from_raw_os_error(1_314);

    assert!(windows_capabilities::is_symlink_creation_capability_error(
        &error
    ));
}

#[test]
fn local_optional_mode_emits_an_explicit_skip_outcome() {
    assert!(gate_mode_from(None).is_ok_and(|mode| mode == GateMode::LocalOptional));
    assert!(
        unavailable_in_mode(
            GateMode::LocalOptional,
            "symlink-creation",
            Some(5),
            "permission-denied"
        )
        .is_ok()
    );
}

#[test]
fn required_mode_turns_unavailable_capabilities_into_gate_failures() {
    assert!(gate_mode_from(Some(OsStr::new("1"))).is_ok_and(|mode| mode == GateMode::Required));
    let message = unavailable_in_mode(
        GateMode::Required,
        "case-sensitive-query",
        Some(120),
        "unsupported",
    )
    .err()
    .map(|error| error.to_string());
    assert_eq!(
        message.as_deref(),
        Some(
            "required Windows backend capability unavailable: capability=case-sensitive-query os_code=120 reason=unsupported; DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES=1"
        )
    );
}

#[test]
fn invalid_required_mode_configuration_fails_closed() {
    let message = gate_mode_from(Some(OsStr::new("true")))
        .err()
        .map(|error| error.to_string());
    assert_eq!(
        message.as_deref(),
        Some("DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES must be unset or exactly 1")
    );
}

#[test]
fn hosted_windows_and_release_gates_require_capabilities_with_visible_output()
-> Result<(), Box<dyn std::error::Error>> {
    for (workflow, source) in [
        (
            ".github/workflows/ci.yaml",
            include_str!("../../../.github/workflows/ci.yaml"),
        ),
        (
            ".github/workflows/release.yaml",
            include_str!("../../../.github/workflows/release.yaml"),
        ),
    ] {
        assert!(
            source.contains("DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES = '1'"),
            "{workflow} must enable required Windows backend capabilities"
        );
        assert!(
            source.contains(
                "cargo test --workspace --all-targets --all-features --locked -- --nocapture"
            ),
            "{workflow} must retain capability output in the hosted log"
        );
    }
    Ok(())
}

#[test]
fn planning_benchmark_workflow_is_manual_least_privilege_and_directional() {
    let workflow = normalize_workflow_source(include_str!(
        "../../../.github/workflows/benchmark-planning.yaml"
    ));

    assert!(workflow.contains("on:\n  workflow_dispatch:"));
    assert!(!workflow.contains("\n  push:"));
    assert!(!workflow.contains("\n  pull_request:"));
    assert!(workflow.contains(
        "count:\n        description: Entry count\n        required: true\n        type: choice\n        default: all\n        options:\n          - all\n          - \"100\"\n          - \"1000\"\n          - \"10000\""
    ));
    assert!(workflow.contains(
        "topology:\n        description: Parent topology\n        required: true\n        type: choice\n        default: all\n        options:\n          - all\n          - same-parent\n          - unique-parent\n          - deep-parent"
    ));
    assert!(workflow.contains(
        "repetitions:\n        description: Recorded repetitions after each warmup\n        required: true\n        type: choice\n        default: \"3\"\n        options:\n          - \"1\"\n          - \"3\""
    ));
    assert!(workflow.contains("permissions:\n  contents: read"));
    assert!(!workflow.contains(": write"));
    assert!(workflow.contains("cancel-in-progress: false"));
    assert!(workflow.contains("runs-on: windows-2025"));
    assert!(workflow.contains("timeout-minutes: 45"));
    assert!(
        workflow
            .contains("uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1")
    );
    assert!(workflow.contains("persist-credentials: false"));
    assert!(workflow.contains("rustup toolchain install 1.97.1 --profile minimal"));
    assert!(workflow.contains("$env:DARKRENAMER_BENCH_ROOT = $env:RUNNER_TEMP"));
    assert!(workflow.contains("$env:DARKRENAMER_BENCH_ROOT_PRIVATE = '1'"));
    assert!(workflow.contains("$env:DARKRENAMER_BENCH_EVIDENCE_CLASS = 'directional-hosted'"));
    assert!(workflow.contains("$env:DARKRENAMER_BENCH_MEDIA = 'virtual'"));
    assert!(workflow.contains("$env:DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES = '1'"));
    assert!(workflow.contains("foreach ($iteration in 0..$repetitions)"));
    assert!(workflow.contains(
        "cargo test --package darknamer-app --test rename_windows_backend benchmark_durable_production_path --locked --release -- --ignored --exact --nocapture --test-threads=1"
    ));
    assert!(!workflow.contains("actions/upload-artifact"));
    assert!(!workflow.contains("actions/cache"));
}

#[test]
fn workflow_contract_normalizes_windows_line_endings() {
    assert_eq!(
        normalize_workflow_source("on:\r\n  workflow_dispatch:\r\n"),
        "on:\n  workflow_dispatch:\n"
    );
}
