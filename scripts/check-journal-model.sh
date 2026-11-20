#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

jar=${TLA2TOOLS_JAR:-"$work/tla2tools.jar"}
if [[ -z "${TLA2TOOLS_JAR:-}" ]]; then
  curl --fail --silent --show-error --location --retry 2 --max-time 120 \
    --output "$jar" https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
fi
digest=$(sha256sum < "$jar")
if [[ "${digest%% *}" != 936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88 ]]; then
  printf '%s\n' 'TLC v1.7.4 JAR digest mismatch.' >&2
  exit 1
fi

run_tlc() {
  local config=$1
  shift
  "${JAVA_HOME:+$JAVA_HOME/bin/}java" -Xmx256m "-Djava.io.tmpdir=$work" -XX:+UseParallelGC \
    -cp "$jar" tlc2.TLC -workers 1 -seed 1 -fp 0 -metadir "$work" \
    -config "verification/journal/$config.cfg" "$@" verification/journal/JournalRecovery.tla
}

if ! run_tlc JournalRecovery -coverage 0 > "$work/model.log" 2>&1; then
  cat "$work/model.log" >&2
  exit 1
fi
# Keep the action counts and summary visible without the per-expression detail.
awk '/^(<|TLC2 Version|Running breadth-first|Model checking completed|[0-9]+ states generated|The depth|Finished in)/' \
  "$work/model.log"

expect_violation() {
  local config=$1 invariant=$2 state=$3 transition=$4 status=0
  run_tlc "$config" > "$work/control.log" 2>&1 || status=$?
  cat "$work/control.log"
  if [[ "$status" != 12 ]] ||
    ! grep -Fxq "Error: Invariant $invariant is violated." "$work/control.log" ||
    ! grep -Fq "State $state: <$transition " "$work/control.log"; then
    printf 'Expected %s to violate %s at state %s.\n' "$config" "$invariant" "$state" >&2
    exit 1
  fi
  printf 'Negative control detected %s.\n' "$transition"
}

expect_violation UnpreparedMove PositionExplained 3 MoveWithoutPrepare
expect_violation PrematureTerminal TerminalEvidenceResolved 6 FinishWithoutResolution
