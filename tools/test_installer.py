#!/usr/bin/env python3
"""Run Installers/openos.lua end-to-end against release.cpio.

This is a mock OpenOS environment: it executes the *real* installer and the
*real* Fuchas libraries with a real Lua 5.4 interpreter (lupa), using a
temporary directory as the target disk.  It does not need Minecraft or an
OpenComputers world.

Requirements:
    .tools/py2.5 must contain lupa (pip install --target .tools/py2.5 lupa==2.5)

Usage (from the repository root):
    python tools/test_installer.py
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUPA_PATH = REPO / ".tools" / "py2.5"
sys.path.insert(0, str(LUPA_PATH))
sys.path.insert(0, str(REPO / "tools"))

from lua_runtime import lua_version, make_lua


PASSWORD = "correct horse battery staple"


def lua_string(data: bytes) -> str:
    """Convert bytes to a Lua source literal using decimal escapes."""
    return '"' + "".join(
        chr(b) if 32 <= b < 127 and b not in (34, 92) else "\\%03d" % b
        for b in data
    ) + '"'


def main() -> int:
    erase = "--erase" in sys.argv[1:]
    temp_root = Path(tempfile.mkdtemp(prefix="fuchas-install-"))
    install_root = temp_root / "root"
    install_root.mkdir()
    shutil.copyfile(REPO / "release.cpio", install_root / "fuchas.cpio")

    lua = make_lua(unpack_returned_tuples=True)
    globals_ = lua.globals()
    globals_.INSTALL_ROOT = install_root.as_posix()
    globals_.PASSWORD = PASSWORD
    globals_.ERASE = erase

    # Python filesystem callbacks (Lua's standard library has no mkdir).
    def py_exists(path):
        return os.path.exists(path)

    def py_isdir(path):
        return os.path.isdir(path)

    def py_mkdir(path):
        os.makedirs(path, exist_ok=True)
        return True

    globals_.PY_EXISTS = py_exists
    globals_.PY_ISDIR = py_isdir
    globals_.PY_MKDIR = py_mkdir

    lua.execute(
        r"""
local ROOT = INSTALL_ROOT
local function map(path)
    path = tostring(path)
    if path:sub(1, 1) == "/" then
        return ROOT .. path
    end
    return path
end
MAP = map

-- ---------------------------------------------------------------------------
-- Filesystem shim over the temporary directory
-- ---------------------------------------------------------------------------
local fs = {}
function fs.exists(path) return PY_EXISTS(map(path)) end
function fs.isDirectory(path) return PY_ISDIR(map(path)) end
function fs.makeDirectory(path)
    local ok = PY_MKDIR(map(path))
    if not ok then error("mkdir failed: " .. tostring(path)) end
    return true
end
function fs.findNode(path)
    if not fs.exists(path) then return nil end
    return {fs = {isReadOnly = function() return false end}}
end
function fs.get(path) return fs.findNode(path) end
function fs.canonical(path)
    local parts = {}
    for part in tostring(path):gmatch("[^/]+") do parts[#parts + 1] = part end
    return table.concat(parts, "/")
end

-- ---------------------------------------------------------------------------
-- Fake hardware / OpenOS modules
-- ---------------------------------------------------------------------------
local gpu = {}
function gpu.getResolution() return 80, 25 end
function gpu.setResolution(w, h) return true end
function gpu.set() return true end
function gpu.fill() return true end
function gpu.copy() return true end
function gpu.setBackground() return true end
function gpu.setForeground() return true end
function gpu.getBackground() return 0 end
function gpu.getForeground() return 0xFFFFFF end

local password_queue = {PASSWORD, PASSWORD}
local term = {}
function term.gpu() return gpu end
function term.setCursor() return true end
function term.read()
    local value = table.remove(password_queue, 1)
    return value or PASSWORD
end
function term.write(value) return true end
function term.clear() return true end

local events = {
    {"key_up", false, false, 28}, -- stage 1: continue (dual boot)
    {"key_up", false, false, 28}, -- stage 2: install stable
}
if ERASE then
    events = {
        {"key_down", false, false, 200}, -- stage 1: select "Erase OpenOS"
        {"key_up", false, false, 28},
        {"key_up", false, false, 28}, -- stage 2: install stable
    }
end
local event = {}
function event.pull()
    local item = table.remove(events, 1)
    if item then return table.unpack(item) end
    return "key_down", false, false, 28
end

local computer = {}
function computer.uptime() return os.clock() end
function computer.shutdown()
    SHUTDOWN = true
    return true
end
function computer.getArchitectures() return {"Lua 5.4"} end
function computer.setArchitecture() return true end

local component = {}
function component.list(name)
    if name == "gpu" or name == "screen" or name == nil then
        return function() return nil end
    end
    return function() return nil end
end
function component.getPrimary() return nil end

local env = {BASE_DIR = "/", CPIO_BASE_DIR = "/"}
local realGetenv = os.getenv
os.getenv = function(name)
    if env[name] ~= nil then return env[name] end
    return realGetenv(name)
end
os.sleep = function() return true end

local realOpen = io.open
io.open = function(path, mode)
    return realOpen(map(path), mode)
end

local realDofile = dofile
local realLoadfile = loadfile
dofile = function(path) return realDofile(map(path)) end
loadfile = function(path) return realLoadfile(map(path)) end

local modules = {
    component = component,
    computer = computer,
    term = term,
    event = event,
    filesystem = fs,
}
require = function(name)
    local module = modules[name]
    if module == nil then error("unexpected require: " .. tostring(name)) end
    return module
end

SHUTDOWN = false
"""
    )

    installer = (REPO / "Installers" / "openos.lua").read_text(encoding="utf-8")
    # Expose the chunk as a function so the test can report errors cleanly.
    globals_.INSTALLER_SOURCE = installer
    ok = lua.execute(
        r"""
local chunk, err = load(INSTALLER_SOURCE, "=Installers/openos.lua")
if not chunk then error(err) end
chunk()
return true
"""
    )

    failures = []

    def check(condition, message):
        if not condition:
            failures.append(message)

    check(bool(globals_.SHUTDOWN), "installer did not request a shutdown")

    account_path = install_root / "Users" / "admin" / "account.lon"
    check(account_path.is_file(), "admin account was not created")
    check((install_root / "Fuchas" / "Kernel" / "boot.lua").is_file(),
          "Fuchas kernel missing after install")
    check((install_root / "init.lua").is_file(), "init.lua missing after install")

    if account_path.is_file():
        account_bytes = account_path.read_bytes()
        # Parse with the installed Fuchas liblon and verify the password hash
        # using the installed sha3 implementation.  Pass raw bytes so bytes
        # >= 0x80 in the random salt are not mangled by a UTF-8 decode.
        lua.globals().ACCOUNT_TEXT = account_bytes
        lua.globals().EXPECTED_PASSWORD = PASSWORD
        try:
            lua.execute(
                r"""
local liblon = assert(loadfile("Users/Shared/Libraries/liblon.lua"))()
local account = liblon.loadlon(ACCOUNT_TEXT)
assert(account.name == "admin", "wrong account name")
assert(account.security == "sha3-512", "wrong hash algorithm")
assert(type(account.salt) == "string" and #account.salt > 0, "missing salt")
assert(type(account.password) == "string" and #account.password == 128,
    "password hash is not sha3-512 hex")
local sha3 = assert(loadfile("Fuchas/Libraries/sha3.min.lua"))()
local hex = sha3.bin.stohex(sha3.sha3.sha512(account.salt .. EXPECTED_PASSWORD))
assert(hex == account.password, "password hash does not match the password")
ACCOUNT_OK = true
"""
            )
        except Exception as exc:  # lupa.LuaError
            failures.append(f"account verification failed: {exc}")
        check(bool(globals_.ACCOUNT_OK), "admin password verification failed")

    # Every file in the archive must have been extracted byte-for-byte.
    sys.path.insert(0, str(REPO / "tools"))
    import inspect_cpio

    entries = inspect_cpio.parse(str(REPO / "release.cpio"))
    for entry in entries:
        if entry["name"] == "TRAILER!!!":
            continue
        target = install_root / entry["name"]
        if (entry["mode"] & 0o170000) == 0o040000:
            check(target.is_dir(), f"missing directory: {entry['name']}")
        else:
            check(target.is_file(), f"missing file: {entry['name']}")
            if target.is_file() and entry["name"] != "init.lua":
                check(target.read_bytes() == entry["body"],
                      f"content mismatch: {entry['name']}")

    # In dual-boot mode the installer replaces init.lua with dualboot_init.lua;
    # in erase mode it keeps the normal init.lua.
    expected_loader = "init.lua" if erase else "dualboot_init.lua"
    check((install_root / "init.lua").read_bytes() == (REPO / expected_loader).read_bytes(),
          f"init.lua does not match {expected_loader}")

    if failures:
        print(f"FAIL ({len(failures)} problems), install root: {install_root}")
        for failure in failures:
            print("  -", failure)
        return 1

    print(f"installer test passed (Lua {lua_version()}); install root: {install_root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
