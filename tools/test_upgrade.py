#!/usr/bin/env python3
"""Run Fuchas' own upgrade-fuchas.lua against release.cpio.

The script executes `install()` on load, so this harness mocks the driver,
filesystem and io modules in memory, feeds it the real release.cpio through a
fake internet driver, and then checks every entry was extracted byte-for-byte.

Usage (from the repository root):
    python tools/test_upgrade.py
"""

from __future__ import annotations

import stat
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUPA_PATH = REPO / ".tools" / "py2.5"
sys.path.insert(0, str(LUPA_PATH))
sys.path.insert(0, str(REPO / "tools"))

from lua_runtime import lua_version, make_lua

import build_cpio
import inspect_cpio

UPGRADE = REPO / "Fuchas" / "Binaries" / "upgrade-fuchas.lua"


def pack_entry(name: str, data: bytes, mode: int) -> bytes:
    name_len = len(name.encode("utf-8")) + 1
    out = build_cpio.header(name, mode, len(data), 1)
    if name_len % 2:
        out += b"\0"
    out += data
    if len(data) % 2:
        out += b"\0"
    return out


def make_traversal_archive() -> bytes:
    archive = pack_entry("../escape.lua", b"pwned", stat.S_IFREG | 0o664)
    archive += pack_entry("/absolute.lua", b"pwned", stat.S_IFREG | 0o664)
    archive += pack_entry("good.lua", b"ok", stat.S_IFREG | 0o664)
    trailer = "TRAILER!!!"
    archive += build_cpio.header(trailer, 0, 0, 99)
    if (len(trailer) + 1) % 2:
        archive += b"\0"
    return archive


def run_upgrade(archive: bytes) -> tuple[dict, dict]:
    lua = make_lua(unpack_returned_tuples=True, encoding=None)
    g = lua.globals()
    g.ARCHIVE = archive
    g.UPGRADE_PATH = str(UPGRADE).encode("utf-8")

    lua.execute(
        r"""
FILES = {}
DIRS = {}
PRINTED = {}

local function reader(data)
    local pos = 1
    local obj = {}
    function obj:read(n)
        if pos > #data then return nil end
        if n == nil or n == math.huge then n = #data - pos + 1 end
        local chunk = data:sub(pos, pos + n - 1)
        pos = pos + #chunk
        if #chunk == 0 then return nil end
        return chunk
    end
    function obj:seek() return pos end
    function obj:close() end
    return obj
end

filesystem = {}
function filesystem.isDirectory(path) return DIRS[path] == true end
function filesystem.makeDirectory(path)
    local acc = ""
    for part in path:gmatch("[^/]+") do
        acc = acc .. (acc == "" and "" or "/") .. part
        DIRS[acc] = true
    end
    return true
end
function filesystem.remove(path) FILES[path] = nil return true end
function filesystem.open(path, mode)
    if mode == "w" or mode == "wb" then
        local obj = {data = ""}
        function obj:write(value) self.data = self.data .. value end
        function obj:close() FILES[path] = self.data end
        return obj
    end
    if not FILES[path] then return nil end
    return reader(FILES[path])
end

driver = {
    internet = {
        httpDownload = function(url, dest)
            FILES[dest] = ARCHIVE
            return true
        end
    }
}
component = {}

local real_open = io.open
io.open = function(path, mode) return filesystem.open(path, mode) end
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    PRINTED[#PRINTED + 1] = table.concat(parts, "\t")
end

require = function(name)
    if name == "filesystem" then return filesystem end
    if name == "driver" then return driver end
    error("unexpected require: " .. tostring(name))
end

local chunk = assert(loadfile(UPGRADE_PATH))
chunk()
UPGRADE_OK = true
"""
    )

    if not g.UPGRADE_OK:
        raise SystemExit("upgrade-fuchas.lua did not finish")

    return g.FILES, g.DIRS


def check_archive(label: str, archive: bytes, entries: list[dict]) -> list[str]:
    files, dirs = run_upgrade(archive)
    failures = []

    for entry in entries:
        if entry["name"] == "TRAILER!!!":
            continue
        key = ("A:/" + entry["name"]).encode("utf-8")
        if (entry["mode"] & 0o170000) == 0o040000:
            if dirs[key] is not True:
                failures.append(f"{label}: missing directory {entry['name']}")
        else:
            if files[key] is None:
                failures.append(f"{label}: missing file {entry['name']}")
            elif files[key] != entry["body"]:
                failures.append(f"{label}: content mismatch {entry['name']}")

    if files[b"A:/Temporary/fuchas.cpio"] is not None:
        failures.append(f"{label}: temporary archive was not removed")

    return failures


def main() -> int:
    entries = inspect_cpio.parse(str(REPO / "release.cpio"))
    failures = check_archive("release.cpio", (REPO / "release.cpio").read_bytes(), entries)

    traversal = make_traversal_archive()
    files, _ = run_upgrade(traversal)
    if files[b"A:/good.lua"] != b"ok":
        failures.append("traversal archive: good.lua was not extracted")
    for key in files:
        if b"escape" in key or b"absolute" in key:
            failures.append(f"traversal archive: unsafe path extracted: {key!r}")

    if failures:
        print(f"FAIL ({len(failures)} problems)")
        for failure in failures:
            print("  -", failure)
        return 1

    print(f"upgrade-fuchas test passed (Lua {lua_version()}, {len(entries) - 1} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
