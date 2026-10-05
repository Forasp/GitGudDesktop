# Building GitGud Desktop

Windows + Visual Studio is the tested setup. Linux and macOS build too (see
[Linux](#linux) and [macOS](#macos)); they're newer and less tested.

## Quick start: `setup.cmd`

Needs Visual Studio 2022+ with "Desktop development with C++" (MSVC, CMake,
Ninja, and the bundled vcpkg) and Git. From any shell in the repository:

```powershell
.\setup.cmd                    # release build (CEGUI too, the first time)
.\setup.cmd -Preset full -Test # debug build, then run the engine tests
```

It finds Visual Studio and enters its developer environment, fetches the
CEGUI submodule, applies GitGud's CEGUI patches, builds and installs CEGUI
(once per configuration; later runs skip it until the submodule or a patch
changes), then configures and builds the app. Options: `-Preset
release|full|nogui`, `-AllConfigurations` (both CEGUI builds),
`-SkipApp`, `-Test`, `-Force` (rebuild CEGUI). Re-run it after pulling;
it only redoes what changed.

vcpkg installs SDL2, libgit2, Lua, stb, Catch2, and CEGUI's dependencies
(glm, glew, pugixml, freetype) automatically on first configure.

## Linux

`setup.sh` does what `setup.cmd` does. It needs a compiler, CMake, Ninja,
a vcpkg checkout in `VCPKG_ROOT`, and the development packages SDL2 builds
against (without them SDL2 silently drops X11 or Wayland support). On
Ubuntu 24.04:

```bash
sudo apt install build-essential cmake ninja-build pkg-config zip unzip \
    autoconf autoconf-archive automake libtool bison flex python3-venv \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev \
    libxinerama-dev libxss-dev libxxf86vm-dev libxkbcommon-dev \
    libwayland-dev wayland-protocols libdecor-0-dev libegl1-mesa-dev \
    libgl1-mesa-dev libglu1-mesa-dev libdbus-1-dev libibus-1.0-dev
git clone https://github.com/microsoft/vcpkg ~/vcpkg && ~/vcpkg/bootstrap-vcpkg.sh
export VCPKG_ROOT=~/vcpkg
./setup.sh                      # release build (CEGUI too, the first time)
./setup.sh --preset full --test # debug build, then run the engine tests
```

One Release CEGUI (`third_party/cegui-install-release`) serves every
preset, and the app finds its libraries through its RPATH. Settings live in
`$XDG_CONFIG_HOME/gitgud` (`~/.config/gitgud`). Optional desktop tools the
app uses when present: `xdg-open`, `gio` (trash), `zenity` or `kdialog`
(folder picker), and libsecret (saved passwords).

Under WSL, build inside the Linux file system (not `/mnt/c`), and drop the
Windows folders WSL appends to `PATH` (or set `appendWindowsPath = false`
in `/etc/wsl.conf`): CMake's package searches otherwise crawl over them.

### Linux packages: `package.sh`

```bash
sudo apt install rpm          # rpmbuild, for the .rpm (the .deb needs nothing extra)
./package.sh                  # or --skip-build after ./setup.sh
```

It builds the release preset, downloads the GitHub CLI release named by
`GH_VERSION` (checked against its published SHA-256) to bundle with the
app, and runs CPack: `build/dist/gitgud-desktop_<version>_amd64.deb` and
`gitgud-desktop-<version>-1.x86_64.rpm`. Both install the app to
`/usr/lib/gitgud` (CEGUI's libraries and modules in its `lib/`, gh in
`gh/`), link `/usr/bin/gitgud`, and add a menu entry and icons. Library
dependencies are worked out from the binaries; git, git-lfs, gnupg,
xdg-utils, libsecret and zenity are recommended (used when present).

The packages need at least the glibc they were built against, so build
them on the oldest distribution you support (Ubuntu 22.04 covers Debian 12,
Ubuntu 22.04+, and Fedora 36+). Linux builds don't update themselves: the
package manager does, and Help > Check for Updates says so.

## macOS

Apple Silicon (arm64), macOS 12 or later. `setup.sh` works as on Linux. It
needs the Xcode command-line tools (`xcode-select --install`), CMake, Ninja
and pkg-config (Homebrew: `brew install cmake ninja pkg-config`), and a vcpkg
checkout in `VCPKG_ROOT`:

```bash
git clone https://github.com/microsoft/vcpkg ~/vcpkg && ~/vcpkg/bootstrap-vcpkg.sh
export VCPKG_ROOT=~/vcpkg
./setup.sh --test               # release build and engine tests
open build/release/bin/gitgud.app
```

vcpkg builds for macOS 12 through the overlay triplet in `triplets/`
(`CMakePresets.json` and `setup.sh` point vcpkg at it). The build makes a
runnable app bundle, `build/release/bin/gitgud.app`: `resources/`, `docs/`
and `cegui-datafiles/` in `Contents/Resources` (hot-reload watches that
copy), CEGUI's libraries and modules in `Contents/Frameworks`. Settings live
in `~/Library/Application Support/Gitgud`, saved passwords in the login
Keychain (service "GitGud"). At startup the app takes `PATH` from the login
shell, so tools installed with Homebrew are found when it's opened from
Finder. Run another copy with `open -n build/release/bin/gitgud.app`.

The window uses the display's full resolution on Retina screens: the UI is
laid out in points, and text and the commit graph are drawn at two pixels
per point (CEGUI patch 0012). `GITGUD_PIXEL_RATIO=2` shows on any display,
on any platform, what a Retina screen would (at half size).

### macOS disk image: `package.sh`

```bash
./package.sh                  # or --skip-build after ./setup.sh
```

On macOS it makes `build/dist/GitGud-macOS-arm64.dmg` holding
`GitGud Desktop.app`: the built bundle plus gh (the `GH_VERSION` release,
checked against its published SHA-256) in `Contents/Resources/gh`. It
checks that every binary needs only the system and the bundle (`otool -L`)
and signs the app ad hoc. The app isn't notarized, so the first time
right-click it in Applications and choose Open. It doesn't update itself:
Help > Check for Updates points to the releases page.

## What setup does, by hand

Only needed if the script doesn't suit you. Work in a **Developer PowerShell
for VS** (its vcpkg sets `VCPKG_ROOT`; a plain shell can't configure) after
`git submodule update --init`.

CEGUI isn't in vcpkg; it's built from the `third_party/cegui` submodule,
**twice** (Debug and Release) because MSVC can't mix debug and release
runtimes across DLLs. First apply every patch in `third_party/patches/cegui`,
in name order (they fix CEGUI behaviour GitGud depends on; see each file's
header):

```powershell
Get-ChildItem third_party/patches/cegui/*.patch | Sort-Object Name |
  ForEach-Object { git -C third_party/cegui apply $_.FullName }
```

Then configure, build, and install each configuration (repeat with
`Debug` / `build\cegui` / `third_party\cegui-install`):

```powershell
$tc = "$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
cmake -S third_party/cegui -B build/cegui-rel -G Ninja `
  "-DCMAKE_BUILD_TYPE=Release" `
  "-DCMAKE_INSTALL_PREFIX=$PWD/third_party/cegui-install-release" `
  "-DCMAKE_TOOLCHAIN_FILE=$tc" "-DVCPKG_MANIFEST_DIR=$PWD/third_party/cegui-manifest" `
  <every option in $CeguiOptions in setup.ps1>
cmake --build build/cegui-rel
cmake --install build/cegui-rel
```

The installs (`third_party/cegui-install*`) are gitignored and machine-local.
CMake picks the one matching the build type. The patches leave the
submodule's working tree modified, but its recorded commit is unchanged, so
there's nothing to commit.
## Build the app

| Preset | What | Use it for |
|---|---|---|
| `release` | Optimized app + tests (RelWithDebInfo) | day-to-day use — much faster |
| `full` | Debug app + tests | stepping through C++ in a debugger |
| `nogui` | Engine + tests, no UI | headless engine work |

```powershell
cmake --preset release
cmake --build --preset release
```

Output lands in `build/<preset>/bin`. Every build mirrors `resources/` and
`docs/` next to the exe (even when no code changed).

## Run

```powershell
D:\...\build\release\bin\gitgud.exe                        # reopens the last repository
D:\...\build\release\bin\gitgud.exe C:\path\to\some\repo   # opens that one ("." works)
```

Without a path, GitGud reopens the repository you had open last. The first
launch opens none: it asks which interface to use, then you add a repository
from the UI. The first launch asks which interface to use (the default or
the Depot one); `GITGUD_UI=default`, `depot`, or `path:<folder>` picks
one for a run without asking. Launched from a terminal it prints to that console;
`GITGUD_CONSOLE=1` forces a console window and `GITGUD_LOG=<file>` sends all
output to a file. A crash writes a symbolized stack trace to that output and
`gitgud-crash.dmp` to `%APPDATA%\Gitgud\logs`, next to `CEGUI.log`. The app
never writes into its own folder, which is read only when it's installed
under Program Files.

**Hot reload:** the app watches the `resources/` copy next to the exe. Edit
layouts and scripts there (or edit the source tree and rebuild — the
resource sync is fast); saving reloads the UI in about a second. Skin files
(`looknfeel/`, `schemes/`) need a restart.

The build also copies the handful of stock CEGUI data files GitGud uses
(`imagesets/Vanilla`, the DejaVu font, `xml_schemas`) to
`bin/cegui-datafiles`. The app prefers that folder, so `bin` still works
when copied to another machine; the source tree's copy is only a fallback.

## Package a build: `package.cmd`

```powershell
.\package.cmd              # build, assemble build\dist\GitGud, smoke-test it, zip it
.\package.cmd -SkipBuild   # package the existing build\release\bin
.\package.cmd -Installer   # and fail if Inno Setup can't build the installer
```

The package is a self-contained folder of about 21 MB: `gitgud.exe`, every
DLL (including the Visual C++ runtime, so no redistributable install is
needed), `resources/`, `docs/`, `cegui-datafiles/`, `BUILD-INFO.txt` (the
version and source commit), `LICENSE`, and `THIRD_PARTY_NOTICES.txt`.

`THIRD_PARTY_NOTICES.txt` holds the license of every third-party component
that ships. After adding or upgrading a dependency, regenerate it and commit
the result: packaging refuses to run while it's out of date:

```powershell
powershell -ExecutionPolicy Bypass -File tools\update-notices.ps1
```

It takes each vcpkg package's license from the build; where vcpkg only points
at the upstream file, the text lives in `tools/notices/<package>.txt`.

Before the smoke test, packaging checks that every DLL the binaries import is
in the package or part of Windows. The smoke test then starts a copy of the
package from an empty folder with a throwaway `%APPDATA%` and checks that it
came up on its own files and wrote nothing into its own folder. The result is
zipped as `build\dist\GitGud-win64.zip`, with one `GitGud\` folder inside.

With [Inno Setup](https://jrsoftware.org/isinfo.php) 6 or later installed,
the folder also becomes `build\dist\GitGud-win64-setup.exe`, from
`installer\gitgud.iss` (without it, that step is skipped unless you pass
`-Installer`). The installer defaults to Program Files for all users, offers
a per-user install, lets you choose the folder, adds a Start menu shortcut
(a desktop one optionally), and can add the folder to `PATH` for
`gitgud .`. Uninstalling leaves `%APPDATA%\Gitgud` alone.

Last come the update files that installed copies patch themselves from:
`build\dist\GitGud-win64.pack` (every package file, deflated, back to back)
and `update-manifest.txt` (each file's hash and place in the pack). The
package itself carries `package-manifest.txt` (what that version installed)
and `gitgud-patcher.exe`, which swaps the files while GitGud is closed.

### Updates

`src/app/Updater.*` checks the latest release's `update-manifest.txt`,
downloads only the files whose hash differs (HTTP Range requests into the
pack), verifies each, and stages them in `%LOCALAPPDATA%\Gitgud\updates`.
At the next start, or on *Restart now*, `gitgud.exe` hands over to a copy of
`gitgud-patcher.exe` (`src/patcher/`), which waits for every copy of the app
to close, applies the files with a journal (rolled back on failure, or after
a crash at the next attempt), and restarts GitGud. `src/update/UpdateCore.*`
is shared by both and covered by `gitgud_tests "[update]"`.

The manifest is signed (ECDSA P-256). `tools\new-update-key.ps1 -PrivateKeyFile
<file outside the repo>` makes the key pair once: it writes the public key
into `src\update\UpdateKey.h` (commit that) and the private key to the file,
whose contents go into the GitHub Actions secret `GITGUD_UPDATE_SIGNING_KEY`.
`package.ps1` signs when that variable is set; release builds
(`-RequireSigned`, used for tags) fail without it. A build whose
`UpdateKey.h` is empty never installs updates.

To try the whole flow locally, package two versions with a test key
(`GITGUD_UPDATE_SIGNING_KEY` set, `-UpdatePackUrl GitGud-win64.pack`), then run
the older package with `GITGUD_UPDATE_URL` pointing at the newer
`build\dist` folder and `GITGUD_UPDATE_PUBLIC_KEY` set to the test public key
(base64 X||Y). `GITGUD_PATCHER_NO_UI=1` keeps the patcher from showing
dialogs. Use scratch `APPDATA` and `LOCALAPPDATA`.

## Releases

CI (`.github/workflows/build.yml`) builds, runs the engine tests,
packages, and smoke-tests every push and pull request. The runners have no
GPU, so the smoke test borrows Mesa's software OpenGL (`-OpenGLRuntime`); those
DLLs go next to the test's copy of the app only, never into the package.
Inno Setup comes from its GitHub release at a pinned version, checked
against a pinned SHA-256 (`INNO_VERSION` and `INNO_SHA256` in the workflow;
update both together). Each run keeps the zip, the installer, and the
update files as its `GitGud-win64` artifact for two weeks.

To release, set the version in `CMakeLists.txt` (`project(... VERSION x.y.z)`)
and `vcpkg.json`, commit, and push a tag:

```powershell
git tag v1.5.1
git push origin v1.5.1
```

The workflow then publishes a release for the tag with
`GitGud-win64.zip`, `GitGud-win64-setup.exe`, `GitGud-win64.pack`, and
`update-manifest.txt` attached; installed copies find the new version
through the last two. The latest one is always at
<https://github.com/Forasp/GitGudDesktop/releases/latest>.

## Tests

- **Engine (C++)**: Catch2, 97 cases: `build\release\bin\gitgud_tests.exe`
  (or `ctest --test-dir build/release`). The signing and LFS cases need
  `ssh-keygen` and `git-lfs` (Git for Windows ships both) and skip without.
- **UI (Lua, scripted)**: `tests/ui/*.lua` drive the real UI without
  touching your mouse or keyboard and save screenshots:

  ```powershell
  powershell -File tests\ui\make-testrepo.ps1 -Dir C:\temp\gg-test
  $env:GITGUD_SCRIPT = "$PWD\tests\ui\workflows.lua"   # or features / remotes / walkthrough / perf / mod-example
  $env:GITGUD_UI     = "default"                         # depot.lua needs "depot"
  $env:GITGUD_SHOTS  = "C:\temp\shots"
  $env:GITGUD_LOG    = "C:\temp\gg.log"
  Start-Process build\release\bin\gitgud.exe -ArgumentList C:\temp\gg-test
  ```

  `GITGUD_PERF=<ms>` also logs every main-loop pass, live-resize step, and
  Lua handler or timer slower than that, with the phase or source line.
  Grep the log for `[check]`, `[perf]`, and `failed`. Always point these at a
  throwaway repository — they stage, commit, branch, and push. They also save
  settings, open tabs, and recent repositories to `%APPDATA%\Gitgud`; set
  `$env:APPDATA` to a scratch folder first to keep your own untouched.
  On macOS run `tests/ui/make-testrepo.sh` and start
  `build/release/bin/gitgud.app/Contents/MacOS/gitgud <repo>` with the same
  variables and `HOME` set to a scratch folder. The Keychain isn't per
  `HOME`: scripts that can reach a sign-in must stub `gitgud.setCredential`
  (see `tests/ui/signin.lua`), and the engine's Keychain test uses its own
  service name ("GitGud tests") and deletes what it adds.
- **Perforce**: the `[p4][server]` engine cases and the `p4.lua` /
  `depot-p4.lua` UI scripts need `p4.exe` and `p4d.exe` from Perforce's
  downloads. Point `GITGUD_P4` and `GITGUD_TEST_P4D` at them, or the server
  cases skip. For the UI scripts, `tests\ui\make-p4workspace.ps1 -Dir
  C:\temp\gg-p4` makes a throwaway server and workspace and prints the
  environment to launch `gitgud.exe C:\temp\gg-p4\ws` with. See
  [Perforce workspaces ▸ Testing](P4.md#testing).

## Documentation

`docs/` is the source for both the app's Help menu and the project wiki.
Edit a doc there, then republish the wiki (the Home, sidebar, and footer
pages come from `tools/wiki/`):

```powershell
powershell -ExecutionPolicy Bypass -File tools\publish-wiki.ps1   # -DryRun to preview
```

## Troubleshooting

- *Configure can't find vcpkg* — use the Developer PowerShell (or set
  `VCPKG_ROOT` to Visual Studio's `VC\vcpkg`).
- *libgit2 target not found* — the vcpkg target is `libgit2::libgit2package`.
- *SSH remotes say "unsupported URL protocol"* — libgit2 must be built with
  the `ssh` feature (`vcpkg.json` asks for it; it pulls in libssh2 and
  OpenSSL, so the first configure after that change takes a while).
- *CEGUI wasn't found* — run `setup.cmd` with that preset (or build and
  install CEGUI for that build type by hand, above).
- *CMake 4 rejects CEGUI's `cmake_minimum_required`*: patch
  `0008-cmake-minimum-3.10.patch` isn't applied; apply every patch first.
- *Lua syntax check without running the app* — vcpkg's Lua has no `luac`;
  compile a tiny `luaL_loadfile` program against
  `build\release\vcpkg_installed\x64-windows\lib\lua.lib`.
