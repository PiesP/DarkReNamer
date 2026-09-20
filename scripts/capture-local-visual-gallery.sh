#!/usr/bin/env bash
# Preserve the public diagnostic command while keeping its implementation separate.
set -euo pipefail
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/diagnostics/capture-local-visual-gallery.sh" "$@"
