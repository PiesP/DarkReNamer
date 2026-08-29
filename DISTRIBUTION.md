# Distribution policy

DarkReNamer publishes Windows builds only from a version tag whose commit is on
`master` and whose name exactly matches the Cargo workspace version. The tag
workflow creates a GitHub **prerelease**; ordinary branch, pull-request, and
manual CI runs never publish artifacts.

## Current unsigned handoff

The current executable is intentionally Authenticode `NotSigned`. The release
workflow fails if that status changes without an explicit policy update. A
release contains:

- `DarkReNamer.exe`;
- `SHA256SUMS.txt`;
- a CycloneDX JSON SBOM;
- a zipped PDB plus the complete Actions handoff artifact;
- license, attribution, and this distribution policy;
- GitHub build-provenance and SBOM attestations.

Verify the checksum before running the executable. GitHub attestations can be
verified with `gh attestation verify` against this repository. A valid checksum
or attestation identifies the produced bytes; it does not replace Authenticode
publisher identity.

## Future Authenticode boundary

Authenticode may be enabled only after the owner approves a public-CA
organization-validation signing service, its disclosure text, and the
credential boundary. Self-signed certificates are not release credentials and
must not be introduced. Signing keys and service tokens must remain outside the
repository and must not be exposed to pull-request workflows.

The signing step, when approved, must run after the reproducible build and
before checksums, SBOM attestation, artifact attestation, and publication. The
workflow must then require a successful signature status instead of `NotSigned`.

MSIX or Microsoft Store distribution is a separate future channel with its own
identity, update, and signing review. It is not implied by the GitHub portable
prerelease workflow.
