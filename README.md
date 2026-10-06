# GitGud Desktop

A Git and Perforce client you can reshape. The engine is native C++ over
libgit2 (and the `p4` command line for Perforce); the interface above it
(layouts, skin, menus, shortcuts, workflows) is XML and Lua that reloads
while the app runs, so you can restyle it, rearrange it, or build your own
features without recompiling. Works with any Git server; no account
required.

## Getting started

1. Download GitGud from the
   **[latest release](https://github.com/Forasp/GitGudDesktop/releases/latest)**:
   - **Windows** (64-bit): the
     **[installer](https://github.com/Forasp/GitGudDesktop/releases/latest/download/GitGud-win64-setup.exe)**,
     or the
     **[zip](https://github.com/Forasp/GitGudDesktop/releases/latest/download/GitGud-win64.zip)**
     to unzip anywhere and run `gitgud.exe` without installing.
   - **Linux** (x86-64): the `.deb` (Ubuntu 22.04 or later, Debian 12) or the
     `.rpm` (Fedora 36 or later); install it with `sudo apt install ./<file>`
     or `sudo dnf install ./<file>`.
   - **macOS** (Apple Silicon, macOS 12 or later): the `.dmg`. Drag GitGud
     Desktop into Applications; the first time, right-click it and choose
     **Open**, because the app isn't notarized.
2. Start GitGud and pick an interface (you can switch any time), then choose
   Git or Perforce for new repositories.
3. Add a repository: clone one, create one, or open a folder you already
   have. Next time, GitGud reopens the repository you had open.

Windows copies update themselves from **Help ▸ Check for Updates…**; on Linux
install the newer package, and on macOS replace the app with the one in the
new disk image. The **[Getting Started](https://github.com/Forasp/GitGudDesktop/wiki/Getting-Started)**
guide walks through each step with screenshots, including signing in to a
server. Older versions and release notes are on the
[releases page](https://github.com/Forasp/GitGudDesktop/releases).

## Two interfaces, or build your own

GitGud ships two interfaces and asks which one you'd like on first launch:

- **GitGud**: changes and history side by side, a commit graph, a branch
  tree, undo, interactive rebase, and a merge tool.
- **Depot**: pending changelists with shelving, submitted changelists, and
  revision graph, time-lapse, and diff windows.

![The GitGud interface behind the Depot interface](.github/images/ui-interfaces.png)

Both work on the same repositories and settings, and on Perforce workspaces
as well as Git repositories. Or build your own: see
[Modding](https://github.com/Forasp/GitGudDesktop/wiki/Modding).

## Documentation

Everything lives in the **[wiki](https://github.com/Forasp/GitGudDesktop/wiki)**.
Start with **[Getting Started](https://github.com/Forasp/GitGudDesktop/wiki/Getting-Started)**; it leads on to the
guide for the interface you pick. To change GitGud:
[Modding](https://github.com/Forasp/GitGudDesktop/wiki/Modding) · [Lua API](https://github.com/Forasp/GitGudDesktop/wiki/Lua-API) · [Building](https://github.com/Forasp/GitGudDesktop/wiki/Building) ·
[Principles](https://github.com/Forasp/GitGudDesktop/wiki/Principles)

## Build

Windows (Visual Studio 2022+ with the C++ workload) and Git:

```powershell
.\setup.cmd
```

Linux and macOS use `./setup.sh` the same way. It sets up the dev
environment, the CEGUI submodule and its build, and the app. See
[Building](https://github.com/Forasp/GitGudDesktop/wiki/Building) for
per-platform prerequisites, presets, tests, and packaging.

## Credits

Built on [libgit2](https://libgit2.org), [CEGUI](https://github.com/cegui/cegui),
[SDL](https://libsdl.org), [Lua](https://www.lua.org),
[OpenSSL](https://www.openssl.org), and [FreeType](https://freetype.org),
among others; the interface uses the [Inter](https://rsms.me/inter/) and
[JetBrains Mono](https://www.jetbrains.com/lp/mono/) fonts.
Portions of this software are copyright © The FreeType Project
(https://freetype.org). All rights reserved.

Every third-party component and its license is listed in
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt), which also ships with
each download.

## License

[MIT](LICENSE)
