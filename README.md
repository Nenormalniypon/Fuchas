# Fuchas

Fuchas is an Operating System with multi-tasking, security and multi-user with UAC features. It is an OS made in Lua that can run on the [OpenComputers mod](https://github.com/MightyPirates/OpenComputers).

The project is active and continueously updated. You can find update announcements at [the forum post](https://oc.cil.li/topic/1852-fuchas/) or look at the `CHANGELOG`.

Default admin user (if cloning from github):
Username: `admin`
Password: `admin`

## Features
Here are the features it have compared to OpenOS:
- Driver system
- One network API to rule them all
- Included CPIO and VELX writer and parser.
- IPC
- UAC with SHA3-512 passwords
- Permission system
- OCX (drawing and UI library)
- Built-in documentation (not complete yet)
- Extensions to Lua API, like string.startsWith, string.split or string.toByteArray
- More compatibility with Lua specification's API (like availability of io.popen)
- Protected component system, unless a process is admin (= root), it must use drivers
- SJF processs scheduler

One big feature it also have is Stardust, which allows it to run most OpenOS programs.

## Install
Fuchas requires OpenComputers running Lua 5.3 (or the experimental Lua 5.4
architecture). The installer refuses to run on Lua 5.2.

### From OpenOS (most OC computers)
1. Launch the computer
2. Download and run the bootstrap installer:
   ```
   wget -f https://raw.githubusercontent.com/Nenormalniypon/Fuchas/main/Installers/bootstrap.lua /tmp/fuchas-bootstrap.lua
   lua /tmp/fuchas-bootstrap.lua
   ```
3. Follow the installer steps (choose dual boot or erase, then set the admin password).

You can also run the installer directly:

```
wget -f https://raw.githubusercontent.com/Nenormalniypon/Fuchas/main/Installers/openos.lua /tmp/fuchas-install.lua
lua /tmp/fuchas-install.lua
```

The installer downloads `release.cpio` from GitHub, with jsDelivr and
raw.githack as mirrors. If the computer has no internet card, copy
`release.cpio` onto the computer as `fuchas.cpio` in the current directory (or
set `FUCHAS_CPIO` to its path) and run the installer again; the local archive
is validated and used automatically.

### From MineOS
1. Launch the computer
2. On the App Market, make a search for `Fuchas Installer`
3. Click `Install` to install the installer
4. Launch `Fuchas Installer` from your desktop
5. Click `Install`. Or click `Install (UNSAFE)` if you want the latest features.
6. You can see the changelog, again, click `Install` to install Fuchas.
7. Reboot your computer

## Development
`release.cpio` is the install payload and uses the old binary CPIO format
(`070707`) that the installer and Fuchas' own CPIO library expect. Rebuild it
from the source tree with:

```
python tools/build_cpio.py
```

Run the full test suite (offline, on both Lua 5.3 and Lua 5.4) with:

```
python tools/run_all_tests.py
```

The tests use [lupa](https://pypi.org/project/lupa/) from `.tools/py2.5` to run
the real installer, the kernel boot chain, the MineOS extractor, Fuchas' own
upgrade command and Stardust's terminal on mocked
OpenComputers/OpenOS/MineOS APIs.

