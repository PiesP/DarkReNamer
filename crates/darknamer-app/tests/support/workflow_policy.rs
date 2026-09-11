use std::collections::BTreeMap;

use serde::Deserialize;

#[derive(Deserialize)]
struct Workflow {
    #[serde(rename = "on")]
    triggers: BTreeMap<String, Option<Dispatch>>,
    #[serde(default)]
    permissions: BTreeMap<String, String>,
    concurrency: Option<Concurrency>,
    jobs: BTreeMap<String, Job>,
}

#[derive(Deserialize)]
struct Dispatch {
    #[serde(default)]
    inputs: BTreeMap<String, Input>,
}

#[derive(Deserialize)]
struct Input {
    required: Option<bool>,
    #[serde(rename = "type")]
    kind: Option<String>,
    default: Option<Scalar>,
    #[serde(default)]
    options: Vec<Scalar>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Scalar {
    String(String),
    Bool(bool),
    Integer(i64),
}

impl Scalar {
    fn text(&self) -> String {
        match self {
            Self::String(value) => value.clone(),
            Self::Bool(value) => value.to_string(),
            Self::Integer(value) => value.to_string(),
        }
    }
}

#[derive(Deserialize)]
struct Concurrency {
    #[serde(rename = "cancel-in-progress")]
    cancel_in_progress: bool,
}

#[derive(Deserialize)]
struct Job {
    #[serde(rename = "if")]
    condition: Option<String>,
    #[serde(rename = "runs-on")]
    runs_on: String,
    #[serde(default)]
    permissions: BTreeMap<String, String>,
    environment: Option<Environment>,
    strategy: Option<serde::de::IgnoredAny>,
    steps: Vec<Step>,
}

#[derive(Deserialize)]
struct Environment {
    name: String,
}

#[derive(Deserialize)]
struct Step {
    id: Option<String>,
    #[serde(rename = "if")]
    condition: Option<Scalar>,
    #[serde(rename = "continue-on-error")]
    continue_on_error: Option<Scalar>,
    uses: Option<String>,
    run: Option<String>,
    #[serde(default)]
    env: BTreeMap<String, Scalar>,
    #[serde(default)]
    with: BTreeMap<String, Scalar>,
}

struct Experiment<'a> {
    path: &'a str,
    source: &'a str,
    job: &'a str,
    retains_artifact: bool,
    required: &'a [&'a str],
    forbidden: &'a [&'a str],
}

fn parse(path: &str, source: &str) -> Result<Workflow, String> {
    yaml_serde::from_str(source).map_err(|error| format!("{path} is not valid YAML: {error}"))
}

fn require(condition: bool, message: impl Into<String>) -> Result<(), String> {
    if condition {
        Ok(())
    } else {
        Err(message.into())
    }
}

fn permissions(
    path: &str,
    actual: &BTreeMap<String, String>,
    expected: &[(&str, &str)],
) -> Result<(), String> {
    let expected = expected
        .iter()
        .map(|(name, access)| ((*name).to_owned(), (*access).to_owned()))
        .collect::<BTreeMap<_, _>>();
    require(
        actual == &expected,
        format!("{path} permissions must be {expected:?}, found {actual:?}"),
    )
}

fn manual_only(path: &str, workflow: &Workflow) -> Result<(), String> {
    require(
        workflow.triggers.len() == 1 && workflow.triggers.contains_key("workflow_dispatch"),
        format!("{path} must only support workflow_dispatch"),
    )
}

fn dispatch_inputs<'a>(
    path: &str,
    workflow: &'a Workflow,
) -> Result<&'a BTreeMap<String, Input>, String> {
    workflow
        .triggers
        .get("workflow_dispatch")
        .and_then(Option::as_ref)
        .map(|dispatch| &dispatch.inputs)
        .ok_or_else(|| format!("{path} must declare workflow_dispatch inputs"))
}

fn only_job<'a>(path: &str, workflow: &'a Workflow, name: &str) -> Result<&'a Job, String> {
    require(
        workflow.jobs.len() == 1,
        format!("{path} must contain exactly one job"),
    )?;
    workflow
        .jobs
        .get(name)
        .ok_or_else(|| format!("{path} must contain the {name} job"))
}

fn action_name(uses: &str) -> &str {
    uses.split_once('@').map_or(uses, |(name, _)| name)
}

fn action_is_immutable(uses: &str) -> bool {
    uses.split_once('@').is_some_and(|(_, revision)| {
        revision.len() == 40
            && revision
                .bytes()
                .all(|value| value.is_ascii_digit() || (b'a'..=b'f').contains(&value))
    })
}

fn action_policy(path: &str, job: &Job, allowed: &[&str]) -> Result<(), String> {
    for uses in job.steps.iter().filter_map(|step| step.uses.as_deref()) {
        require(
            allowed.contains(&action_name(uses)) && action_is_immutable(uses),
            format!("{path} action must be allowlisted and pinned to a lowercase commit: {uses}"),
        )?;
    }
    Ok(())
}

fn scalar_bool(value: Option<&Scalar>, default: bool) -> bool {
    value.map_or(default, |value| match value {
        Scalar::Bool(value) => *value,
        Scalar::String(value) => matches!(value.trim(), "true" | "${{ true }}"),
        Scalar::Integer(_) => false,
    })
}

fn steps_are_mandatory(path: &str, job: &Job) -> Result<(), String> {
    require(
        job.steps.iter().all(|step| {
            scalar_bool(step.condition.as_ref(), true)
                && !scalar_bool(step.continue_on_error.as_ref(), false)
        }),
        format!("{path} policy steps must execute and propagate failures"),
    )
}

fn is_hosted_windows_runner(label: &str) -> bool {
    label == "windows-latest"
        || label
            .strip_prefix("windows-")
            .and_then(|year| year.parse::<u16>().ok())
            .is_some_and(|year| year >= 2022)
}

fn simple_command(job: &Job, expected: &[&str]) -> bool {
    job.steps
        .iter()
        .filter_map(|step| step.run.as_deref())
        .any(|run| {
            let lines = run
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .collect::<Vec<_>>();
            lines.len() == 1 && lines[0].split_whitespace().eq(expected.iter().copied())
        })
}

fn actions<'a>(job: &'a Job, name: &str) -> Vec<&'a Step> {
    job.steps
        .iter()
        .filter(|step| step.uses.as_deref().map(action_name) == Some(name))
        .collect()
}

fn action_sequence(job: &Job) -> Vec<&str> {
    job.steps
        .iter()
        .filter_map(|step| step.uses.as_deref())
        .map(action_name)
        .collect()
}

fn with_is(step: &Step, name: &str, expected: &str) -> bool {
    step.with.get(name).map(Scalar::text).as_deref() == Some(expected)
}

fn script(job: &Job) -> String {
    job.steps
        .iter()
        .filter_map(|step| step.run.as_deref())
        .map(|run| {
            run.replace("`\r\n", " ")
                .replace("`\n", " ")
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn script_contract(
    path: &str,
    actual: &str,
    required: &[&str],
    forbidden: &[&str],
) -> Result<(), String> {
    for value in required {
        require(
            actual.contains(value),
            format!("{path} script contract is missing: {value}"),
        )?;
    }
    for value in forbidden {
        require(
            !actual.contains(value),
            format!("{path} script contract is forbidden: {value}"),
        )?;
    }
    Ok(())
}

fn checkout_is_read_only(path: &str, job: &Job) -> Result<(), String> {
    let checkouts = actions(job, "actions/checkout");
    require(
        checkouts.len() == 1
            && checkouts[0]
                .with
                .get("persist-credentials")
                .is_some_and(|value| matches!(value, Scalar::Bool(false))),
        format!("{path} must check out once without persisted credentials"),
    )
}

fn env_is_bound(path: &str, job: &Job, name: &str, expected: &str) -> Result<(), String> {
    let bindings = job
        .steps
        .iter()
        .filter_map(|step| step.env.get(name))
        .map(Scalar::text)
        .collect::<Vec<_>>();
    require(
        !bindings.is_empty() && bindings.iter().all(|value| value == expected),
        format!("{path} must bind every {name} occurrence to {expected}"),
    )
}

fn input_contract(
    path: &str,
    input: &Input,
    default: &str,
    options: &[&str],
) -> Result<(), String> {
    require(
        input.required == Some(true) && input.kind.as_deref() == Some("choice"),
        format!("{path} input must be a required choice"),
    )?;
    require(
        input.default.as_ref().map(Scalar::text).as_deref() == Some(default)
            && input.options.iter().map(Scalar::text).collect::<Vec<_>>() == options,
        format!("{path} input choices must be {options:?} with default {default}"),
    )
}

fn validate_experiment(experiment: &Experiment<'_>) -> Result<(), String> {
    let workflow = parse(experiment.path, experiment.source)?;
    manual_only(experiment.path, &workflow)?;
    permissions(
        experiment.path,
        &workflow.permissions,
        &[("contents", "read")],
    )?;
    require(
        workflow
            .concurrency
            .as_ref()
            .is_some_and(|concurrency| !concurrency.cancel_in_progress),
        format!(
            "{} must serialize runs without cancellation",
            experiment.path
        ),
    )?;
    let job = only_job(experiment.path, &workflow, experiment.job)?;
    require(
        is_hosted_windows_runner(&job.runs_on) && job.strategy.is_none(),
        format!(
            "{} must retain one serial hosted Windows job",
            experiment.path
        ),
    )?;
    permissions(experiment.path, &job.permissions, &[])?;
    require(
        job.environment.is_none(),
        format!("{} must not access an environment", experiment.path),
    )?;
    checkout_is_read_only(experiment.path, job)?;
    steps_are_mandatory(experiment.path, job)?;
    let allowed_actions = if experiment.retains_artifact {
        &["actions/checkout", "actions/upload-artifact"][..]
    } else {
        &["actions/checkout"][..]
    };
    action_policy(experiment.path, job, allowed_actions)?;
    for name in ["actions/attest", "actions/cache"] {
        require(
            actions(job, name).is_empty(),
            format!("{} must not use {name}", experiment.path),
        )?;
    }
    require(
        (actions(job, "actions/upload-artifact").len() == 1) == experiment.retains_artifact,
        format!("{} artifact retention differs from policy", experiment.path),
    )?;
    script_contract(
        experiment.path,
        &script(job),
        experiment.required,
        &[
            experiment.forbidden,
            &[
                "cargo publish",
                "gh release",
                "git ls-remote",
                "git push",
                "DARKRENAMER_BENCH_EVIDENCE_CLASS = 'physical'",
                "DARKRENAMER_BENCH_MEDIA = 'ssd'",
                "DARKRENAMER_BENCH_MEDIA = 'hdd'",
            ],
        ]
        .concat(),
    )
}

pub(super) fn validate_hosted_capability_gates() -> Result<(), String> {
    for (path, source) in [
        (
            ".github/workflows/ci.yaml",
            include_str!("../../../../.github/workflows/ci.yaml"),
        ),
        (
            ".github/workflows/release.yaml",
            include_str!("../../../../.github/workflows/release.yaml"),
        ),
    ] {
        let workflow = parse(path, source)?;
        if path.ends_with("ci.yaml") {
            let quality = workflow
                .jobs
                .get("quality")
                .ok_or_else(|| format!("{path} must retain its Ubuntu quality job"))?;
            let windows = workflow
                .jobs
                .get("windows")
                .ok_or_else(|| format!("{path} must retain its Windows job"))?;
            steps_are_mandatory(path, quality)?;
            action_policy(path, quality, &["actions/checkout"])?;
            require(
                quality.runs_on.starts_with("ubuntu-")
                    && simple_command(
                        quality,
                        &["./scripts/test-tooling.ps1", "-Platform", "Ubuntu"],
                    )
                    && simple_command(
                        windows,
                        &["./scripts/test-tooling.ps1", "-Platform", "Windows"],
                    ),
                format!("{path} must run the tooling suite on Ubuntu and Windows"),
            )?;
        }
        let job = workflow
            .jobs
            .get("windows")
            .ok_or_else(|| format!("{path} must retain its Windows job"))?;
        require(
            is_hosted_windows_runner(&job.runs_on),
            format!("{path} must retain its hosted Windows lane"),
        )?;
        steps_are_mandatory(path, job)?;
        let allowed_actions = if path.ends_with("release.yaml") {
            &[
                "actions/checkout",
                "actions/attest",
                "actions/upload-artifact",
            ][..]
        } else {
            &["actions/checkout"][..]
        };
        action_policy(path, job, allowed_actions)?;
    }
    Ok(())
}

pub(super) fn validate_release_handoff_policy() -> Result<(), String> {
    let candidate_path = ".github/workflows/release.yaml";
    let candidate = parse(
        candidate_path,
        include_str!("../../../../.github/workflows/release.yaml"),
    )?;
    manual_only(candidate_path, &candidate)?;
    permissions(
        candidate_path,
        &candidate.permissions,
        &[("contents", "read")],
    )?;
    let candidate_job = only_job(candidate_path, &candidate, "windows")?;
    require(
        candidate_job.condition.as_deref() == Some("github.ref == 'refs/heads/master'")
            && is_hosted_windows_runner(&candidate_job.runs_on),
        "candidate workflow must run only on master in its hosted Windows lane",
    )?;
    permissions(
        candidate_path,
        &candidate_job.permissions,
        &[
            ("artifact-metadata", "write"),
            ("attestations", "write"),
            ("contents", "read"),
            ("id-token", "write"),
        ],
    )?;
    checkout_is_read_only(candidate_path, candidate_job)?;
    steps_are_mandatory(candidate_path, candidate_job)?;
    action_policy(
        candidate_path,
        candidate_job,
        &[
            "actions/checkout",
            "actions/attest",
            "actions/upload-artifact",
        ],
    )?;
    let checkout = actions(candidate_job, "actions/checkout")[0];
    require(
        checkout.with.get("ref").map(Scalar::text).as_deref() == Some("master"),
        "candidate workflow must check out master",
    )?;
    let attestations = actions(candidate_job, "actions/attest");
    let uploads = actions(candidate_job, "actions/upload-artifact");
    require(
        attestations.len() == 2
            && attestations
                .iter()
                .any(|step| with_is(step, "subject-path", "dist/*"))
            && attestations.iter().any(|step| {
                with_is(step, "subject-path", "dist/DarkReNamer.exe")
                    && with_is(step, "sbom-path", "dist/DarkReNamer.cdx.json")
            })
            && uploads.len() == 1
            && uploads[0].id.as_deref() == Some("candidate_artifact")
            && with_is(uploads[0], "path", "dist/")
            && with_is(uploads[0], "if-no-files-found", "error")
            && action_sequence(candidate_job)
                == [
                    "actions/checkout",
                    "actions/attest",
                    "actions/attest",
                    "actions/upload-artifact",
                ],
        "candidate must attest and retain an addressable immutable handoff",
    )?;
    script_contract(candidate_path, &script(candidate_job), &[], &["gh release"])?;
    let promotion_path = ".github/workflows/promote-release.yaml";
    let promotion = parse(
        promotion_path,
        include_str!("../../../../.github/workflows/promote-release.yaml"),
    )?;
    manual_only(promotion_path, &promotion)?;
    let inputs = dispatch_inputs(promotion_path, &promotion)?;
    let names = [
        "candidate_artifact_id",
        "candidate_run_attempt",
        "candidate_run_id",
        "candidate_source_sha",
        "expected_exe_sha256",
        "release_tag",
    ];
    require(
        inputs.keys().map(String::as_str).eq(names)
            && inputs.values().all(|input| {
                input.required == Some(true)
                    && input.kind.as_deref() == Some("string")
                    && input.default.is_none()
                    && input.options.is_empty()
            }),
        "promotion inputs must bind the complete immutable candidate identity",
    )?;
    permissions(
        promotion_path,
        &promotion.permissions,
        &[("actions", "read"), ("contents", "read")],
    )?;
    let job = only_job(promotion_path, &promotion, "publish")?;
    require(
        job.condition.as_deref() == Some("github.ref == 'refs/heads/master'")
            && is_hosted_windows_runner(&job.runs_on)
            && job.environment.as_ref().map(|value| value.name.as_str()) == Some("release"),
        "promotion must run only on master in the protected release environment",
    )?;
    permissions(
        promotion_path,
        &job.permissions,
        &[
            ("actions", "read"),
            ("attestations", "read"),
            ("contents", "write"),
        ],
    )?;
    checkout_is_read_only(promotion_path, job)?;
    steps_are_mandatory(promotion_path, job)?;
    action_policy(
        promotion_path,
        job,
        &["actions/checkout", "actions/download-artifact"],
    )?;
    let downloads = actions(job, "actions/download-artifact");
    require(
        downloads.len() == 1
            && with_is(
                downloads[0],
                "artifact-ids",
                "${{ inputs.candidate_artifact_id }}",
            )
            && with_is(downloads[0], "run-id", "${{ inputs.candidate_run_id }}")
            && with_is(downloads[0], "github-token", "${{ github.token }}")
            && with_is(downloads[0], "repository", "${{ github.repository }}")
            && with_is(downloads[0], "path", "dist")
            && action_sequence(job) == ["actions/checkout", "actions/download-artifact"],
        "promotion must download the exact artifact from the selected candidate run",
    )?;
    require(
        actions(job, "actions/attest").is_empty(),
        "promotion must preserve the candidate provenance without creating a new attestation",
    )?;
    for (name, input) in [
        ("CANDIDATE_RUN_ID", "candidate_run_id"),
        ("CANDIDATE_RUN_ATTEMPT", "candidate_run_attempt"),
        ("CANDIDATE_ARTIFACT_ID", "candidate_artifact_id"),
        ("CANDIDATE_SOURCE_SHA", "candidate_source_sha"),
        ("EXPECTED_EXE_SHA256", "expected_exe_sha256"),
        ("RELEASE_TAG", "release_tag"),
    ] {
        env_is_bound(
            promotion_path,
            job,
            name,
            &format!("${{{{ inputs.{input} }}}}"),
        )?;
    }
    let promotion_script = script(job);
    script_contract(
        promotion_path,
        &promotion_script,
        &[],
        &["cargo build", "cargo test", "rustup toolchain install"],
    )
}

pub(super) fn validate_experimental_workflows() -> Result<(), String> {
    let planning_path = ".github/workflows/benchmark-planning.yaml";
    let planning_source = include_str!("../../../../.github/workflows/benchmark-planning.yaml");
    let planning = parse(planning_path, planning_source)?;
    let inputs = dispatch_inputs(planning_path, &planning)?;
    for (name, default, options) in [
        ("count", "all", &["all", "100", "1000", "10000"][..]),
        (
            "topology",
            "all",
            &["all", "same-parent", "unique-parent", "deep-parent"][..],
        ),
        (
            "variant",
            "baseline",
            &["baseline", "validation-skip-estimate"][..],
        ),
        ("repetitions", "3", &["1", "3"][..]),
    ] {
        let input = inputs
            .get(name)
            .ok_or_else(|| format!("{planning_path} is missing input {name}"))?;
        input_contract(planning_path, input, default, options)?;
    }
    let planning_job = planning
        .jobs
        .get("benchmark")
        .ok_or_else(|| format!("{planning_path} is missing its benchmark job"))?;
    for (name, input) in [
        ("SELECTED_COUNT", "count"),
        ("SELECTED_TOPOLOGY", "topology"),
        ("SELECTED_VARIANT", "variant"),
        ("RECORDED_REPETITIONS", "repetitions"),
    ] {
        env_is_bound(
            planning_path,
            planning_job,
            name,
            &format!("${{{{ inputs.{input} }}}}"),
        )?;
    }

    for experiment in [
        Experiment {
            path: planning_path,
            source: planning_source,
            job: "benchmark",
            retains_artifact: false,
            required: &[
                "DARKRENAMER_BENCH_ROOT_PRIVATE = '1'",
                "DARKRENAMER_BENCH_EVIDENCE_CLASS = 'directional-hosted'",
                "DARKRENAMER_BENCH_MEDIA = 'virtual'",
                "DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES = '1'",
            ],
            forbidden: &[],
        },
        Experiment {
            path: ".github/workflows/binary-size-matrix.yaml",
            source: include_str!("../../../../.github/workflows/binary-size-matrix.yaml"),
            job: "measure",
            retains_artifact: true,
            required: &[
                "id = 'app-3-core-3'",
                "id = 'app-s-core-3'",
                "id = 'app-s-core-s'",
                "id = 'app-2-core-3'",
                "binary-size-matrix.json",
            ],
            forbidden: &["cargo test"],
        },
        Experiment {
            path: ".github/workflows/profile-benchmark-matrix.yaml",
            source: include_str!("../../../../.github/workflows/profile-benchmark-matrix.yaml"),
            job: "benchmark",
            retains_artifact: true,
            required: &[
                "id = 'app-3-core-3'",
                "id = 'app-s-core-3'",
                "id = 'app-s-core-s'",
                "id = 'app-2-core-3'",
                "filesystem_mutation'] -cne 'none'",
                "scope'] -cne 'cpu-micro-workloads'",
                "recorded_iterations = 5",
                "workload_count = 10000",
                "selection_evidence = $false",
                "profile-benchmark-matrix.json",
            ],
            forbidden: &["WindowsRenameBackend", "FileJournal"],
        },
        Experiment {
            path: ".github/workflows/profile-planning-matrix.yaml",
            source: include_str!("../../../../.github/workflows/profile-planning-matrix.yaml"),
            job: "benchmark",
            retains_artifact: true,
            required: &[
                "id = 'app-3-core-3'",
                "id = 'app-s-core-3'",
                "$topologies = @('same-parent', 'unique-parent', 'deep-parent')",
                "DARKRENAMER_BENCH_EVIDENCE_CLASS = 'directional-hosted'",
                "DARKRENAMER_BENCH_MEDIA = 'virtual'",
                "DARKRENAMER_BENCH_VARIANT = 'baseline'",
                "DARKRENAMER_BENCH_COUNT = '10000'",
                "DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES = '1'",
                "execution_performed = $false",
                "physical_storage_or_desktop_acceptance = $false",
                "selection_evidence = $false",
                "filesystem_mutation = 'owned-temporary-fixtures-only'",
                "recorded_iterations = 5",
                "profile-planning-matrix.json",
            ],
            forbidden: &["id = 'app-s-core-s'", "id = 'app-2-core-3'"],
        },
    ] {
        validate_experiment(&experiment)?;
    }
    Ok(())
}

#[test]
fn experiment_policy_rejects_automatic_triggers_and_write_permissions() {
    let fixture = r#"
name: unsafe experiment
on:
  workflow_dispatch:
  push:
permissions:
  contents: read
jobs:
  benchmark:
    runs-on: windows-2028
    steps: []
"#;
    let policy = Experiment {
        path: "unsafe-fixture.yaml",
        source: fixture,
        job: "benchmark",
        retains_artifact: false,
        required: &[],
        forbidden: &[],
    };
    let automatic = validate_experiment(&policy);
    assert!(
        automatic
            .as_ref()
            .is_err_and(|error| error.contains("only support workflow_dispatch"))
    );

    let write_fixture = fixture
        .replace("  push:\n", "")
        .replace("contents: read", "contents: write");
    let write = validate_experiment(&Experiment {
        source: &write_fixture,
        ..policy
    });
    assert!(
        write
            .as_ref()
            .is_err_and(|error| error.contains("permissions must be"))
    );
}

#[test]
fn experiment_policy_accepts_equivalent_yaml_layout() {
    let fixture = r#"
jobs:
  benchmark:
    steps:
      - with: { persist-credentials: false }
        uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      - run: Write-Host ready
    runs-on: windows-2025
concurrency: { cancel-in-progress: false }
permissions: { contents: read }
'on': { workflow_dispatch: null }
name: equivalent experiment
"#;
    let result = validate_experiment(&Experiment {
        path: "equivalent-fixture.yaml",
        source: fixture,
        job: "benchmark",
        retains_artifact: false,
        required: &[],
        forbidden: &[],
    });
    assert!(result.is_ok(), "{result:?}");
}

#[test]
fn experiment_policy_rejects_unpinned_unapproved_and_non_propagating_steps() {
    let fixture = r#"
name: policy fixture
on: { workflow_dispatch: null }
permissions: { contents: read }
concurrency: { cancel-in-progress: false }
jobs:
  benchmark:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: { persist-credentials: false }
      - run: cargo test
"#;
    let validate = |source: &str| {
        validate_experiment(&Experiment {
            path: "policy-fixture.yaml",
            source,
            job: "benchmark",
            retains_artifact: false,
            required: &[],
            forbidden: &[],
        })
    };

    let moving_ref = fixture.replace("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "main");
    assert!(
        validate(&moving_ref)
            .as_ref()
            .is_err_and(|error| error.contains("pinned to a lowercase commit"))
    );
    let uppercase_ref = fixture.replace(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    );
    assert!(
        validate(&uppercase_ref)
            .as_ref()
            .is_err_and(|error| error.contains("lowercase commit"))
    );
    let wrong_runner = fixture.replace("windows-latest", "ubuntu-latest");
    assert!(
        validate(&wrong_runner)
            .as_ref()
            .is_err_and(|error| error.contains("Windows"))
    );
    let unapproved = fixture.replace(
        "      - run: cargo test",
        "      - uses: vendor/publish-action@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n      - run: cargo test",
    );
    assert!(
        validate(&unapproved)
            .as_ref()
            .is_err_and(|error| error.contains("allowlisted"))
    );
    let disabled = fixture.replace(
        "      - run: cargo test",
        "      - if: false\n        run: cargo test",
    );
    assert!(
        validate(&disabled)
            .as_ref()
            .is_err_and(|error| error.contains("must execute"))
    );
    let ignored_failure = fixture.replace(
        "      - run: cargo test",
        "      - continue-on-error: true\n        run: cargo test",
    );
    assert!(
        validate(&ignored_failure)
            .as_ref()
            .is_err_and(|error| error.contains("propagate failures"))
    );
}

#[test]
fn promotion_contract_rejects_rebuilding() {
    let result = script_contract(
        "promotion-fixture.yaml",
        "./scripts/validate-release-handoff.ps1 cargo build --release gh release create",
        &[
            "./scripts/validate-release-handoff.ps1",
            "gh release create",
        ],
        &["cargo build", "cargo test"],
    );
    assert!(
        result
            .as_ref()
            .is_err_and(|error| error.contains("cargo build"))
    );
}
