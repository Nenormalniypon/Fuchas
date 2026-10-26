#!/usr/bin/env python3
"""Boot the installed Fuchas tree in a mocked OpenComputers environment.

This executes the real Fuchas boot sequence (package, filesystem, event, log,
tasks, security, kernel startup modules) on Lua 5.4 with an in-memory disk.
It stops at a stubbed bootmgr so no interactive interface is needed.

Usage (from the repository root):
    python tools/test_boot.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUPA_PATH = REPO / ".tools" / "py2.5"
sys.path.insert(0, str(LUPA_PATH))
sys.path.insert(0, str(REPO / "tools"))

from lua_runtime import lua_version, make_lua

import inspect_cpio


def build_fs_from_archive() -> tuple[dict, dict]:
    files = {}
    dirs = {"": True}

    def add_parents(name: str) -> None:
        parts = name.split("/")
        for i in range(1, len(parts)):
            dirs["/".join(parts[:i])] = True

    for entry in inspect_cpio.parse(str(REPO / "release.cpio")):
        name = entry["name"]
        if name == "TRAILER!!!":
            continue
        add_parents(name)
        if (entry["mode"] & 0o170000) == 0o040000:
            dirs[name] = True
        else:
            files[name] = entry["body"]
    # The kernel boots bootmgr in an endless loop; replace it with a marker so
    # the test can stop right after the startup modules have run.
    files["Fuchas/bootmgr.lua"] = b"-- boot harness stub\nBOOTMGR_REACHED = true\n"
    # Include a real admin account (password "admin") to exercise users.login.
    files["Users/admin/account.lon"] = (REPO / "Users" / "admin" / "account.lon").read_bytes()
    dirs["Users/admin"] = True
    return files, dirs


def _dump_gpu(g) -> None:
    """Print the tail of what the kernel wrote to the mocked GPU."""
    try:
        text = g.GPU_TEXT
        n = len(text)
        print("--- screen output ---")
        for i in range(1, n + 1):
            value = text[i]
            if value is not None:
                print(str(value)[:200])
        print("--- end screen output (%d writes) ---" % n)
    except Exception as exc:  # pragma: no cover - debugging helper
        print("could not read GPU output:", exc)


def main() -> int:
    files, dirs = build_fs_from_archive()
    lua = make_lua(unpack_returned_tuples=True)
    g = lua.globals()
    # Lua tables, not Python dicts: a Python dict raises KeyError for missing
    # keys, while the filesystem mock relies on absent keys returning nil.
    g.FS_FILES = lua.table_from(files)
    g.FS_DIRS = lua.table_from(dirs)
    g.BOOTMGR_REACHED = False
    g.SHUTDOWN = False

    lua.execute(
        r"""
local files, dirs = FS_FILES, FS_DIRS

local function norm(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^%a:/", ""):gsub("^/+", ""):gsub("/+$", "")
    return path
end
NORM = norm

-- ---------------------------------------------------------------------------
-- Minimal unicode/checkArg globals expected by Fuchas
-- ---------------------------------------------------------------------------
unicode = {
    len = function(s) return #s end,
    sub = function(s, i, j) return s:sub(i, j) end,
    char = function(c) return string.char(c) end,
    wlen = function(s) return #s end,
    upper = function(s) return s:upper() end,
    lower = function(s) return s:lower() end,
}
function checkArg(n, value, ...)
    local expected = {...}
    local actual = type(value)
    for _, t in ipairs(expected) do
        local base = t:gsub("%?$", "")
        if actual == base then return end
    end
    error("bad argument #" .. n .. " (" .. table.concat(expected, " or ") ..
        " expected, got " .. actual .. ")", 3)
end

-- ---------------------------------------------------------------------------
-- In-memory drive proxy
-- ---------------------------------------------------------------------------
local function newProxy(address)
    local proxy = {type = "filesystem", address = address}
    function proxy.isReadOnly() return false end
    function proxy.exists(path) local k = norm(path); return files[k] ~= nil or dirs[k] ~= nil end
    function proxy.isDirectory(path) return dirs[norm(path)] == true end
    function proxy.size(path) local d = files[norm(path)]; return d and #d or 0 end
    function proxy.lastModified() return 0 end
    function proxy.getAttributes() return 0 end

    function proxy.list(path)
        local prefix = norm(path)
        if prefix ~= "" then prefix = prefix .. "/" end
        local seen, out = {}, {}
        local function scan(tbl)
            for key in pairs(tbl) do
                if key:sub(1, #prefix) == prefix then
                    local rest = key:sub(#prefix + 1)
                    local name = rest:match("^([^/]+)")
                    if name and not seen[name] then
                        seen[name] = true
                        out[#out + 1] = name
                    end
                end
            end
        end
        scan(files)
        scan(dirs)
        table.sort(out)
        return out
    end

    function proxy.makeDirectory(path)
        local k = norm(path)
        local acc = ""
        for part in k:gmatch("[^/]+") do
            acc = acc == "" and part or (acc .. "/" .. part)
            dirs[acc] = true
        end
        return true
    end

    function proxy.remove(path)
        local k = norm(path)
        if files[k] then files[k] = nil; return true end
        if dirs[k] then dirs[k] = nil; return true end
        return false
    end

    function proxy.rename(old, new)
        local a, b = norm(old), norm(new)
        if files[a] then files[b] = files[a]; files[a] = nil; return true end
        if dirs[a] then dirs[b] = true; dirs[a] = nil; return true end
        return false
    end

    function proxy.open(path, mode)
        local k = norm(path)
        mode = mode or "r"
        if mode:sub(1, 1) == "r" then
            if not files[k] then return nil, "no such file" end
            return {key = k, pos = 1, mode = "r"}
        end
        if mode:sub(1, 1) == "w" then
            files[k] = ""
            return {key = k, pos = 1, mode = "w"}
        end
        if mode:sub(1, 1) == "a" then
            files[k] = files[k] or ""
            return {key = k, pos = #files[k] + 1, mode = "a"}
        end
        return nil, "bad mode"
    end

    function proxy.read(handle, amount)
        local data = files[handle.key] or ""
        if handle.pos > #data then return nil end
        if amount == nil or amount == math.huge then amount = #data - handle.pos + 1 end
        amount = math.floor(amount)
        local chunk = data:sub(handle.pos, handle.pos + amount - 1)
        handle.pos = handle.pos + #chunk
        return chunk
    end

    function proxy.write(handle, data)
        local current = files[handle.key] or ""
        files[handle.key] = current:sub(1, handle.pos - 1) .. data ..
            current:sub(handle.pos + #data)
        handle.pos = handle.pos + #data
        return true
    end

    function proxy.seek(handle, whence, offset)
        whence = whence or "cur"
        offset = offset or 0
        local base
        if whence == "set" then base = 1
        elseif whence == "cur" then base = handle.pos
        elseif whence == "end" then base = #(files[handle.key] or "") + 1
        else return nil, "bad whence" end
        handle.pos = math.max(1, base + offset)
        return handle.pos - 1
    end

    function proxy.close() return true end
    return proxy
end

-- ---------------------------------------------------------------------------
-- Component and hardware mocks
-- ---------------------------------------------------------------------------
local devices = {
    boot = "filesystem",
    tmp = "filesystem",
    gpu1 = "gpu",
    screen1 = "screen",
    kbd1 = "keyboard",
}

local gpuProxy = {type = "gpu", address = "gpu1"}
GPU_TEXT = {}
gpuProxy.viewportW, gpuProxy.viewportH = 160, 50
function gpuProxy.maxResolution() return 160, 50 end
function gpuProxy.getDepth() return 8 end
function gpuProxy.getViewport() return gpuProxy.viewportW, gpuProxy.viewportH end
function gpuProxy.setViewport(w, h) gpuProxy.viewportW, gpuProxy.viewportH = w, h; return true end
function gpuProxy.getResolution() return gpuProxy.viewportW, gpuProxy.viewportH end
function gpuProxy.setResolution(w, h) return gpuProxy.setViewport(w, h) end
function gpuProxy.getBufferSize() return gpuProxy.viewportW, gpuProxy.viewportH end
function gpuProxy.set(x, y, text)
    if #GPU_TEXT < 2000 then
        GPU_TEXT[#GPU_TEXT + 1] = tostring(text)
    end
    return true
end
function gpuProxy.fill() return true end
function gpuProxy.copy() return true end
function gpuProxy.get() return " " end
function gpuProxy.setBackground() return true end
function gpuProxy.setForeground() return true end
function gpuProxy.getBackground() return 0 end
function gpuProxy.getForeground() return 0xFFFFFF end
function gpuProxy.setActiveBuffer() return true end
function gpuProxy.getActiveBuffer() return 0 end
function gpuProxy.bind() return true end

local screenProxy = {type = "screen", address = "screen1"}
function screenProxy.getKeyboards() return {"kbd1"} end
function screenProxy.isOn() return true end
function screenProxy.turnOn() return true end

local kbdProxy = {type = "keyboard", address = "kbd1"}
function kbdProxy.isCtrlPressed() return false end
function kbdProxy.isAltPressed() return false end
function kbdProxy.isShiftPressed() return false end
function kbdProxy.isPressed() return false end
function kbdProxy.resetInterrupted() return true end

local proxies = {
    boot = newProxy("boot"),
    tmp = newProxy("tmp"),
    gpu1 = gpuProxy,
    screen1 = screenProxy,
    kbd1 = kbdProxy,
}

local function makeList(filter, exact)
    local t, order = {}, {}
    for addr, typ in pairs(devices) do
        local match
        if filter == nil then match = true
        elseif exact then match = (typ == filter)
        else match = typ:find(filter, 1, true) ~= nil end
        if match then t[addr] = typ; order[#order + 1] = addr end
    end
    table.sort(order)
    return setmetatable(t, {
        -- A generic `for k, v in component.list() do` calls the iterator with
        -- (state, control), i.e. the callable table receives (self, nil, key).
        -- OpenComputers' own list metatable works this way, and Fuchas also
        -- indexes the returned table, so keep it a table instead of a closure.
        __call = function(self, _, prev)
            local index
            if prev == nil then
                index = 1
            else
                index = 1
                while order[index] and order[index] ~= prev do index = index + 1 end
                index = index + 1
            end
            local key = order[index]
            if key then return key, t[key] end
        end
    })
end

component = {}
function component.list(filter, exact) return makeList(filter, exact) end
function component.type(address) return devices[address] end
function component.proxy(address) return proxies[address] end
function component.invoke(address, method, ...)
    local proxy = proxies[address]
    if proxy and proxy[method] then return proxy[method](proxy, ...) end
end

computer = {}
function computer.getBootAddress() return "boot" end
function computer.tmpAddress() return "tmp" end
function computer.supportsOEFI() return false end
function computer.uptime() return os.clock() end
function computer.pushSignal() return true end
function computer.pullSignal()
    -- After the bootmgr stub runs, fake a key press so the kernel's 30-second
    -- "press any key to reboot" countdown is skipped in the harness.  A real
    -- OpenComputers key signal carries (name, address, char, code).
    if BOOTMGR_REACHED then return "key_down", "kbd1", "", 28 end
end
function computer.shutdown() SHUTDOWN = true; return true end

local env = {}
local realGetenv = os.getenv
os.getenv = function(name) return env[name] end
os.setenv = function(name, value) env[name] = value end

-- ---------------------------------------------------------------------------
-- loadfile/dofile over the in-memory disk (before Fuchas replaces loadfile)
-- ---------------------------------------------------------------------------
local function memLoadfile(path)
    local key = norm(path)
    local data = files[key]
    if not data then return nil, "no such file: " .. tostring(path) end
    return load(data, "=" .. path, "bt", _G)
end
loadfile = memLoadfile
dofile = function(path, ...)
    local chunk, err = memLoadfile(path)
    if not chunk then error(err) end
    return chunk(...)
end

BOOTMGR_REACHED = false
"""
    )

    boot_source = (REPO / "Fuchas" / "Kernel" / "boot.lua").read_text(encoding="utf-8")
    g.BOOT_SOURCE = boot_source
    g.BOOT_PASSWORD = "admin"

    g.BOOT_TEST_OK = False
    try:
        lua.execute(
            r"""
local chunk, err = load(BOOT_SOURCE, "=Fuchas/Kernel/boot.lua")
if not chunk then error(err) end
chunk()
if not BOOTMGR_REACHED then error("bootmgr stub was not reached") end

-- Everything below runs after boot.lua has called protectEnv().
local fs = require("filesystem")
assert(type(io.fromunum) == "function", "02_io did not initialize")
assert(type(io.tounum) == "function", "02_io did not initialize")

-- 32-bit bit32 shim semantics
assert(bit32.band(0xFFFFFFFF, 0xFFFF) == 0xFFFF)
assert(bit32.band() == 0xFFFFFFFF)
assert(bit32.bor(0x80000000, 1) == 0x80000001)
assert(bit32.bxor(0xFFFFFFFF, 0xFF) == 0xFFFFFF00)
assert(bit32.bnot(0) == 0xFFFFFFFF)
assert(bit32.lshift(1, 31) == 0x80000000)
assert(bit32.lshift(1, 32) == 0)
assert(bit32.rshift(0x80000000, 31) == 1)
assert(bit32.btest(0x80000000, 0x80000000))
assert(bit32.extract(0xABCD, 8, 8) == 0xAB)
assert(bit32.replace(0, 0xFF, 8, 8) == 0xFF00)

-- filesystem basics, including case-insensitive drive letters and drives
assert(fs.exists("A:/Fuchas/Kernel/boot.lua"))
assert(fs.exists("a:/Fuchas/Kernel/boot.lua"))
assert(fs.isDirectory("A:/Fuchas/Kernel/Startup"))
assert(fs.freeDriveLetter() == "B", "unexpected free drive letter")
local count = 0
for _ in fs.list("A:/Fuchas/Kernel/Startup/") do count = count + 1 end
assert(count == 4, "unexpected startup file count: " .. count)

local handle = assert(fs.open("A:/Fuchas/permissions.lon", "r"))
local permissions = handle:read(math.huge)
handle:close()
assert(permissions and permissions:find("admin", 1, true))

-- copy/rename must create parents and return success
assert(fs.copy("A:/Fuchas/permissions.lon", "A:/tmp-dir/copied.lon"))
assert(fs.exists("A:/tmp-dir/copied.lon"))
assert(fs.rename("A:/tmp-dir/copied.lon", "A:/tmp-dir/renamed.lon"))
assert(fs.exists("A:/tmp-dir/renamed.lon"))
assert(not fs.exists("A:/tmp-dir/copied.lon"))
local attrs = fs.getAttributes("A:/Fuchas/permissions.lon")
assert(type(attrs) == "table" and attrs.readOnly ~= nil)

-- mountDrive normalizes lower-case letters
assert(fs.mountDrive(require("component").proxy("tmp"), "b"))
assert(fs.isMounted("B") and fs.getProxy("b"))
assert(fs.unmountDrive("B"))

-- task helpers should not crash when asked about unknown pids
local tasks = require("tasks")
assert(type(tasks.newDaemon("unit-test", function() end)) == "table")
assert(tasks.getProcessMetrics(999999) == nil)

-- timers must use the wall clock (computer.uptime), not os.clock
local event = require("event")
local fired = false
event.register("unit_test_event", function() fired = true end, 0, 1)
event.exechandlers({"unit_test_event"})
assert(fired, "event timer did not fire")

-- users/security integration: fake an active process, then log in as admin
local function setCurrentProcess(value)
    local i = 1
    while true do
        local name = debug.getupvalue(tasks.getCurrentProcess, i)
        if not name then break end
        if name == "currentProc" then
            debug.setupvalue(tasks.getCurrentProcess, i, value)
            return true
        end
        i = i + 1
    end
    return false
end
assert(setCurrentProcess({pid = 999, exitHandlers = {}, env = {}, events = {}, io = {}}),
    "could not patch tasks.currentProc")

-- users.login reads account files through buffered streams, which politely
-- yield to the process scheduler.  Drive the section inside a coroutine, like
-- a real Fuchas process, so those yields are resumed.
local function runAsProcess(fn)
    local co = coroutine.create(fn)
    while true do
        local ok, err = coroutine.resume(co)
        if not ok then error(err, 0) end
        if coroutine.status(co) == "dead" then break end
    end
end

runAsProcess(function()
    -- bootmgr normally runs Fuchas/autorun.lua inside a process, which sets
    -- LIB_PATH; require() switches to its protected package.loaded only once
    -- that variable exists.
    os.setenv("LIB_PATH", "A:/Fuchas/Libraries/?.lua;A:/Users/Shared/Libraries/?.lua")
    os.setenv("USER", "guest")
    local users = require("users")
    assert(users.login("admin", BOOT_PASSWORD), "admin login failed")
    local user = users.getUser()
    assert(user and user.name == "admin", "logged in user is wrong")
    assert(users.getUserPath() == "A:/Users/admin", "wrong user path: " .. tostring(users.getUserPath()))
    local security = require("security")
    assert(security.hasPermission("users.create"), "admin should have all permissions")
    assert(security.hasPermission("*"))
    assert(security.getPermissions()[ "*" ])
    assert(users.logout())
    assert(users.getUserPath() == "A:/Users/Shared")
end)

setCurrentProcess(nil)

-- component wrapper should expose primaries outside a process (boot context)
assert(component.gpu ~= nil, "component.gpu is not available")
assert(component.gpu.getDepth() == 8)

BOOT_TEST_OK = true
"""
        )
    except Exception as exc:  # lupa.LuaError
        print("boot/assert phase failed:", exc)
        _dump_gpu(g)
        return 1

    if not g.BOOT_TEST_OK:
        print("boot test failed")
        _dump_gpu(g)
        return 1

    print(f"boot test passed (Lua {lua_version()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
