#!/bin/sh
# Rebuild the Fuchas release payload.
#
# The installer and Fuchas' own cpio library require the *old binary* CPIO
# format (magic 070707), not the default "newc" ASCII format used by modern
# cpio versions.  tools/build_cpio.py writes that format directly and is
# reproducible on Windows, Linux and macOS, so it is the canonical builder.
set -eu
cd "$(dirname "$0")"

# Rebuild the OEFI bundle from its sources, then pack the install payload.
python3 tools/build_cpio.py --efi
python3 tools/build_cpio.py
