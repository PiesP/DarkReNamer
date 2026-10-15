# Historical Windows acceptance

This document preserves retired release comparisons, legacy manual desktop,
physical-media and observer procedures, and completed source-specific GUI
investigations. It is historical reference, not a second release contract.

The active contract is
[VM-Automated release validation](../../SAFETY.md#vm-automated-release-validation).
It uses source-bound automated checks and a fixed Windows VM profile. Nothing
in this history upgrades an old failure, `not-run`, or `review_required` result,
and the existence of these procedures does not show that any acceptance run
was completed.

## Retired release-profile comparisons

The release-profile size, CPU micro-workload, and hosted planning comparisons
were manual experiments for choosing the application's release settings. The
selected settings in `Cargo.toml` use size optimization for the app and level 3
for the core, as committed in
[`db45463fb01e56f84b5a17c5b90bfee70f3f918f`](https://github.com/PiesP/DarkReNamer/commit/db45463fb01e56f84b5a17c5b90bfee70f3f918f).
No current release workflow calls the three comparison workflows. Their last
available Actions runs are from 2026-09-01: [binary size](https://github.com/PiesP/DarkReNamer/actions/runs/33532232816),
[CPU micro-workloads](https://github.com/PiesP/DarkReNamer/actions/runs/33532232768),
and [hosted planning](https://github.com/PiesP/DarkReNamer/actions/runs/33534448904).
Those runs report success, but their artifact listings are empty; no numerical
comparison or full Windows acceptance result is asserted here.

To reproduce a comparison for a new release-profile decision, inspect the exact
pre-retirement source at
[`83a3bd73a07ee642073bc46b8a9481e81b8c891e`](https://github.com/PiesP/DarkReNamer/tree/83a3bd73a07ee642073bc46b8a9481e81b8c891e):
`.github/workflows/binary-size-matrix.yaml`,
`.github/workflows/profile-benchmark-matrix.yaml`, or
`.github/workflows/profile-planning-matrix.yaml`. That revision also contains
their `scripts/resolve-source-matrix-metadata.ps1` and
`scripts/get-git-blob-sha256.ps1` helpers, the
`crates/darknamer-app/tests/profile_benchmarks.rs` CPU harness, and dedicated
tooling tests. Use the selected workflow's `workflow_dispatch` inputs and steps
on a supported Windows runner with a pinned source and toolchain; record fresh
measurements and source identity before making a new decision. The current
`benchmark-planning.yaml` remains available for a separate, directional
planning investigation.

## Historical evidence boundary

Formal desktop acceptance was recorded in an external, path-free JSON artifact
bound to a full source SHA and the tested `DarkReNamer.exe` filename and
SHA-256. Evidence produced from an Actions handoff also recorded its workflow
run. Screenshots remained external and were bound by filename, dimensions,
digest, UI or scenario target, appearance, surface, and the same executable
digest.

The standalone draft generator, benchmark importer, evidence validator, release
acceptance validator, their four dedicated suites, visual fixture and schema
were retired from the active tree. Reproduce them from immutable pre-retirement
commit [`c6c81b742f1490759de811202813aa0f2551f198`](https://github.com/PiesP/DarkReNamer/tree/c6c81b742f1490759de811202813aa0f2551f198),
using that revision's `DEVELOPMENT.md` and `scripts/test-tooling.ps1 -Scope Historical`.
They require PowerShell 7.4 or newer and Git; binary/handoff validation also needs
the original source-bound executable, handoff and private external evidence.
Physical-media and desktop procedures require their actual Windows environment.
Use each artifact's recorded source revision for its original tool/schema
contract; the pre-retirement revision is a reproduction entrypoint, not a claim
that old evidence belongs to that source.

Current campaign observers, v1/v2 profiles and independent verification remain
active. GUI regression and Wine gallery tests remain opt-in with
`-Scope Diagnostics`; see [Tooling tests](../../DEVELOPMENT.md#tooling-tests).

Evidence files, screenshots, traces, benchmark roots, operator or machine
identities, local paths, volume serials, and detailed narratives remain outside
Git. An external visual root must be immutable for validation and writable only
by the acceptance operator. Static reparse checks do not protect against a
different local process replacing files during validation.

## Historical formal matrix

The legacy formal gate required all of the following, bound to one Windows 11
x64 artifact and source:

- passed UI results at 100%, 125%, 150%, 200%, 250%, and 300% DPI in both
  normal and high-contrast modes;
- a main-workbench PNG for every required UI cell, with normal captures covering
  System, Light, and Dark and high-contrast captures using Forced Colors;
- visual coverage of the native menu, advanced appearance window, input prompt,
  common dialog, confirmation TaskDialog, and recovery window;
- passed keyboard-only, accessibility-tool, Explorer drag-and-drop, common
  dialog, clipboard, worker-cancellation, worker-close, startup-recovery,
  recovery-export, and Intent-only candidate-discard scenarios;
- same-parent 100, 1,000, and 10,000 entry benchmarks on physical NTFS SSD
  media, plus the same HDD rows or an explicit hardware-unavailable reason for
  each HDD target; and
- a passed application-process crash trial plus a separately authorized, passed
  VM hard-reset or storage-fault trial.

Physical power loss was an optional, stronger and distinct trial class. Process
exit, VM hard reset, storage fault injection, and physical power loss never
substituted for one another. A failed or residue-producing attempt could not be
reclassified as unavailable. Filesystems other than NTFS could be recorded in a
draft, but could not pass the formal v0.1 gate.

Drafts kept every missing target as `not-run` with a target-bound reason. They
did not convert missing work into passing evidence. Existing Windows 10 rows
were optional observations and could not replace required Windows 11 coverage.

These requirements are not the current VM-Automated matrix. Current validation
does not claim physical-device performance, physical power-loss, VM reset or
storage-fault durability, actual IME or Explorer drag-and-drop, or human visual
or comprehensive assistive-technology acceptance. Those areas remain
unverified unless separately executed and recorded in their actual environment.

## Legacy physical-media benchmarks

The ignored Windows `benchmark_durable_production_path` integration benchmark
used the production planner, `FileJournal`, and handle-relative rename backend.
Its historical physical matrix crossed SSD and HDD media with 100, 1,000, and
10,000 entries and `same-parent`, `unique-parent`, and `deep-parent` topologies.
Each cell used iteration 0 as warmup and recorded iterations 1 through 5:

```powershell
$env:DARKRENAMER_BENCH_ROOT = 'D:\darkrenamer-benchmark-root'
$env:DARKRENAMER_BENCH_MEDIA = 'hdd'
$env:DARKRENAMER_BENCH_ROOT_PRIVATE = '1'
$env:DARKRENAMER_BENCH_EVIDENCE_CLASS = 'physical'
$env:DARKRENAMER_BENCH_VARIANT = 'baseline'
$env:DARKRENAMER_BENCH_SOURCE_SHA = (git rev-parse HEAD).Trim()
$env:DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES = '1'
foreach ($count in 100, 1000, 10000) {
  foreach ($topology in 'same-parent', 'unique-parent', 'deep-parent') {
    foreach ($iteration in 0..5) {
      $env:DARKRENAMER_BENCH_COUNT = "$count"
      $env:DARKRENAMER_BENCH_TOPOLOGY = $topology
      $env:DARKRENAMER_BENCH_ITERATION = "$iteration"
      cargo test --package darknamer-app --test rename_windows_backend `
        benchmark_durable_production_path --locked --release -- `
        --ignored --exact --nocapture --test-threads=1
      if ($LASTEXITCODE -ne 0) { throw 'Benchmark failed.' }
    }
  }
}
```

The selected root had to be an existing private root on the named physical
device, used from a non-elevated session. The media label was operator-supplied
context rather than an automatic hardware claim. Only NTFS physical `baseline`
`same-parent` rows could populate historical formal evidence. Hosted ephemeral
or virtual storage, warmup output, `unique-parent`, `deep-parent`, and the
`validation-skip-estimate` variant remained diagnostic.

Historical recorded values used the median planning and execution time from all
five successful post-warmup iterations after clean fixture removal. A fresh
baseline was required for the exact source, instrumentation revision, machine,
volume, power mode, toolchain, count, and topology. Missing output after work
began could indicate cleanup failure and was unusable. The skip estimate never
established behavioral parity or waived the separate physical SSD and HDD
evidence needed for a production optimization decision.

The retired `scripts/add-windows-acceptance-benchmark.ps1` imported exactly five
private, source-bound logs and a path-free `benchmark-context.json` into a new draft. It
never edited evidence in place or overwrote the output. Inputs and output parents
had to remain external, private, and free of reparse points.

The ignored preview diagnostic measured validation and Windows UTF-16 path-key
generation, not ListView repaint latency:

```powershell
cargo test -p darknamer-app --lib `
  windows::list_view::native_tests::measure_preview_validation_with_production_windows_path_keys `
  --locked --release -- --ignored --exact --nocapture --test-threads=1
```

Interactive preview responsiveness still required a separate source-bound
Windows UI observation.

## Standalone historical observers

The current campaign controller stages its own observers. The standalone
procedures below are retained only for diagnosing or interpreting historical
formal acceptance:

- [`scripts/windows-vm-acceptance.ps1`](../../scripts/windows-vm-acceptance.ps1)
  records UI Automation, keyboard import and prefix entry, Apply cancellation
  and confirmation, filesystem contents and identities, screenshots, and normal
  close. Historical formal use required operator review of the screenshots.
- [`scripts/windows-vm-recovery-acceptance.ps1`](../../scripts/windows-vm-recovery-acceptance.ps1)
  observes process-crash recovery, worker cancellation, or ordinary close
  during a partial transaction and verifies names, contents, identities,
  journal state, and cleanup.

Both observers reuse a source-bound VM test bundle. Keep `bundle.json`, the
guest runner, listed binaries, `tooling-bundle.json`, `tooling-loader.ps1`, and
the selected role's complete flat dependency closure from one source. Check the
manifest with:

```bash
python3 scripts/update-tooling-bundle.py --check
```

Run only one observer at a time in the bundle account's unlocked, non-elevated
Windows PowerShell desktop. Pass `-BundleRoot`, `-ExpectedSessionId`,
`-OutputRoot`, and `-ExpectedScriptSha256` explicitly. Record the observer hash
separately from the bundle source and executable digests. Retain failed-session
evidence instead of replacing it with a retry.

The UI observer's `-HighContrast` mode temporarily changes Windows state. A
separate rescue invocation with `-RestoreHighContrastOnly` and the same bindings
must be arranged before the mode starts, and the observer and rescue snapshot
must remain available until restoration is verified.

The recovery observer's `ProcessCrash` mode terminates only its production
application after a partial fixture rename, then relaunches the same executable
with the same journal and profile. `WorkerCancellation` and `WorkerClose` use
the enabled cancel control or ordinary close. A missed interruption boundary is
a failed run. These observers do not reset the VM, inject storage faults, change
DPI settings, or certify either the historical full matrix or current release
matrix.

## Historical GUI diagnostics

The source-bound GUI regression runner remains useful as a diagnostic:

```bash
python3 -I scripts/run-gui-regression.py \
  --output-root /absolute/new/external-output \
  --connection-profile /absolute/private/connection.json
```

It expects a clean checkout, a private connection profile, a Windows 11 x64
guest, PowerShell 7.4 or newer, and a trusted managed desktop helper that
supports explicit display geometry. It runs fixed light and dark geometry,
DPI, text-scale, and tooltip cells, binds inputs and outputs, and validates the
result with `scripts/validate-gui-regression-evidence.py`.

Requested display settings must match the application's observed monitor
geometry and DPI. RDP smart sizing or resizing the application is not a
substitute. Text scaling requires comparison of the same rendered glyphs, while
native TaskDialog text scaling remains a separate limitation. Inspect original
screenshots before making a human visual claim. Hashes provide integrity
bookkeeping; they do not prove an independent rebuild or protect against a
coordinated replacement of every evidence file.

The local Wine/Xvfb gallery and legacy workload benchmarks were also diagnostic
only. They could compare app-owned rendering or record timings, but could not
establish native Windows acceptance, real device performance, power-loss
durability, or a release verdict.

The gallery requires Wine (`wine`, `wineboot`, `winepath`, and `wineserver`),
Xvfb, ffmpeg, jq, GNU `timeout`, and `sha256sum`. Its compatibility entrypoint
cross-builds and captures the production advanced-appearance window:

```bash
./scripts/capture-local-visual-gallery.sh
```

The external manifest records source state, executable digest, capture backend,
geometry, color diversity, and whether custom colors were active. Wine cannot
provide the audited journal handles used by the main application, and its theme
APIs may fall back to system rendering. The result does not establish Windows
version, DPI, Forced Colors, main-workbench, or accessibility acceptance.

## Historical focused GUI observations

These source-specific diagnostics are separate from the active
[fixed performance sample](../../DEVELOPMENT.md#fixed-performance-sample)
and [icon settlement diagnostic](../../DEVELOPMENT.md#icon-settlement-diagnostic).
Their original source, executable and tooling pins must be checked before any
reproduction. They do not establish release acceptance or causal speed claims.
The commands below came from the
[immutable pre-move development guide](https://github.com/PiesP/DarkReNamer/blob/0c26bc69856a8c8d6a06ab1698c25f972bfb2998/DEVELOPMENT.md#L1109).

### Focused first-10k-clear observation

Use `focused-10k-clear` only for a separately authorized, single observation of
the first clear after the ordinary 10,000-row full preview/reset. It retains
the original source-built product EXE and original bundle manifest unchanged,
while separately binding the corrected tooling to the current clean checkout.
Pin both origins before VM contact:

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic focused-10k-clear \
  --preserved-product-bundle-root /tmp/issue32-bootstrap-baseline-prepared-8248c73 \
  --expected-original-bundle-sha256 23f42a2c2af9e7a9417e275e10b9415be46dc05a0ecf610527a89e632ec7f38e \
  --expected-product-source-sha 8248c73859e3a3ff0e524fd9448acfe965fa3f68 \
  --expected-tooling-source-sha <current-clean-tooling-source-sha> \
  --expected-prepared-application-sha256 06c5511e042714f5a343e541856f2dbdc3850d5d60eeb62c3c36c2dacfef2f0f \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-focused-clear-attempt
```

The distinct `focused-10k-clear-v1-1366x768-96-text100` run repeats the original
30-second idle, 100/1,000/10,000 ordinary rows, four 2,250-row additions,
single-row preview/reset, and five-row full preview/reset. It records the bound
product PID and HWND, pre-clear rows, native command result and last-error class,
post-clear rows, sampler coverage, exact normal exit, and the existing strict
V1 guest cleanup. It stops after the first successful clear and does not run
long-path, extension, or cycle phases. The 5-second native command timeout,
600-second observer limit, one-PNG/32 MiB collection cap, and original fixture
and disk/journal checks still apply. Failed attempts retain their original raw
failure and partial observations; later cleanup cannot convert them to success.
This receipt is an observation, not a full performance comparison or release
acceptance. The original failed performance receipt stays failed, and the
focused result cannot supply normal A/B/B/A medians.

### Pre-worker icon settlement baseline

For the pre-worker synchronous source, use the same `icon-settlement`
diagnostic, V2 owned-resource profile, prepared-bundle pin, display, and two
fresh fixture phases, but select its separate baseline endpoint explicitly:

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic icon-settlement \
  --icon-endpoint-method synchronous-row-count-upper-bound-v1 \
  --baseline-product-source-sha b152761010b16ef74e2a3765241a253778b88e0b \
  --expected-run-source-sha <frozen-tooling-only-commit-sha> \
  --acceptance-profile-id vm-automated-v2-owned-resources \
  --prepared-bundle-root /absolute/private/native-baseline-bundle \
  --expected-prepared-application-sha256 <frozen-baseline-application-sha256> \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-icon-baseline-attempt
```

The baseline has run ID
`icon-settlement-sync-upper-bound-v1-1366x768-96-text100` and a distinct raw
scope. Its `synchronous_lookup_completion_upper_bound_ms` equals the existing
Open-to-UIA-row-count `data_ready_ms`. The pre-worker source finishes synchronous
Shell icon lookup before adding each row, so RowCount is a source-derived upper
bound for lookup completion. It does not observe actual icon visibility,
workers, queues, or joins and emits no status snapshots or fabricated zero
counters. The shared plan's 100-ms status poll applies only to the async method.
The baseline method is never inferred when the async status query is
missing. The command requires the original product reference and the exact
clean tooling-only run SHA; the prepared EXE hash and source are pinned before
VM execution. A separate source audit must establish that the tooling-only
checkout's product Rust, Cargo and toolchain blobs match the original product
reference; the manifest's asserted reference does not perform that audit.
Compare the baseline upper bound and candidate observed endpoint descriptively,
recording their different methods and any censored attempts. These samples do
not establish a causal or statistical speed claim.
