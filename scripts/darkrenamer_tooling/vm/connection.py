"""Private VM connection profile and authenticated guest preflight."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid


WINDOWS_PATH = re.compile(r"[A-Za-z]:\\[^\r\n]+")


def digest(path: Path) -> str:
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def digest_text(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    require(isinstance(value, dict), f"{path.name} must contain a JSON object.")
    return value


def ordinary_file(path: Path, maximum: int, label: str) -> Path:
    require(path.is_file() and not path.is_symlink(), f"{label} must be an ordinary file.")
    require(path.stat().st_size <= maximum, f"{label} exceeds its size bound.")
    return path


def load_connection_profile(path: Path) -> tuple[dict, str]:
    original = path
    path = ordinary_file(path.resolve(strict=True), 16 * 1024, "Connection profile")
    require(not original.is_symlink(), "Connection profile must not be a symlink.")
    profile = read_json(path)
    require(
        set(profile) == {"schema_version", "ssh_host", "desktop_helper", "expected_vm_id"}
        and profile.get("schema_version") == 1,
        "Connection profile fields are invalid.",
    )
    require(
        isinstance(profile.get("ssh_host"), str)
        and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", profile["ssh_host"]) is not None,
        "Connection profile SSH alias is invalid.",
    )
    require(
        isinstance(profile.get("desktop_helper"), str)
        and WINDOWS_PATH.fullmatch(profile["desktop_helper"]) is not None,
        "Connection profile desktop helper path is invalid.",
    )
    try:
        identity = uuid.UUID(profile.get("expected_vm_id", ""))
    except (ValueError, AttributeError) as error:
        raise ValueError("Connection profile VM identity is invalid.") from error
    require(identity.int != 0, "Connection profile VM identity is invalid.")
    profile["expected_vm_id"] = str(identity)
    return profile, digest(path)


def guest_preflight(profile: dict) -> dict:
    pwsh = shutil.which("pwsh")
    require(pwsh is not None, "VM preflight requires PowerShell 7.4 or newer as pwsh.")
    script = r"""
$ErrorActionPreference = 'Stop'
$options = @{BatchMode='yes';StrictHostKeyChecking='yes';ForwardAgent='no'}
$session = New-PSSession -HostName $env:DARKRENAMER_GUI_SSH_HOST -Options $options
try {
    $value = Invoke-Command -Session $session -ScriptBlock {
        [ordered]@{
            system = 'windows'
            os_version = [Environment]::OSVersion.VersionString
            build = [Environment]::OSVersion.Version.Build.ToString()
            architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            product_caption = (Get-CimInstance Win32_OperatingSystem).Caption
            vm_id = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -Name VirtualMachineId).VirtualMachineId
        } | ConvertTo-Json -Compress
    }
    [Console]::Out.Write([string]$value)
}
finally { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
"""
    environment = dict(os.environ)
    environment["DARKRENAMER_GUI_SSH_HOST"] = profile["ssh_host"]
    raw = subprocess.check_output(
        [pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
        env=environment, text=True,
    )
    value = json.loads(raw)
    require(isinstance(value, dict) and set(value) == {
        "system", "os_version", "build", "architecture", "product_caption", "vm_id"
    }, "Guest preflight returned an invalid document.")
    require(value["system"] == "windows" and value["architecture"].lower() in {"x64", "x86_64"},
            "Guest preflight did not reach Windows x86_64.")
    require(str(uuid.UUID(value["vm_id"])) == profile["expected_vm_id"],
            "Guest preflight VM identity differs from the private profile.")
    require(all(isinstance(value[name], str) and value[name] for name in ("product_caption", "os_version", "build")),
            "Guest preflight Windows version/build is missing.")
    require("Windows 11" in value["product_caption"] and value["build"].isdigit()
            and int(value["build"]) >= 22000,
            "Guest preflight must prove a supported Windows 11 build.")
    canonical_id = str(uuid.UUID(value["vm_id"]))
    return {
        "system": "windows", "product_caption": value["product_caption"],
        "os_version": value["os_version"],
        "build": value["build"], "architecture": "x86_64",
        "vm_identity_kind": "hyper-v-guest-parameters-virtual-machine-id-v1",
        "vm_identity_sha256": digest_text(canonical_id),
    }


