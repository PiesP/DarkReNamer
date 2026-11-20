#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ "$(uname -sm)" != "Linux x86_64" ]]; then
  printf '%s\n' 'This proof is pinned to an x86_64 Linux host.' >&2
  exit 1
fi

version=$(cargo kani --version)
if [[ "$version" != $'Kani Rust Verifier 0.68.0 (cargo plugin)\nCBMC 6.11.0' ]]; then
  printf 'Expected Kani 0.68.0 with its bundled CBMC 6.11.0. Found:\n%s\n' "$version" >&2
  exit 1
fi

# The Kani Cargo plugin does not accept --locked. Validate and cache the locked
# dependencies first, then run offline and verify the lockfile after the proof.
cargo fetch --locked --target x86_64-unknown-linux-gnu
lock_digest=$(sha256sum Cargo.lock)
results=$(mktemp)
trap 'rm -f -- "$results"' EXIT
CARGO_NET_OFFLINE=true cargo kani -p darknamer-app --lib --exact \
  --harness rename::file_journal::decoder_verification::decoder_take_preserves_extent_and_cursor \
  --output-format terse | tee "$results"
if [[ "$(sha256sum Cargo.lock)" != "$lock_digest" ]]; then
  printf '%s\n' 'Kani changed Cargo.lock.' >&2
  exit 1
fi
if ! grep -Fxq ' ** 4 of 4 cover properties satisfied' "$results"; then
  printf '%s\n' 'The decoder proof must reach all four cover properties.' >&2
  exit 1
fi
