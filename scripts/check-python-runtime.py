#!/usr/bin/env python3
"""Record and verify the selected tooling interpreter before running tools."""

import argparse
import json
import os
import platform
import ssl
import sys
import sysconfig


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exact", required=True, help="required CPython major.minor.patch")
    args = parser.parse_args()
    expected = tuple(int(part) for part in args.exact.split("."))
    if len(expected) != 3:
        parser.error("--exact requires major.minor.patch")

    gil_probe = getattr(sys, "_is_gil_enabled", None)
    gil_enabled = gil_probe() if gil_probe is not None else None
    jit = getattr(sys, "_jit", None)
    jit_available = jit.is_available() if jit is not None else None
    jit_enabled = jit.is_enabled() if jit is not None else None
    selected = os.environ.get("DARKRENAMER_PYTHON")
    record = {
        "implementation": platform.python_implementation(),
        "version": sys.version,
        "executable": sys.executable,
        "selected_executable": selected,
        "build": platform.python_build(),
        "compiler": platform.python_compiler(),
        "openssl": ssl.OPENSSL_VERSION,
        "gil_enabled": gil_enabled,
        "gil_disabled_build": sysconfig.get_config_var("Py_GIL_DISABLED"),
        "jit_available": jit_available,
        "jit_enabled": jit_enabled,
        "python_jit": os.environ.get("PYTHON_JIT"),
    }
    print(json.dumps(record, sort_keys=True))
    if record["implementation"] != "CPython" or sys.version_info[:3] != expected:
        raise SystemExit(f"Expected CPython {args.exact}")
    if selected is None or not os.path.samefile(sys.executable, selected):
        raise SystemExit("The running Python differs from DARKRENAMER_PYTHON")
    if record["gil_disabled_build"] not in (None, 0, "0") or gil_enabled is not True:
        raise SystemExit("Tooling requires a GIL-enabled CPython build")
    if jit_enabled is not False or record["python_jit"] != "0":
        raise SystemExit("Tooling requires PYTHON_JIT=0 and a disabled JIT")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
