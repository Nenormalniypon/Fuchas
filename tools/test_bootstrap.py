#!/usr/bin/env python3
"""Test Installers/bootstrap.lua against a mocked OpenOS internet stack.

Covers mirror fallback, branch forwarding, HTTP error handling and the final
"could not download" error.

Usage (from the repository root):
    python tools/test_bootstrap.py
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUPA_PATH = REPO / ".tools" / "py2.5"
sys.path.insert(0, str(LUPA_PATH))
sys.path.insert(0, str(REPO / "tools"))

from lua_runtime import lua_version, make_lua

BOOTSTRAP = REPO / "Installers" / "bootstrap.lua"


def run_bootstrap(branch: str | None, match: str | None) -> tuple[bool, str]:
    """Run bootstrap.lua; `match` limits which URL succeeds (None = all fail)."""
    lua = make_lua(unpack_returned_tuples=True)
    g = lua.globals()
    g.BOOTSTRAP_PATH = str(BOOTSTRAP)
    g.BRANCH = branch
    g.MATCH = match
    g.INSTALLER_SOURCE = "BOOTSTRAP_INSTALLER_RAN = true\n"

    lua.execute(
        r"""
local written = {}
term = {
    write = function(value) written[#written + 1] = value end
}
TERM_OUTPUT = written

internet = {}
function internet.request(url)
    if MATCH == nil or not url:find(MATCH, 1, true) then
        return nil, "not found"
    end
    local source = INSTALLER_SOURCE
    local pos = 1
    local handle = {}
    function handle:finishConnect() return true end
    function handle:response() return 200, "OK" end
    function handle:read(n)
        if pos > #source then return nil end
        local chunk = source:sub(pos, pos + n - 1)
        pos = pos + #chunk
        return chunk
    end
    function handle:close() end
    return handle
end

computer = {getArchitecture = function() return "Lua 5.3" end}

package.preload["internet"] = function() return internet end
package.preload["computer"] = function() return computer end
package.preload["term"] = function() return term end

local chunk = assert(loadfile(BOOTSTRAP_PATH))
local args = {}
if BRANCH ~= nil then args[1] = BRANCH end
local ok, err = pcall(chunk, table.unpack(args))
BOOTSTRAP_RAN = true
BOOTSTRAP_OK = ok
BOOTSTRAP_ERROR = tostring(err)
BOOTSTRAP_INSTALLED = BOOTSTRAP_INSTALLER_RAN == true
"""
    )

    output = "\n".join(str(g.TERM_OUTPUT[i]) for i in range(1, len(g.TERM_OUTPUT) + 1))
    ok = bool(g.BOOTSTRAP_OK) and bool(g.BOOTSTRAP_INSTALLED)
    return ok, g.BOOTSTRAP_ERROR or output


def main() -> int:
    failures = []

    ok, detail = run_bootstrap(None, "cdn.jsdelivr.net")
    if not ok:
        failures.append("default branch: bootstrap failed: " + detail)

    ok, detail = run_bootstrap("dev", "/dev/")
    if not ok:
        failures.append("branch forwarding: bootstrap failed: " + detail)

    ok, detail = run_bootstrap(None, None)
    if ok:
        failures.append("all mirrors down: bootstrap should have failed")
    elif "could not download" not in detail:
        failures.append("all mirrors down: unexpected error: " + detail)

    if failures:
        print(f"FAIL ({len(failures)} problems)")
        for failure in failures:
            print("  -", failure)
        return 1

    print(f"bootstrap test passed (Lua {lua_version()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
