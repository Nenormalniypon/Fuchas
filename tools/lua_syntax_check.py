#!/usr/bin/env python3
"""Parse every Lua file in the project with a real Lua VM.

Usage: python tools/lua_syntax_check.py
Exits non-zero when at least one file fails to compile.

Binary payloads such as .efi/fuchas.efi2 (a CPIO archive) are skipped, as are
any other files that contain NUL bytes in their first few kilobytes.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))

from lua_runtime import lua_version, make_lua  # noqa: E402

SUFFIXES = (".lua", ".efi", ".efi2")


def is_binary(path):
    try:
        with open(path, "rb") as handle:
            return b"\0" in handle.read(4096)
    except OSError:
        return True


def main():
    lua = make_lua(unpack_returned_tuples=True)
    loadfile = lua.eval("loadfile")
    check = lua.eval("function(path) local f, err = loadfile(path, 't'); return f ~= nil, err end")
    count = 0
    skipped = []
    failed = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in (".git", ".tools", "node_modules", "__pycache__")]
        for name in filenames:
            if not name.endswith(SUFFIXES):
                continue
            path = os.path.join(dirpath, name)
            if is_binary(path):
                skipped.append(os.path.relpath(path, ROOT))
                continue
            count += 1
            ok, err = check(path)
            if not ok:
                failed.append((os.path.relpath(path, ROOT), err))
    print("checked %d Lua files with Lua %s" % (count, lua_version()))
    for path in skipped:
        print("skipped binary %s" % path)
    for path, err in failed:
        print("FAIL %s: %s" % (path, err))
    if failed:
        return 1
    print("all files compile")
    return 0


if __name__ == "__main__":
    sys.exit(main())
