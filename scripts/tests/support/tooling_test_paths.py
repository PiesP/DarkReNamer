"""Canonical checkout paths for the tooling test suite."""

from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SCRIPT_ROOT.parent
