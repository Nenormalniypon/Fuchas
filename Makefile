PYTHON ?= python3

all: build

# The installer and Fuchas' CPIO library require the old binary 070707 format,
# so releases are built by tools/build_cpio.py rather than by luacomp or a
# system cpio.  This also keeps the payload human-readable Lua source.
build:
	$(PYTHON) tools/build_cpio.py

clean:
	rm -rf tmp

test: build
	$(PYTHON) tools/run_all_tests.py

.PHONY: all build clean test
