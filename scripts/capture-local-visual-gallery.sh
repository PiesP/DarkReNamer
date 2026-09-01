#!/usr/bin/env bash
set -euo pipefail

for tool in cargo wine wineboot winepath wineserver xvfb-run ffmpeg sha256sum timeout; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required visual-gallery tool is unavailable: %s\n' "$tool" >&2
    exit 1
  fi
done

repo_root="$(git rev-parse --show-toplevel)"
if [[ "$repo_root" != "$PWD" ]]; then
  printf 'Run this script from the DarkReNamer repository root.\n' >&2
  exit 1
fi

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [absolute-empty-output-directory]\n' "$0" >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  output_root="$1"
  if [[ "$output_root" != /* ]]; then
    printf 'The visual-gallery output directory must be absolute.\n' >&2
    exit 1
  fi
  if [[ -e "$output_root" ]]; then
    if [[ ! -d "$output_root" || -n "$(find "$output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      printf 'The visual-gallery output directory must be absent or empty.\n' >&2
      exit 1
    fi
  else
    mkdir "$output_root"
  fi
else
  output_root="$(mktemp -d /tmp/darkrenamer-visual-gallery.XXXXXX)"
fi

source_sha="$(git rev-parse HEAD)"
if git diff --quiet && git diff --cached --quiet; then
  source_state=clean
else
  source_state=dirty
fi

resource_compiler="${RC:-/usr/bin/llvm-rc-19}"
if [[ ! -x "$resource_compiler" ]]; then
  printf 'The pinned LLVM resource compiler is unavailable: %s\n' "$resource_compiler" >&2
  exit 1
fi

RC="$resource_compiler" cargo xwin test \
  --package darknamer-app \
  --lib \
  --locked \
  --target x86_64-pc-windows-msvc \
  --no-run

test_exe="$({
  find target/x86_64-pc-windows-msvc/debug/deps \
    -maxdepth 1 -type f -name 'darknamer_app-*.exe' -printf '%T@ %p\n'
} | sort -nr | head -1 | cut -d' ' -f2-)"
if [[ -z "$test_exe" || ! -f "$test_exe" ]]; then
  printf 'The current Windows native-test executable was not produced.\n' >&2
  exit 1
fi
fixture_sha="$(sha256sum "$test_exe" | cut -d' ' -f1)"

wine_root="$(mktemp -d /tmp/darkrenamer-wine-prefix.XXXXXX)"
export WINEPREFIX="$wine_root"
export WINEDEBUG=-all
export WINEDLLOVERRIDES='mscoree,mshtml='
cleanup() {
  WINEPREFIX="$wine_root" wineserver -k >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

timeout 60s xvfb-run -a -s '-screen 0 1600x1200x24' bash -c \
  'wineboot -i >/dev/null 2>&1; wineserver -w'
windows_output="$(winepath -w "$output_root")"

DARKRENAMER_VISUAL_OUTPUT_DIR="$windows_output" \
DARKRENAMER_VISUAL_SOURCE_SHA="$source_sha" \
DARKRENAMER_VISUAL_SOURCE_STATE="$source_state" \
DARKRENAMER_VISUAL_RUNTIME=wine \
DARKRENAMER_VISUAL_FIXTURE_SHA256="$fixture_sha" \
timeout 45s xvfb-run -a -s '-screen 0 1600x1200x24' \
  wine "$test_exe" \
  'windows::visual_capture::write_appearance_dialog_visual_gallery' \
  --exact --ignored --nocapture

for bmp in "$output_root"/*.bmp; do
  ffmpeg -hide_banner -loglevel error -y -i "$bmp" "${bmp%.bmp}.png"
done
(
  cd "$output_root"
  sha256sum ./*.bmp ./*.png visual-gallery.json > SHA256SUMS.txt
)

printf 'Diagnostic visual gallery: %s\n' "$output_root"
printf 'Source: %s (%s working tree)\n' "$source_sha" "$source_state"
printf 'This Wine fixture is diagnostic only and is not Windows acceptance evidence.\n'
