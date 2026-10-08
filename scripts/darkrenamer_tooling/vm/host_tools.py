"""Trusted Linux/WSL host executables and bounded PowerShell child environment."""

from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import subprocess


DEFAULT_TOOLS = {"pwsh": "/usr/bin/pwsh", "wslpath": "/usr/bin/wslpath"}
OVERRIDES = {"pwsh": "DARKRENAMER_PWSH_PATH", "wslpath": "DARKRENAMER_WSLPATH_PATH"}
CHILD_PATH = ("/usr/bin", "/bin")
CHILD_VARIABLES = {
    "HOME", "USER", "LOGNAME", "LANG", "TERM", "TMPDIR", "TZ",
    "SSH_AUTH_SOCK", "WSL_DISTRO_NAME", "WSL_INTEROP", "WSLENV",
    "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR",
}


def _trusted_identity(path: Path, info: os.stat_result, kind: str) -> None:
    # POSIX symlink mode bits are ignored by the kernel (normally 0777).
    if info.st_uid not in (0, os.geteuid()) or (
            kind != "symlink" and info.st_mode & 0o022):
        raise RuntimeError(f"Host {kind} has an untrusted owner or write permission: {path}.")


def trusted_path(path: str | Path, *, executable: bool = False) -> Path:
    """Check every directory/link/target without executing or searching PATH.

    Root and the current account are the only trusted writers. A privileged or
    same-account attacker remains in the host trust boundary; pathname checks
    cannot provide race-free execution against either of them.
    """
    if os.name != "posix":
        raise RuntimeError("Trusted VM host tools require Linux/WSL.")
    path = Path(path)
    if not path.is_absolute():
        raise RuntimeError("Host tool path must be absolute.")
    pending = list(path.parts[1:])
    current = Path("/")
    links = 0
    while pending:
        part = pending.pop(0)
        if part in ("", "."):
            continue
        if part == "..":
            current = current.parent
            continue
        parent_info = current.lstat()
        if not stat.S_ISDIR(parent_info.st_mode):
            raise RuntimeError(f"Host tool parent is not a directory: {current}.")
        _trusted_identity(current, parent_info, "directory")
        candidate = current / part
        try:
            info = candidate.lstat()
        except OSError as error:
            raise RuntimeError(f"Approved host path is unavailable: {candidate}.") from error
        if stat.S_ISLNK(info.st_mode):
            _trusted_identity(candidate, info, "symlink")
            links += 1
            if links > 16:
                raise RuntimeError("Host tool symlink chain is too deep.")
            target = Path(os.readlink(candidate))
            if target.is_absolute():
                current = Path("/")
            pending = list(target.parts[1:] if target.is_absolute() else target.parts) + pending
            continue
        if pending and not stat.S_ISDIR(info.st_mode):
            raise RuntimeError(f"Host tool parent is not a directory: {candidate}.")
        _trusted_identity(candidate, info, "path")
        current = candidate
    info = current.lstat()
    if executable and (not stat.S_ISREG(info.st_mode) or not os.access(current, os.X_OK)):
        raise RuntimeError(f"Approved host tool is not an executable regular file: {current}.")
    if not executable and not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"Approved host search path is not a directory: {current}.")
    return current


def resolve_tool(name: str, environment: dict[str, str] | None = None) -> str:
    if name not in DEFAULT_TOOLS:
        raise ValueError("Unknown host tool.")
    environment = os.environ if environment is None else environment
    selected = environment.get(OVERRIDES[name], DEFAULT_TOOLS[name])
    if not selected:
        raise RuntimeError(f"{OVERRIDES[name]} must name an approved absolute executable.")
    try:
        trusted_path(selected, executable=True)
    except OSError as error:
        raise RuntimeError(f"Approved {name} path is unavailable; set {OVERRIDES[name]} to a trusted absolute installation.") from error
    return str(Path(selected))


def child_environment(environment: dict[str, str] | None = None, **extra: str) -> dict[str, str]:
    """Keep SSH/WSL identity inputs, while removing preload/module and ambient PATH inputs."""
    environment = os.environ if environment is None else environment
    for directory in CHILD_PATH:
        trusted_path(directory)
    trusted_path("/usr/bin/ssh", executable=True)
    result = {key: value for key, value in environment.items()
              if key in CHILD_VARIABLES or re.fullmatch(r"LC_[A-Z_]+", key)}
    result["PATH"] = os.pathsep.join(CHILD_PATH)
    result.update(extra)
    return result


def require_pwsh74(environment: dict[str, str] | None = None) -> str:
    executable = resolve_tool("pwsh", environment)
    try:
        version = subprocess.check_output(
            [executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
             "$PSVersionTable.PSVersion.ToString()"],
            env=child_environment(environment), text=True, timeout=10,
        ).strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise RuntimeError("Unable to verify that approved pwsh is PowerShell 7.4 or newer.") from error
    if (re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+){0,2}", version) is None or
            tuple(int(part) for part in version.split(".")[:2]) < (7, 4)):
        raise RuntimeError("SSH transport requires approved PowerShell 7.4 or newer.")
    return executable
