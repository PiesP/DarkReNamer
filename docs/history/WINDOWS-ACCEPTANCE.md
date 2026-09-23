# Historical Windows acceptance

This document preserves the legacy manual desktop, physical-media, and
observer procedures that predate the current release gate. It is historical
reference, not a second release contract.

The active contract is
[VM-Automated release validation](../../SAFETY.md#vm-automated-release-validation).
It uses source-bound automated checks and a fixed Windows VM profile. Nothing
in this history upgrades an old failure, `not-run`, or `review_required` result,
and the existence of these procedures does not show that any acceptance run
was completed.

## Historical evidence boundary

Formal desktop acceptance was recorded in an external, path-free JSON artifact
bound to a full source SHA and the tested `DarkReNamer.exe` filename and
SHA-256. Evidence produced from an Actions handoff also recorded its workflow
run. Screenshots remained external and were bound by filename, dimensions,
digest, UI or scenario target, appearance, surface, and the same executable
digest.

The machine-readable field contract remains
[`config/schemas/windows-acceptance-evidence.schema.json`](../../config/schemas/windows-acceptance-evidence.schema.json).
The historical tools remain available for interpreting existing evidence:

- [`scripts/new-windows-acceptance-draft.ps1`](../../scripts/new-windows-acceptance-draft.ps1)
  creates a new path-free draft from a local executable or validated Actions
  handoff. It does not observe a host or establish coverage.
- [`scripts/validate-windows-acceptance-evidence.ps1`](../../scripts/validate-windows-acceptance-evidence.ps1)
  validates structure, bindings, privacy fields, unique targets, and draft or
  formal-gate semantics with PowerShell 7.4 or newer.
- [`scripts/validate-release-acceptance.ps1`](../../scripts/validate-release-acceptance.ps1)
  cross-checks historical formal evidence and external PNGs against an exact
  downloaded Actions handoff.

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

`scripts/add-windows-acceptance-benchmark.ps1` imported exactly five private,
source-bound logs and a path-free `benchmark-context.json` into a new draft. It
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
