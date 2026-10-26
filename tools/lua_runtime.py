"""Shared Lua runtime selection for the Fuchas test harnesses.

The test suite runs on real Lua interpreters through lupa so the installer and
kernel are executed, not just parsed.  OpenComputers 1.8.10+ ships Lua 5.3 and
has an experimental Lua 5.4 architecture, so both are supported:

    FUCHAS_LUA_VERSION=5.3 python tools/test_installer.py
    FUCHAS_LUA_VERSION=5.4 python tools/test_installer.py

The default is Lua 5.4.
"""

from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUPA_PATH = REPO / ".tools" / "py2.5"
if str(LUPA_PATH) not in sys.path:
    sys.path.insert(0, str(LUPA_PATH))


def lua_version() -> str:
    """Return the selected Lua version as "5.3" or "5.4"."""
    value = (os.environ.get("FUCHAS_LUA_VERSION") or "5.4").strip().lower()
    value = value.replace("lua", "").replace(" ", "")
    if value in {"53", "5.3"}:
        return "5.3"
    if value in {"54", "5.4"}:
        return "5.4"
    raise SystemExit(f"unsupported FUCHAS_LUA_VERSION: {value!r} (use 5.3 or 5.4)")


def make_lua(**kwargs):
    """Create a lupa runtime for the selected Lua version."""
    version = lua_version()
    module = importlib.import_module("lupa.lua" + version.replace(".", ""))
    return module.LuaRuntime(**kwargs)
