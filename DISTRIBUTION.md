# Distribution policy

DarkReNamer publishes Windows builds only from a version tag whose commit is on
`master` and whose name exactly matches the Cargo workspace version. The tag
workflow creates a GitHub **prerelease**. A manual run packages and validates
the selected source commit and retains an Actions handoff artifact, but cannot
create a tag, release, or attestation.

## Current unsigned handoff

The current executable is intentionally Authenticode `NotSigned`. The packaging
workflow fails if that status changes without an explicit policy update. A
published prerelease contains:

- `DarkReNamer.exe`;
- `SHA256SUMS.txt`;
- `release-handoff.json`, binding the source SHA and Actions workflow run to the
  executable filename and SHA-256;
- a CycloneDX JSON SBOM;
- a zipped PDB;
- license, attribution, and this distribution policy;
- GitHub build-provenance and SBOM attestations.

Every successful packaging run also retains the complete Actions handoff,
including the raw PDB. The handoff validator checks the exact file layout,
symbol archive contents, SBOM format, checksums, unsigned Authenticode status,
provenance shape and executable bytes, and byte-identical copies of the
repository license and policy files.

Verify the checksum before running the executable. GitHub attestations can be
verified with `gh attestation verify` against this repository. A valid checksum
or attestation identifies the produced bytes; it does not replace Authenticode
publisher identity.

## Publish-free packaging validation

Run the Portable prerelease workflow manually on the source ref to exercise the
same Windows test, build, SBOM, packaging, and handoff-validation path without
running the publication or attestation job. Inspect the retained dry-run
artifact before creating a release tag.

The workflow exports the source commit timestamp as `SOURCE_DATE_EPOCH` before
the release build. This supplies stable source-time metadata to tools that honor
the variable; it is not a claim that independent EXE or PDB builds are
byte-for-byte reproducible. Desktop acceptance and power-loss durability remain
separate from packaging validation.

Formal desktop acceptance is complete only when the external evidence passes
the full release gate documented in repository file `SAFETY.md` and repository
script `scripts/validate-release-acceptance.ps1` cross-checks it against the
checkout HEAD and the actual Actions handoff. Use the exact source commit named
by `release-handoff.json`; this standalone policy file does not embed or link to
a potentially newer repository revision. A valid handoff alone is packaging
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
prerelease workflow.
