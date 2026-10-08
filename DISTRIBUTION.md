# Distribution policy

DarkReNamer publishes Windows builds only from a version tag whose commit is the
current `master` and whose name exactly matches the Cargo workspace version. The
manual Portable prerelease candidate workflow packages and validates the
selected `master` commit, attests those exact files, and retains an immutable
Actions handoff artifact. It cannot create a tag or release. The separate
promotion workflow downloads that artifact by its immutable artifact ID and
creates a new GitHub release or prerelease without rebuilding it.

## Release channels and approval

A regular release is intended for general use within the documented support
and feature scope. Its quality decision uses the existing VM-Automated v2
profile and evidence bound to the exact source and candidate executable.
It does not expand the automated profile's guarantees. Supported use remains
Windows 11 or later on x64, without elevation, on supported local NTFS paths:
file and directory renames within one parent, and regular-file moves to an
existing folder on the same volume.

The next unused product version follows the new-release path below, with
`release_channel=release`. Prereleases remain available through
`release_channel=prerelease`. A regular release requires the
`vm-automated-v2-owned-resources` profile; v1 remains a historical prerelease
option. Both channels require the same five gates and exact identity checks.
Selecting a channel does not authorize publication or bypass validation.

Before creating the tag or dispatching promotion, obtain explicit maintainer
authorization for the version, source SHA, EXE SHA-256, candidate run/attempt,
immutable artifact ID and complete artifact ZIP SHA-256, campaign/profile,
hosted validation run/attempt and statement digest,
and chosen channel. Record the approval in an issue comment or the existing
handoff, including ignored or unexecuted tests and the documented limitations.
The regular-release decision accepts the current unsigned `NotSigned` policy.
Save Names / Save Paths create new files without replacing existing targets,
as described in [the safety model](SAFETY.md). This policy does not claim formal
memory soundness. Human Explorer/IME or visual/accessibility acceptance,
physical-media performance, physical power loss and VM reset/storage faults
remain outside this release guarantee, rather than additional mandatory gates.
New blocking defects or failed mandatory gates still prevent publication.

This policy authorizes preparation of future regular releases, not publication
of an unrecorded candidate. Each new source needs its own immutable candidate,
complete first-attempt campaign and hosted verification. Existing published
prereleases retain their original channel, tags, files and approval records;
changing their metadata into regular releases is not a supported promotion
path. In particular, prior evidence cannot be relabeled for a newer policy or
harness commit.

The `make_latest` workflow input is a separate explicit decision and defaults
to `false`. It may be `true` only for a regular release. Channel selection and
latest designation are distinct; neither changes the supported environment.
Regular-release status does not require a 1.0.0 version number; the tag must
still match the chosen Cargo workspace version exactly.

## Prepared 0.1.7 release notes

This patch clarifies that Reset Names resets proposed names in the list; it does
not undo changes already made on disk. Resetting target folders remains a
separate command. Selected proposal names remain readable in light, dark and
high-contrast themes, including when the list no longer has keyboard focus.
Existing preferences remain compatible and do not need to be reset.

The app's command, appearance, layout and preference code now uses smaller
modules with shared preview-row formatting and ListView update mechanics.
These changes preserve rename behavior, no-replacement mutation authority and
Cancel-default confirmation. They do not establish a new speed, startup,
memory, binary-size or native-paint performance improvement.

Release preparation binds the candidate build to its workflow event source,
retains source-bound metrics and provenance, and enforces private evidence
archive parents and object-bound cleanup. Scheduled and manual dependency
audits reject malformed scanner output. Shared tooling setup is consolidated
without changing the fixed candidate validation profile or its first-attempt
rules.

A Shell or import provider that never returns can keep close pending. The
executable remains intentionally unsigned (`NotSigned`); the supported
environment and automated-validation limitations below remain unchanged.
Preparation is not publication approval.

## Historical 0.1.6 development observations

Published v0.1.6 already includes [PR #45](https://github.com/PiesP/DarkReNamer/pull/45):
full refresh streams one additional complete owned row instead of retaining a
second complete formatted row list. All native column values, including hidden
columns, remain available. Native-count mismatch or partial update failure
retains the explicit authoritative rebuild fallback and Apply blocking when
synchronization cannot be restored. Icon scheduling and file-mutation authority
are unchanged. Optional timestamp reuse was not selected.

In the [previously recorded prepared-VM comparison](https://github.com/PiesP/DarkReNamer/issues/31#issuecomment-5984364932),
the selected 10,000-row workload's median sampled peak Private Bytes decreased
by about 5.77 MiB (11.12%); whole-run sampled peak reduction was about 1.01 MiB.
The 10,000-row elapsed median increased by 3.09% within the predeclared local
adoption screen. These are historical development observations from two runs
per product with 200-ms resource sampling; the workload was four 2,250-row
additions after 1,000 rows. They are not a fresh benchmark of the packaged
candidate or a comparison against published v0.1.5's exact executable.
No general speed improvement is claimed.

The [async-worker normal comparison remains deferred, not verified](https://github.com/PiesP/DarkReNamer/issues/32#issuecomment-5980518916).
A Shell or import provider that never returns can keep close pending; the
executable remains intentionally unsigned (`NotSigned`). Preparation is not
publication approval: every new candidate and evidence tuple still requires
the existing validation and separate authorization. Historical v0.1.5 excluded
this optimization and remains unchanged.

## Current unsigned handoff

The current executable is intentionally Authenticode `NotSigned`. The packaging
workflow fails if that status changes without an explicit policy update. A
published release or prerelease contains:

- `DarkReNamer.exe`;
- `SHA256SUMS.txt`;
- `release-handoff.json`, binding the source SHA and Actions workflow run to the
  executable filename and SHA-256;
- `release-metrics.json`, recording the source, toolchain, target, executable and
  `.text` raw byte sizes, raw and compressed debug-symbol sizes, SBOM size, and
  Cargo lockfile package count for that build;
- a CycloneDX JSON SBOM;
- a zipped PDB;
- the project license, source attribution, generated Rust dependency license
  texts, and this distribution policy;
- the original candidate workflow's GitHub build-provenance and SBOM
  attestations;
- `validation-statement.json`, the canonical VM-Automated profile verdict,
  whose separate hosted validation attestation is verified before promotion.

`DarkReNamer.exe` is the only runnable product file and requires no adjacent
configuration file. “Portable” means an installer-free executable; it does not
make preferences self-contained with the download. UI preferences remain in the
current user's `%LOCALAPPDATA%\DarkReNamer` directory, while the executable can
be replaced or moved independently.

Every successful packaging run also retains the complete Actions handoff,
including the raw PDB. The handoff validator checks the exact file layout,
symbol archive contents, SBOM format, checksums, unsigned Authenticode status,
provenance and metrics shape, source and toolchain bindings, recorded artifact
sizes, Cargo lockfile package count, executable bytes, and byte-identical copies
of the repository license and policy files. `THIRD_PARTY_LICENSES.html` is
generated from the locked x86-64 Windows dependency graph with build
dependencies included and development-only dependencies excluded. The metrics
are information only; the workflow does not apply release size or
dependency-count thresholds.

Verify the checksum before running the executable. Verify candidate provenance
against the repository, signer workflow, pinned master ref, and exact source
digest recorded in `release-handoff.json`:

```text
gh attestation verify DarkReNamer.exe \
  --repo PiesP/DarkReNamer \
  --signer-workflow PiesP/DarkReNamer/.github/workflows/release.yaml \
  --source-ref refs/heads/master \
  --source-digest <release-handoff source_sha> \
  --deny-self-hosted-runners
```

Repository-only verification is not the release policy because another ref or
workflow can produce a different attestation. A valid checksum or strict
attestation identifies the produced bytes; it does not replace Authenticode
publisher identity.

## Publish-free packaging validation

Run the Portable prerelease candidate workflow manually on `master` to exercise
the Windows test, build, SBOM, packaging, handoff-validation, and attestation
path without publishing a release. Inspect the retained artifact and its Actions
summary before creating a release tag. The summary identifies the immutable
artifact ID, run ID, and run attempt required by the promotion workflow;
`release-handoff.json` identifies the source and executable digest.

The build job has only read access to repository contents. It uploads one
immutable artifact after finalizing and validating the handoff. A fresh hosted
job holds attestation authority, checks the exact successful build's artifact
ID, approved ZIP digest, source and run/attempt name, and downloads those same
bytes. It treats the candidate as data, validates it using the checked-out
source, and attests the unchanged files and executable SBOM. It does not install
Cargo tools, execute candidate code, rebuild files, or upload another handoff.
A failed or skipped signing job cannot produce a successful candidate run.

Candidate builds use `config/release-tool-integrity.json` to approve the official
Windows Rust components and Cargo utility archives by SHA-256 before extraction,
installation or version probes. Rust's version and component owners remain
`rust-toolchain.toml`; scanner versions remain bound to the maintained security
workflow. The installer assembles the verified components as data and links the
release-only `darkrenamer-release` toolchain using the hosted image's rustup.
Product registry source packages retain the reviewed `Cargo.lock` checksums.
No Cargo utility is compiled from an externally resolved source closure here.

The hosted Windows image, its PowerShell, Git, rustup, Windows SDK and MSVC
tools, and the pinned Actions runtime remain bootstrap trust anchors. Digest
approval constrains selected upstream bytes; it does not establish that compiler
output is harmless or defeat a compromised trusted signer. To update a pin,
review the exact official version/asset and its bytes, record its URL and digest
with the version owner's change, inspect archive layout, run the integrity
fixtures, and exercise a non-publishing hosted candidate. A downloaded checksum
alone is not repository approval. Stale pins and corrupt retained archives fail
closed instead of reinstalling a floating alternative.

After handoff validation, the workflow copies the effective values from
`release-metrics.json` into the Actions job summary. Use the retained JSON as
the machine-readable record for the build; the summary is an informational
view of the same values.

The workflow exports the source commit timestamp as `SOURCE_DATE_EPOCH` before
the release build. This supplies stable source-time metadata to tools that honor
the variable; it is not a claim that independent EXE or PDB builds are
byte-for-byte reproducible. VM-Automated validation remains separate from
packaging validation. The release scope does not claim power-loss durability.

## Immutable release promotion

After inspecting the candidate, create the version tag on that exact `master`
commit and dispatch the Promote portable release workflow. Select the approved
`release_channel` (`release` by default) and `make_latest` decision. Supply the
candidate run ID, run attempt, immutable artifact ID, source SHA, executable
SHA-256 from `release-handoff.json`, complete artifact ZIP SHA-256 from the
independently approved workflow artifact digest, and version tag. Also supply the private
evidence release ID, asset ID, archive SHA-256 and size, and the exact successful
VM validation run ID and attempt. Select the profile explicitly for both hosted
validation and promotion: `vm-automated-v1-win11-ntfs` or
`vm-automated-v2-owned-resources`. Workflow choices, the local validator and
hosted wrapper default to v2; supply v1 explicitly for historical v1 evidence.
Promotion fails unless the selected profile ID, typed revision, source blob
digest and statement schema agree, and all pinned values agree with current
`origin/master`, the successful candidate workflow metadata, the unexpired
artifact metadata, the downloaded handoff
bytes, the original candidate attestations, and the existing remote tag. The
authenticated artifact API digest and the actual downloaded original ZIP bytes
must both match the approved digest; a re-created ZIP or executable digest is
not an equivalent artifact selection. Every candidate-derived public asset,
including checksums and generated metadata, must pass the original candidate
provenance gate. The publication list and verified subject list have one owner.
The validation statement retains its separate hosted verifier attestation.

Before collecting new raw evidence, use the local POSIX owner-only destination
procedure in [campaign development](DEVELOPMENT.md#vm-automated-campaign-development).
Temporary and final campaign ZIPs are created owner-only before content is
written, rather than restricted after packaging. The supported Linux/WSL
producer enforces an effective-user-owned `0700` ordinary parent, retains its
descriptor, and refuses uncertain cleanup of names it cannot authenticate.
Use local Linux storage with enforced POSIX permissions, keep it private through
upload, and preserve equivalent protection when moving or copying raw evidence.
These checks do not certify filesystem ACLs or support Windows-backed WSL
packaging destinations. They do not retroactively prove creation-time privacy
or the newer parent/cleanup boundaries of historical evidence archives.

The manual VM validation workflow obtains raw evidence from one dedicated,
never-published draft release asset owned and uploaded by the repository owner.
Its numeric identity, digest and length are pinned; arbitrary download URLs are
not accepted. The archive remains private and is not uploaded as an Actions
artifact. The workflow independently downloads and verifies the immutable
candidate, validates the bounded archive, re-derives the full profile from raw
observations, and cleans up its private scratch and extracted archive before it
can complete. The next workflow step attests only the canonical path-free
statement. Product, clean harness checkout and hosted verifier must
use the same pinned master source commit.

The selected statement can report `passed` only after the verifier derives all
22 target verdicts from the fixed 20-cell matrix and 10 independent stability executions,
and binds all five gates listed in
[`SAFETY.md`](SAFETY.md#vm-automated-release-validation). Every slot is its
predeclared first attempt. A failed or missing slot stops the remaining VM work
and cannot be replaced by a successful retry; publication requires a new
complete campaign. The policy and profile define this requirement, but do not
claim that a campaign has already passed.

Successful cleanup of resources owned by a failed execution is not release
acceptance. Original product and required-environment failures remain
immutable inputs, even when a separately verified cleanup proof establishes
that the run's resources were removed. V1 retains its strict whole-runner
environment predicate; its failed records cannot become v2 passes. V2 retains
raw ambient process observations but does not require whole-session OS process
stasis. Missing ownership evidence, unresolved owned lifetimes or roots,
incomplete observations, unexpected scheduled-task changes, input/focus
interference, and unsuccessful setting restoration still prevent a passing
statement. A filename, signature, or absence from the owned Job does not alone
establish that an observation is harmless. This distinction does not relax the
fixed first-attempt matrix, the same-source
candidate/harness/hosted-verifier requirement, or any of the
five required gates.

The repository owner and the prepared VM evidence producer remain trusted to
run the recorded commands and capture their observations honestly. Archive
validation detects missing, substituted and inconsistent evidence; it does not
provide remote attestation of the VM or prove an administrator could not
fabricate an entire observation set. The native backend gate joins retained
source-bound test executable bytes to the complete actual stdout/stderr
transcripts and source records. Its source build provenance relies on that
trusted producer, alongside the independently queried exact-source Windows CI
gate. Original release-candidate provenance is authenticated separately through
GitHub attestations.

Promotion downloads the same pinned evidence and candidate and recomputes the
same statement bytes. It verifies the statement attestation against the exact
validation workflow, pinned master ref and digest, and GitHub-hosted runner.
The verified certificate must identify the selected run and attempt; that exact
attempt must also report successful completion. A producer-supplied run field,
a successful different retry, or a statement checksum alone cannot satisfy this
boundary. Deleted evidence or attestations cause verification to fail closed.
This attestation authenticates the hosted derivation and statement bytes; it is
not an attestation from the VM that produced the private observations.

Promotion does not install a toolchain, run product tests, build an executable,
replace an artifact, or create new product provenance. It publishes the exact
candidate handoff files and the verified validation statement. An existing
release for the tag is rejected instead of being overwritten. Private raw
journals, local paths, screenshots and machine identities are never published.
After an authorized publication, bounded readback checks require the exact
public asset set and unchanged downloaded digests. Missing, unexpected or
substituted assets fail closeout without deleting or replacing public assets.

The published item is a **VM-Automated validated release or prerelease**,
according to its approved channel, limited to the
selected Windows VM profile recorded in the statement and release notes. V2
makes a narrower claim than v1: observed product safety, required environment
and explicit owned-resource cleanup, without a whole-session OS process-stasis
guarantee or complete causality for ambient OS activity. Physical-media
performance, physical power loss, VM reset/storage-fault durability, actual IME and Explorer
drag-and-drop, and human visual or comprehensive assistive-technology acceptance
are outside that claim. VM measurements must remain labeled as virtual storage.
The safety policy's historical formal desktop evidence and its validators retain
their old meaning; they are not silently reclassified as the new contract.

## Future Authenticode boundary

Authenticode may be enabled only after the owner approves a public-CA
organization-validation signing service, its disclosure text, and the
credential boundary. Self-signed certificates are not release credentials and
must not be introduced. Signing keys and service tokens must remain outside the
repository and must not be exposed to pull-request workflows.

The signing step, when approved, must run after the validated release build and
before checksums, SBOM attestation, artifact attestation, and publication. The
workflow must then require a successful signature status instead of `NotSigned`.

MSIX or Microsoft Store distribution is a separate future channel with its own
identity, update, and signing review. It is not implied by the GitHub portable
candidate and promotion workflows.
