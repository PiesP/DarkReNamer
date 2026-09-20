"""Shared errors for bounded evidence parsing and verification."""


class EvidenceError(ValueError):
    """Evidence is malformed, unsafe, or inconsistent with its contract."""
