#!/usr/bin/env python3
"""Test Stardust's term.read compatibility with modern and legacy OpenOS.

Runs Users/Shared/Libraries/stardust/term.lua on Lua 5.4 with mocked
event/shell/io/component modules.

Usage (from the repository root):
    python tools/test_stardust_term.py
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUPA_PATH = REPO / ".tools" / "py2.5"
sys.path.insert(0, str(LUPA_PATH))
sys.path.insert(0, str(REPO / "tools"))

from lua_runtime import lua_version, make_lua


def main() -> int:
    lua = make_lua(unpack_returned_tuples=True)
    g = lua.globals()

    lua.execute(
        r"""
local shell = {}
local lastReadOptions
local readResult = "typed text"
function shell.read(options)
    lastReadOptions = options
    return readResult
end
function shell.getCursor() return 3, 4 end
function shell.setCursor(col, row) CURSOR = {col, row} end
function shell.clear() CLEARED = true end
function shell.getY() return 7 end

local event = {}
function event.pull(...) return "pulled", ... end

local output = {}
local stdout = {}
function stdout:write(value) output[#output + 1] = value end

component = {gpu = nil}

require = function(name)
    if name == "event" then return event end
    if name == "shell" then return shell end
    if name == "stardust/text" then
        return {detab = function(value, tab) return "DETAB(" .. value .. "," .. tostring(tab) .. ")" end}
    end
    if name == "component" then return component end
    error("unexpected require: " .. tostring(name))
end

io.stdout = stdout
function getReadOptions() return lastReadOptions end
function setReadResult(value) readResult = value end
function getOutput() return output end
"""
    )

    g.TERM_PATH = (REPO / "Users" / "Shared" / "Libraries" / "stardust" / "term.lua").as_posix()
    lua.execute('TERM = assert(loadfile(TERM_PATH))()')

    failures = []

    def run(label, code):
        try:
            lua.execute(code)
        except Exception as exc:  # lupa.LuaError
            failures.append(f"{label}: {exc}")

    # Modern signature: term.read(history, dobreak, hint, pwchar, filter).
    run(
        "modern term.read signature",
        r"""
local history = {"old command"}
local hintWasWritten = false
local oldWrite = TERM.write
TERM.write = function(value) hintWasWritten = (value == "hint>") end
local value = TERM.read(history, nil, "hint>", "*")
TERM.write = oldWrite
local options = getReadOptions()
assert(options, "shell.read was not called")
assert(options.pwchar == "*", "pwchar was not forwarded")
assert(options.history == history, "history was not forwarded")
assert(hintWasWritten, "hint was not written")
assert(value == "typed text\n", "default dobreak should append a newline")
""",
    )

    # Modern signature with dobreak = false must not append a newline.
    run(
        "modern dobreak=false",
        r"""
local value = TERM.read(nil, false)
assert(value == "typed text", "dobreak=false should not append a newline")
""",
    )

    # Legacy options-table signature, including a custom history list.
    run(
        "legacy options table",
        r"""
local options = {dobreak = false, pwchar = "#", history = {"y"}}
local value = TERM.read(options)
local seen = getReadOptions()
assert(seen == options, "legacy options table was not forwarded as-is")
assert(seen.pwchar == "#", "legacy pwchar was lost")
assert(value == "typed text", "legacy dobreak=false should not append a newline")
""",
    )

    # term.write must detab through stardust/text.
    run(
        "term.write",
        r"""
TERM.write("a\tb")
local output = getOutput()
assert(#output == 1, "term.write did not write once")
assert(output[1] == "DETAB(a\tb,8)", "unexpected term.write output: " .. tostring(output[1]))
""",
    )

    # Viewport/global area should use the GPU driver when available.
    run(
        "term viewport",
        r"""
component.gpu = {
    getViewport = function() return 80, 25, 1, 1, 80, 25 end,
    getResolution = function() return 80, 25 end,
}
local w, h = TERM.getViewport()
assert(w == 80 and h == 25, "term.getViewport did not use the GPU")
local gx, gy, gw, gh = TERM.getGlobalArea()
assert(gx == 1 and gy == 1 and gw == 80 and gh == 25, "term.getGlobalArea is wrong")
component.gpu = nil
local dw, dh = TERM.getViewport()
assert(dw == 160 and dh == 50, "term.getViewport fallback is wrong")
local dx, dy, dxw, dxh = TERM.getGlobalArea()
assert(dx == 1 and dy == 1 and dxw == 160 and dxh == 50, "term.getGlobalArea fallback is wrong")
""",
    )

    if failures:
        print(f"FAIL ({len(failures)} problems)")
        for failure in failures:
            print("  -", failure)
        return 1

    print(f"Stardust term test passed (Lua {lua_version()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
