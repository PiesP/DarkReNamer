# Third-party notices

## DarkNamer 08.02.10

The compatibility implementation is based on the behavior, source, and
resources published at <https://github.com/nanpuhaha/DarkNamer>, commit
`3e5d6242e8c8eea60d94e73f8af8ddf9ab677203`. The repository credits the
original DarkNamer developer `darkwalker` and distributes the archived source
under the MIT License with the following notice:

> Copyright (c) 2018 Seo, Jang-won

The full upstream MIT terms are preserved in `LICENSES/DarkNamer-MIT.txt`.
This project retains the credit and uses the matched version as a compatibility
reference. Historical source, screenshots, archives, and executables remain in
the fork history and upstream-derived paths; Rust release packaging is defined
separately.

## Renamewright native adapter

`crates/dark-renamer-windows` is adapted from the minimal filesystem subset of
`renamewright-windows-native` at commit
`e41670ae9c242f0e363d184dd960ded06e905beb`. Both implementations are authored
by PiesP and distributed under the repository MIT License. The adapted subset
retains the reviewed handle-lifetime, native no-replace rename, 128-bit file
identity, reparse-parent rejection, leaf-name validation, and hard-link
destination rejection behavior; unrelated Renamewright UI code is not included.
