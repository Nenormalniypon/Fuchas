#!/usr/bin/env python3
"""Build Fuchas' old-binary (070707) CPIO release archive.

The OpenOS installer and Fuchas' own cpio library both expect the *old
binary* format, not the ASCII "newc" format produced by most modern cpio
commands.  This script writes that format directly so releases can be built
on Windows without a native cpio binary.

Usage (from the repository root):
    python tools/build_cpio.py
    python tools/build_cpio.py --output release.cpio
"""

from __future__ import annotations

import argparse
import os
import stat
import struct
import sys
from pathlib import Path

MAGIC = 0o070707
TRAILER = "TRAILER!!!"

# Entries packed into release.cpio.  Paths are relative to the repository
# root.  Directories are walked recursively.
INCLUDES = [
    "Fuchas",
    "Users/Shared/Libraries",
    "Users/Shared/account.lon",
    "Users/Shared/Binaries/stardust.lua",
    ".efi",
    "init.lua",
    "dualboot_init.lua",
]

EXCLUDED_NAMES = {
    ".git",
    "__pycache__",
    ".DS_Store",
    "Thumbs.db",
}

EXCLUDED_SUFFIXES = (".pyc", ".pyo", ".swp", "~")


def posix(path: Path) -> str:
    return path.as_posix()


def collect(root: Path) -> list[tuple[str, Path | None]]:
    """Return (archive name, source path or None for a directory) tuples."""
    entries: list[tuple[str, Path | None]] = []
    seen: set[str] = set()

    def add(path: Path, name: str | None = None) -> None:
        name = name or posix(path.relative_to(root))
        if name in seen:
            return
        seen.add(name)
        if path.is_dir():
            entries.append((name, None))
            children = sorted(path.iterdir(), key=lambda p: p.name)
            for child in children:
                if child.name in EXCLUDED_NAMES:
                    continue
                if child.name.endswith(EXCLUDED_SUFFIXES):
                    continue
                add(child)
        else:
            entries.append((name, path))

    for item in INCLUDES:
        path = root / item
        if not path.exists():
            raise SystemExit(f"missing include: {item}")
        add(path)
    return entries


def header(name: str, mode: int, size: int, ino: int) -> bytes:
    name_bytes = name.encode("utf-8") + b"\0"
    namesize = len(name_bytes)
    filesize_high, filesize_low = size >> 16, size & 0xFFFF
    return struct.pack(
        "<13H",
        MAGIC,
        0x800,          # dev
        ino & 0xFFFF,   # ino
        mode & 0xFFFF,  # mode
        0,              # uid
        0,              # gid
        2 if stat.S_ISDIR(mode) else 1,  # nlink
        0,              # rdev
        0,              # mtime high
        0,              # mtime low
        namesize,
        filesize_high,
        filesize_low,
    ) + name_bytes


def build_entries(entries: list[tuple[str, Path | None]], output: Path) -> tuple[int, int]:
    out = bytearray()
    file_count = 0

    for ino, (name, path) in enumerate(entries, start=1):
        if path is None:
            mode = 0o040775
            data = b""
        else:
            mode = 0o100664
            data = path.read_bytes()
            file_count += 1
        name_bytes_len = len(name.encode("utf-8")) + 1
        out += header(name, mode, len(data), ino)
        if name_bytes_len % 2:
            out += b"\0"
        out += data
        if len(data) % 2:
            out += b"\0"

    trailer = TRAILER
    out += header(trailer, 0, 0, len(entries) + 1)
    if (len(trailer) + 1) % 2:
        out += b"\0"

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(out)
    return len(entries) + 1, file_count


def build(root: Path, output: Path) -> tuple[int, int]:
    """Build release.cpio from the install payload source tree."""
    return build_entries(collect(root), output)


def build_efi(root: Path, output: Path | None = None) -> tuple[int, int]:
    """Rebuild .efi/fuchas.efi2 from .efi/Source.

    The OEFI bundle uses the same old-binary CPIO format.  Keep the "." root
    directory entry that the original `find . | cpio -oHbin` build produced.
    """
    source = root / ".efi" / "Source"
    if not source.is_dir():
        raise SystemExit(f"missing EFI source directory: {source}")
    entries: list[tuple[str, Path | None]] = [(".", None)]
    for path in sorted(source.rglob("*"), key=lambda p: posix(p.relative_to(source))):
        if path.name in EXCLUDED_NAMES or path.name.endswith(EXCLUDED_SUFFIXES):
            continue
        entries.append((posix(path.relative_to(source)), None if path.is_dir() else path))
    output = output or (root / ".efi" / "fuchas.efi2")
    return build_entries(entries, output)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=repo_root)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--efi", action="store_true",
                        help="rebuild .efi/fuchas.efi2 from .efi/Source instead")
    args = parser.parse_args()

    root = args.root.resolve()
    if args.efi:
        output = (args.output or (root / ".efi" / "fuchas.efi2")).resolve()
        entries, files = build_efi(root, output)
    else:
        output = (args.output or (root / "release.cpio")).resolve()
        entries, files = build(root, output)
    print(f"wrote {output} ({output.stat().st_size} bytes, {entries} entries, {files} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
