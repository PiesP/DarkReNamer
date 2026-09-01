#[path = "support/windows_capabilities.rs"]
mod windows_capabilities;

use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::PathBuf;

use windows_capabilities::{GateMode, gate_mode_from, unavailable_in_mode};

fn normalize_workflow_source(source: &str) -> String {
    source.replace("\r\n", "\n")
}

fn repository_file(path: &str) -> Result<String, Box<dyn std::error::Error>> {
    let repository = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    Ok(fs::read_to_string(repository.join(path))?)
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
fn release_workflows_promote_the_immutable_candidate_without_rebuilding()
-> Result<(), Box<dyn std::error::Error>> {
    let candidate = normalize_workflow_source(&repository_file(".github/workflows/release.yaml")?);
    let promotion =
        normalize_workflow_source(&repository_file(".github/workflows/promote-release.yaml")?);
    let ci = normalize_workflow_source(&repository_file(".github/workflows/ci.yaml")?);
    let (non_windows_ci, windows_ci) = ci
        .split_once("\n  windows:\n")
        .ok_or("CI workflow must retain a dedicated Windows job")?;

    assert!(candidate.contains("on:\n  workflow_dispatch:"));
    assert!(!candidate.contains("\n  push:"));
    assert!(candidate.contains("if: github.ref == 'refs/heads/master'"));
    assert!(candidate.contains("ref: master"));
    assert!(candidate.contains("git ls-remote origin refs/heads/master"));
    assert!(candidate.contains("./scripts/prepare-release-cyclonedx.ps1"));
    assert!(candidate.contains("[Guid]::NewGuid().ToString('D').ToLowerInvariant()"));
    assert!(candidate.contains("name: Attest candidate build provenance"));
    assert!(candidate.contains("name: Attest candidate executable SBOM"));
    assert!(candidate.contains("id: candidate_artifact"));
    assert!(candidate.contains("artifact-id: ${{ steps.candidate_artifact.outputs.artifact-id }}"));
    assert!(!candidate.contains("gh release create"));

    assert!(promotion.contains("on:\n  workflow_dispatch:\n    inputs:"));
    for input in [
        "candidate_run_id:",
        "candidate_run_attempt:",
        "candidate_artifact_id:",
        "candidate_source_sha:",
        "expected_exe_sha256:",
        "release_tag:",
    ] {
        assert!(
            promotion.contains(input),
            "missing promotion input: {input}"
        );
    }
    assert!(promotion.contains("actions: read"));
    assert!(promotion.contains("contents: write"));
    assert!(promotion.contains("runs-on: windows-2025"));
    assert!(!promotion.contains("runs-on: ubuntu-24.04"));
    assert!(promotion.contains("artifact-ids: ${{ inputs.candidate_artifact_id }}"));
    assert!(promotion.contains("github-token: ${{ github.token }}"));
    assert!(promotion.contains("repository: ${{ github.repository }}"));
    assert!(promotion.contains("run-id: ${{ inputs.candidate_run_id }}"));
    assert!(promotion.contains("./scripts/validate-release-candidate-metadata.ps1"));
    assert!(promotion.contains("./scripts/validate-release-handoff.ps1"));
    assert!(promotion.contains("[regex]::Matches($cargo, '(?m)^version = \"([^\"]+)\"\\r?$')"));
    assert!(promotion.contains("if ($versionMatches.Count -ne 1)"));
    assert!(promotion.contains("gh attestation verify"));
    assert!(promotion.contains("--signer-workflow"));
    assert!(promotion.contains("--source-digest $env:CANDIDATE_SOURCE_SHA"));
    assert!(promotion.contains("--source-ref refs/heads/master"));
    assert!(promotion.contains("--deny-self-hosted-runners"));
    assert_eq!(
        promotion
            .matches("git ls-remote origin refs/heads/master")
            .count(),
        1,
        "promotion must revalidate live master immediately before publication"
    );
    assert!(promotion.contains("gh release create $env:RELEASE_TAG"));
    assert!(!promotion.contains("gh release view"));
    assert!(promotion.contains("GitHub prerelease publication failed"));
    assert!(promotion.contains("--verify-tag"));
    assert!(promotion.contains("--prerelease"));
    assert!(promotion.contains("Source-complete Windows prerelease"));
    for forbidden in [
        "cargo build",
        "cargo test",
        "rustup toolchain install",
        "actions/attest@",
    ] {
        assert!(
            !promotion.contains(forbidden),
            "promotion workflow must not rebuild or replace provenance: {forbidden}"
        );
    }
    assert!(!promotion.contains("-ExpectedRunId '${{"));
    for script in [
        "./scripts/test-release-candidate-metadata-validator.ps1",
        "./scripts/test-prepare-release-cyclonedx.ps1",
        "./scripts/test-release-workflow-powershell-syntax.ps1",
    ] {
        assert_eq!(
            non_windows_ci.matches(script).count(),
            1,
            "{script} must run exactly once before the Windows CI job"
        );
        assert_eq!(
            windows_ci.matches(script).count(),
            1,
            "{script} must run exactly once in the Windows CI job"
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
        "variant:\n        description: Planning measurement variant\n        required: true\n        type: choice\n        default: baseline\n        options:\n          - baseline\n          - validation-skip-estimate"
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
    assert!(workflow.contains("SELECTED_VARIANT: ${{ inputs.variant }}"));
    assert!(workflow.contains("$env:DARKRENAMER_BENCH_VARIANT = $env:SELECTED_VARIANT"));
    assert!(workflow.contains("$env:DARKRENAMER_BENCH_SOURCE_SHA = $env:GITHUB_SHA"));
    assert!(workflow.contains("$env:DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES = '1'"));
    assert!(workflow.contains("foreach ($iteration in 0..$repetitions)"));
    assert!(workflow.contains(
        "cargo test --package darknamer-app --test rename_windows_backend benchmark_durable_production_path --locked --release -- --ignored --exact --nocapture --test-threads=1"
    ));
    assert!(!workflow.contains("actions/upload-artifact"));
    assert!(!workflow.contains("actions/cache"));
}

#[test]
fn binary_size_matrix_is_manual_serial_and_non_publishing() {
    let workflow = normalize_workflow_source(include_str!(
        "../../../.github/workflows/binary-size-matrix.yaml"
    ));

    assert!(workflow.contains("on:\n  workflow_dispatch:"));
    assert!(!workflow.contains("\n  push:"));
    assert!(!workflow.contains("\n  pull_request:"));
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
    assert!(!workflow.contains("strategy:"));
    assert!(!workflow.contains("${{ matrix."));
    assert_eq!(
        workflow.matches("foreach ($variant in $variants)").count(),
        1
    );
    for declaration in [
        "id = 'current-3-3'; app_opt_level = '3'; core_opt_level = '3'",
        "id = 'app-s-core-3'; app_opt_level = 's'; core_opt_level = '3'",
        "id = 'app-s-core-s'; app_opt_level = 's'; core_opt_level = 's'",
        "id = 'app-2-core-3'; app_opt_level = '2'; core_opt_level = '3'",
    ] {
        assert!(
            workflow.contains(declaration),
            "missing variant {declaration}"
        );
    }
    assert!(workflow.contains("[profile.release.package.darknamer-app]"));
    assert!(workflow.contains("[profile.release.package.darknamer-core]"));
    assert!(workflow.contains("$env:CARGO_TARGET_DIR = $variantTarget"));
    assert!(workflow.contains(
        "cargo --config $configPath build --release --locked `\n              --package darknamer-app --bin DarkReNamer"
    ));
    assert!(workflow.contains("SOURCE_DATE_EPOCH=$sourceEpoch"));
    assert!(workflow.contains("cargo_config_sha256 = $configHash"));
    assert!(workflow.contains("cargo_toml_sha256 = (Get-FileHash"));
    assert!(workflow.contains("cargo_lock_sha256 = (Get-FileHash"));
    assert!(workflow.contains("rust_toolchain_toml_sha256 = (Get-FileHash"));
    assert!(workflow.contains("./scripts/measure-windows-binary.ps1"));
    assert!(workflow.contains("binary-size-matrix.json"));
    assert!(workflow.contains(
        "uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1"
    ));
    for prohibited in [
        "actions/attest@",
        "actions/cache@",
        "artifact-metadata: write",
        "attestations: write",
        "cargo publish",
        "cargo test",
        "gh release",
        "git ls-remote",
        "id-token: write",
    ] {
        assert!(
            !workflow.contains(prohibited),
            "binary-size experiment must not contain {prohibited}"
        );
    }
}

#[test]
fn workflow_contract_normalizes_windows_line_endings() {
    assert_eq!(
        normalize_workflow_source("on:\r\n  workflow_dispatch:\r\n"),
        "on:\n  workflow_dispatch:\n"
    );
}
