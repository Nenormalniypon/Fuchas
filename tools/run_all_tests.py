#!/usr/bin/env python3
"""Build the release archive and run the full test suite on Lua 5.3 and 5.4.

Usage (from the repository root):
    python tools/run_all_tests.py
    python tools/run_all_tests.py --lua 5.4

The suite is offline except for the installer's own network code, which is
never exercised: the installer tests use the local release.cpio.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

TESTS = [
    ("bootstrap", ["tools/test_bootstrap.py"]),
    ("installer (dual boot)", ["tools/test_installer.py"]),
    ("installer (erase)", ["tools/test_installer.py", "--erase"]),
    ("kernel boot", ["tools/test_boot.py"]),
    ("MineOS extractor", ["tools/test_mineos_extract.py"]),
    ("Fuchas upgrade", ["tools/test_upgrade.py"]),
    ("Stardust term", ["tools/test_stardust_term.py"]),
    ("Lua syntax", ["tools/lua_syntax_check.py"]),
]


def run(command: list[str], version: str) -> tuple[bool, str]:
    env = os.environ.copy()
    env["FUCHAS_LUA_VERSION"] = version
    result = subprocess.run(
        [sys.executable, *command],
        cwd=REPO,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    output = (result.stdout or "").strip()
    return result.returncode == 0, output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", action="append", choices=["5.3", "5.4"],
                        help="Lua version(s) to test; defaults to both")
    args = parser.parse_args()
    versions = args.lua or ["5.3", "5.4"]

    ok, output = run(["tools/build_cpio.py"], versions[0])
    print(("PASS " if ok else "FAIL ") + "build release.cpio")
    if not ok:
        print(output)
        return 1
    print("  " + output)

    failures = 0
    for version in versions:
        print(f"\n=== Lua {version} ===")
        for label, command in TESTS:
            ok, output = run(command, version)
            print(("PASS " if ok else "FAIL ") + label)
            if ok:
                print("  " + output.replace("\n", "\n  "))
            else:
                failures += 1
                print(output)

    print()
    if failures:
        print(f"{failures} test run(s) failed")
        return 1
    print("all tests passed on " + ", ".join("Lua " + v for v in versions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
