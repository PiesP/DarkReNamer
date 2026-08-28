# Native adapter provenance

`crates/dark-renamer-windows` is adapted from the minimal filesystem subset of
`renamewright-windows-native` at commit
`e41670ae9c242f0e363d184dd960ded06e905beb`. Both projects are authored by PiesP
and distributed under the MIT License in the repository root.

The adapted subset retains the original handle-lifetime model, native
no-replace rename operation, 128-bit file identity, reparse-parent rejection,
leaf-name validation, existing-hard-link rejection, and audited unsafe-block
proofs. Renamewright UI, locale, theme, and accessibility code is not included.
