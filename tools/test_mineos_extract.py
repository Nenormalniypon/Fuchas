#!/usr/bin/env python3
"""Exercise the MineOS installer's CPIO extractor against release.cpio.

The extractor lives inside Installers/Fuchas.app/Main.lua, which needs the
MineOS GUI to load.  This harness slices out just the `extract` function and
runs it on Lua 5.4 with mocked filesystem/Screen/GUI objects, then verifies
that every archive entry was extracted byte-for-byte.

Usage (from the repository root):
    python tools/test_mineos_extract.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUPA_PATH = REPO / ".tools" / "py2.5"
sys.path.insert(0, str(LUPA_PATH))
sys.path.insert(0, str(REPO / "tools"))

from lua_runtime import lua_version, make_lua

import inspect_cpio


def extract_function_source() -> str:
    source = (REPO / "Installers" / "Fuchas.app" / "Main.lua").read_text(encoding="utf-8")
    start = source.index("local function extract(stream, progressBar)")
    end = source.index("local function readChangelog()", start)
    return source[start:end]


def main() -> int:
    archive = (REPO / "release.cpio").read_bytes()
    entries = inspect_cpio.parse(str(REPO / "release.cpio"))

    lua = make_lua(unpack_returned_tuples=True, encoding=None)
    g = lua.globals()
    g.ARCHIVE = archive
    g.EXTRACT_SOURCE = extract_function_source().encode("utf-8")

    lua.execute(
        r"""
local archive = ARCHIVE
local pos = 1
local stream = {}
function stream:readString(n)
    if n == nil then n = #archive - pos + 1 end
    if pos > #archive then return nil end
    local chunk = archive:sub(pos, pos + n - 1)
    pos = pos + #chunk
    return chunk
end
STREAM = stream

FILES = {}
DIRS = {["/"] = true}

local function ensure(path)
    local acc = ""
    for part in path:gmatch("[^/]+") do
        acc = acc .. "/" .. part
        DIRS[acc] = true
    end
end

filesystem = {}
function filesystem.makeDirectory(path)
    ensure(path)
    return true
end
function filesystem.open(path, mode)
    local file = {path = path, data = ""}
    function file:write(data)
        self.data = self.data .. data
        return self
    end
    function file:close()
        FILES[self.path] = self.data
        return true
    end
    return file
end

progressText = {}
progressBar = {roll = function() end}
workspace = {draw = function() end}
require = function(name)
    if name == "Screen" then return {update = function() end} end
    error("unexpected require: " .. tostring(name))
end

local extract = assert(load(EXTRACT_SOURCE .. "\nreturn extract", "=extract"))()
extract(STREAM, progressBar)
EXTRACT_OK = true
"""
    )

    failures = []
    extracted = g.FILES

    for entry in entries:
        if entry["name"] == "TRAILER!!!":
            continue
        name = ("/" + entry["name"]).encode("utf-8")
        if (entry["mode"] & 0o170000) == 0o040000:
            if not g.DIRS[name]:
                failures.append(f"missing directory: {entry['name']}")
        else:
            if extracted[name] is None:
                failures.append(f"missing file: {entry['name']}")
            elif extracted[name] != entry["body"]:
                failures.append(f"content mismatch: {entry['name']}")

    if failures:
        print(f"FAIL ({len(failures)} problems)")
        for failure in failures:
            print("  -", failure)
        return 1

    print(f"MineOS extractor test passed (Lua {lua_version()}, {len(entries) - 1} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
