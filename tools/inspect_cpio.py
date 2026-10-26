#!/usr/bin/env python3
"""Inspect an old-binary (070707) CPIO archive used by Fuchas.

Usage: python tools/inspect_cpio.py release.cpio
"""
import sys
import os

MAGIC = 0x71C7  # 070707 octal, little-endian on disk


def read_int(buf, pos, size):
    return int.from_bytes(buf[pos:pos + size], "little")


def parse(path):
    data = open(path, "rb").read()
    pos = 0
    entries = []
    while True:
        if pos + 26 > len(data):
            raise SystemExit("truncated header at %d" % pos)
        magic = read_int(data, pos, 2)
        if magic != MAGIC:
            raise SystemExit("bad magic %04x at %d" % (magic, pos))
        mode = read_int(data, pos + 6, 2)
        namesize = read_int(data, pos + 20, 2)
        # High word first, then low word (this is how old binary cpio stores
        # the 32-bit fields; both words are little-endian).
        filesize = (read_int(data, pos + 22, 2) << 16) | read_int(data, pos + 24, 2)
        name = data[pos + 26:pos + 26 + namesize - 1].decode("utf-8", "replace")
        # The name is padded to an even length; the file data follows the
        # padding, then the data itself is padded to an even length.
        body_start = pos + 26 + namesize + (namesize % 2)
        body = data[body_start:body_start + filesize]
        entries.append({
            "name": name,
            "mode": mode,
            "size": filesize,
            "body": body,
        })
        if name == "TRAILER!!!":
            break
        pos = body_start + filesize + (filesize % 2)
    return entries


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "release.cpio"
    entries = parse(path)
    print("archive: %s (%d bytes, %d entries)" % (path, os.path.getsize(path), len(entries)))
    total = 0
    for e in entries:
        kind = "dir " if (e["mode"] & 0o170000) == 0o040000 else "file"
        sig = ""
        if e["body"][:4] == b"\x1bLua":
            sig = " LUAC bytecode v%d" % e["body"][4]
        total += e["size"]
        print("%s %7d %s%s" % (kind, e["size"], e["name"], sig))
    print("payload: %d bytes" % total)


if __name__ == "__main__":
    main()
