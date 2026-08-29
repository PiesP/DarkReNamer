# Security policy

## Supported versions

Security fixes are provided for the current `master` line and the latest
published DarkReNamer release or prerelease. Historical DarkNamer binaries and
archived MFC sources are retained for provenance and are not supported by this
fork.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/PiesP/DarkReNamer/security/advisories/new)
for vulnerabilities in the Rust port. Do not report DarkReNamer issues to the
original DarkNamer maintainers.

Include the affected commit or release, the reachable source-to-sink path,
expected impact, and a minimal reproduction using disposable files. Remove
personal filenames, native paths, credentials, and unrelated user data from all
reports and fixtures.

Security-sensitive areas include unintended file replacement or movement,
reparse-point traversal and path races, malformed import lists, unsafe Win32
boundaries, dependency provenance, and release artifact substitution.
Compatibility behavior inherited from DarkNamer is not
automatically a vulnerability; reports should demonstrate the additional
confidentiality, integrity, or availability impact in the maintained Rust port.
