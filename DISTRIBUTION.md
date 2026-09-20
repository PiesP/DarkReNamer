# Distribution policy

DarkReNamer publishes Windows builds only from a version tag whose commit is the
current `master` and whose name exactly matches the Cargo workspace version. The
manual Portable prerelease candidate workflow packages and validates the
selected `master` commit, attests those exact files, and retains an immutable
Actions handoff artifact. It cannot create a tag or release. The separate
promotion workflow downloads that artifact by its immutable artifact ID and
creates a GitHub **prerelease** without rebuilding it.

## Current unsigned handoff

The current executable is intentionally Authenticode `NotSigned`. The packaging
workflow fails if that status changes without an explicit policy update. A
published prerelease contains:

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
against the repository, signer workflow, protected source ref, and exact source
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

After handoff validation, the workflow copies the effective values from
`release-metrics.json` into the Actions job summary. Use the retained JSON as
the machine-readable record for the build; the summary is an informational
view of the same values.

The workflow exports the source commit timestamp as `SOURCE_DATE_EPOCH` before
the release build. This supplies stable source-time metadata to tools that honor
the variable; it is not a claim that independent EXE or PDB builds are
byte-for-byte reproducible. VM-Automated validation remains separate from
packaging validation. The release scope does not claim power-loss durability.

## Immutable prerelease promotion

After inspecting the candidate, create the version tag on that exact `master`
commit and dispatch the Promote portable prerelease workflow. Supply the
candidate run ID, run attempt, immutable artifact ID, source SHA, executable
SHA-256 from `release-handoff.json`, and version tag. Also supply the private
evidence release ID, asset ID, archive SHA-256 and size, and the exact successful
VM validation run ID and attempt. Promotion fails unless all
of those values agree with current `origin/master`, the successful candidate
workflow metadata, the unexpired artifact metadata, the downloaded handoff
bytes, the original candidate attestation, and the existing remote tag.

The manual VM validation workflow obtains raw evidence from one dedicated,
never-published draft release asset owned and uploaded by the repository owner.
Its numeric identity, digest and length are pinned; arbitrary download URLs are
not accepted. The archive remains private and is not uploaded as an Actions
artifact. The workflow independently downloads and verifies the immutable
candidate, validates the bounded archive, re-derives the full profile from raw
observations, and cleans up its private scratch and extracted archive before it
can complete. The next workflow step attests only the canonical path-free
statement. Product, clean harness checkout and protected hosted verifier must
use the same protected source commit.

The statement can report `passed` only after the verifier derives all 22 target
verdicts from the fixed 20-cell matrix and 10 independent stability executions,
and binds all five gates listed in
[`SAFETY.md`](SAFETY.md#vm-automated-release-validation). Every slot is its
predeclared first attempt. A failed or missing slot stops the remaining VM work
and cannot be replaced by a successful retry; publication requires a new
complete campaign. The policy and profile define this requirement, but do not
claim that a campaign has already passed.

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
validation workflow, protected source ref and digest, and GitHub-hosted runner.
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

The published item is a **VM-Automated validated prerelease**, limited to the
fixed Windows VM profile recorded in the statement. Physical-media performance,
physical power loss, VM reset/storage-fault durability, actual IME and Explorer
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
