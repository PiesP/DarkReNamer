# DarkReNamer

[English](README.md) | [한국어](README.ko.md) | [日本語](README.ja.md)

DarkReNamer is an unofficial, community-maintained Rust port and GitHub fork
of [DarkNamer](https://github.com/nanpuhaha/DarkNamer). It targets DarkNamer
08.02.10 transformation and command semantics, but uses its own safety model
and interface. It is not an official release by `darkwalker`, Seo Jang-won, or
the upstream repository maintainer.

The application has a native Korean-language Windows interface. This README is
also available in Korean and Japanese; those translations do not indicate
additional interface languages.

## Download

Download the newest portable prerelease and its checksum from
[GitHub Releases](https://github.com/PiesP/DarkReNamer/releases). The runnable
product is one installer-free `DarkReNamer.exe`. Current builds are unsigned;
read the [distribution policy](DISTRIBUTION.md#current-unsigned-handoff) before
using a release and verify the supplied checksum and provenance.

Source is maintained in the
[DarkReNamer repository](https://github.com/PiesP/DarkReNamer). To build it
yourself, follow the [development guide](DEVELOPMENT.md).

## Supported environment

DarkReNamer officially supports Windows 11 and later on x64. Windows 10 may run
the application, but is not tested or officially supported.

The v0.1 filesystem scope is a non-elevated process working on local NTFS in
case-insensitive directories without reparse-point traversal. DarkReNamer
supports:

| Operation | Supported scope |
| --- | --- |
| Rename files and directories | Within the same parent directory |
| Move files | Regular files only, to an existing directory on the same local NTFS volume |

Network and device paths, filesystems other than NTFS, case-sensitive
directories, elevated execution, reparse traversal, cross-volume moves,
directory moves, destination-directory creation, replacement, and folder
merging are unsupported. The runtime checks this boundary and fails closed.

## Quick start

1. Start `DarkReNamer.exe` normally, without administrator elevation.
2. Select **파일 추가...** (Add files) and choose entries in the supported scope.
3. Choose a transformation and review every proposed name and Status value. For
   a blocked row, open **보기 > 선택 항목 진단...** (View > Selected item
   diagnostics).
4. Choose **변경 적용** (Apply), review the freshly validated plan, and confirm.
   Cancelling the confirmation leaves the files unchanged.

To move regular files within the supported scope, first use **편집 > 대상 폴더 >
모든 파일의 대상 폴더 지정...** (Edit > Target folder > Set the target folder
for all files).

## Safety and recovery

- Safe v2 rechecks entry and parent identities before execution, records durable
  intent before mutation, and performs no-replace operations. Existing
  destinations are never overwritten.
- The preview describes the current proposal. It does not validate the live
  filesystem or authorize a change until Apply performs its checks.
- **편집 > 모든 이름 변경 취소** resets proposed names. It does not undo changes
  already made on disk. Resetting a target folder also changes only the proposal.
- If an operation is interrupted or journal state is uncertain, DarkReNamer can
  lock further Apply operations. Keep the journal evidence and follow the
  startup recovery window; do not try to bypass the lock by moving or deleting
  journal files.

The complete mutation and recovery contract is in the
[safety model](SAFETY.md). Detailed appearance, settings, diagnostics, and
recovery directions are in the [user guide](docs/USER-GUIDE.md).

## Validation limits

Release validation is defined by the
[VM-Automated contract](SAFETY.md#vm-automated-release-validation), which binds
automated source checks and a fixed Windows VM profile to the exact candidate
executable. The policy does not show that any particular campaign has passed,
and this README makes no VM campaign pass claim.

VM-Automated v1 does not cover physical-device performance, physical power
loss, VM reset or storage faults, human visual or comprehensive assistive
technology acceptance, or actual IME and Explorer drag-and-drop interaction.
It also does not establish manually verified runtime parity with DarkNamer.
Historical manual and physical acceptance requirements are retained separately
in [Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md).

## Documentation

- [User guide](docs/USER-GUIDE.md): appearance, local settings, diagnostics,
  proposal reset, and recovery.
- [Safety model](SAFETY.md): filesystem authority, journal, cancellation, and
  current release-validation contract.
- [Distribution policy](DISTRIBUTION.md): unsigned artifacts, checksums,
  provenance, packaging, and release promotion.
- [Development guide](DEVELOPMENT.md): toolchains, commands, tooling registry,
  native VM execution, and required gates.
- [Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md): legacy
  manual, physical-media, and observer procedures.

## Attribution and license

DarkNamer was originally developed by
[`darkwalker`](https://blog.naver.com/darkwalk77). The upstream Git repository
carries `Copyright (c) 2018 Seo, Jang-won` under the MIT License. The Rust port
adds `Copyright (c) 2026 PiesP` under the same terms.

See `LICENSE`, `THIRD_PARTY_NOTICES.md`, and the package-level notices for full
attribution and embedded-resource provenance. Report DarkReNamer bugs in this
repository rather than asking the original DarkNamer maintainers to support
this fork. Compatibility reports should state whether the same behavior occurs
in DarkNamer 08.02.10.

This project is developed with assistance from AI tools.
