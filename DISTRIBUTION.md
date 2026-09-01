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
- `release-metrics.json`, recording the source, toolchain, target, artifact byte
  sizes, and Cargo lockfile package count for that build;
- a CycloneDX JSON SBOM;
- a zipped PDB;
- license, attribution, and this distribution policy;
- the original candidate workflow's GitHub build-provenance and SBOM
  attestations.

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
of the repository license and policy files. The metrics are information only;
the workflow does not apply release size or dependency-count thresholds.

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
byte-for-byte reproducible. Desktop acceptance and power-loss durability remain
separate from packaging validation.

## Immutable prerelease promotion

After inspecting the candidate, create the version tag on that exact `master`
commit and dispatch the Promote portable prerelease workflow. Supply the
candidate run ID, run attempt, immutable artifact ID, source SHA, executable
SHA-256 from `release-handoff.json`, and version tag. Promotion fails unless all
of those values agree with current `origin/master`, the successful candidate
workflow metadata, the unexpired artifact metadata, the downloaded handoff
bytes, the original candidate attestation, and the existing remote tag.

Promotion does not install a toolchain, run tests, build an executable, replace
an artifact, or create a new provenance claim. It publishes the exact files from
the candidate handoff. An existing release for the tag is rejected instead of
being overwritten.

The published item is a **source-complete prerelease**. Its release notes state
that real Windows desktop acceptance and physical SSD evidence remain separate;
hosted Windows checks do not establish those claims. This disclosure remains in
place unless a future policy defines a controlled way to provide the external
acceptance evidence to the publication boundary.

Formal desktop acceptance is complete only when the external evidence passes
the full release gate documented in repository file `SAFETY.md` and repository
script `scripts/validate-release-acceptance.ps1` cross-checks it against the
checkout HEAD, the actual Actions handoff, and the PNG bytes under the supplied
`-VisualEvidenceRoot`. Use the exact source commit named by
`release-handoff.json`; this standalone policy file does not embed or link to a
potentially newer repository revision. A valid handoff alone is packaging
evidence, not desktop acceptance.

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
