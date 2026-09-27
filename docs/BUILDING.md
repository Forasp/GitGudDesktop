# Building GitGud Desktop

Windows + Visual Studio is the tested setup.

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

## What setup does, by hand

Only needed if the script doesn't suit you. Work in a **Developer PowerShell
for VS** (its vcpkg sets `VCPKG_ROOT`; a plain shell can't configure) after
`git submodule update --init`.

CEGUI isn't in vcpkg; it's built from the `third_party/cegui` submodule,
**twice** — Debug and Release — because MSVC can't mix debug and release
runtimes across DLLs. First apply GitGud's patches (they fix CEGUI behaviour
GitGud depends on; see each file's header):

```powershell
git -C third_party/cegui apply ../patches/cegui/0001-itemview-scroll-without-relayout.patch
git -C third_party/cegui apply ../patches/cegui/0002-text-background-per-element.patch
```

Then configure, build, and install each configuration (repeat with
`Debug` / `build\cegui` / `third_party\cegui-install`):

```powershell
$tc = "$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
cmake -S third_party/cegui -B build/cegui-rel -G Ninja `
  "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" "-DCMAKE_BUILD_TYPE=Release" `
  "-DCMAKE_INSTALL_PREFIX=$PWD/third_party/cegui-install-release" `
  "-DCMAKE_TOOLCHAIN_FILE=$tc" "-DVCPKG_MANIFEST_DIR=$PWD/third_party/cegui-manifest" `
  "-DCEGUI_BUILD_RENDERER_OPENGL3=ON" "-DCEGUI_BUILD_RENDERER_OPENGL=OFF" `
  "-DCEGUI_BUILD_XMLPARSER_PUGIXML=ON" "-DCEGUI_BUILD_XMLPARSER_EXPAT=OFF" `
  "-DCEGUI_BUILD_IMAGECODEC_STB=ON" "-DCEGUI_BUILD_IMAGECODEC_SILLY=OFF" `
  "-DCEGUI_USE_FREETYPE=ON" "-DCEGUI_BUILD_SAMPLES=OFF" `
  "-DCEGUI_BUILD_APPLICATION_TEMPLATES=OFF" "-DCEGUI_BUILD_LUA_MODULE=OFF" `
  "-DCEGUI_STRING_CLASS=UTF-32"
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
cd C:\path\to\some\repo
D:\...\build\release\bin\gitgud.exe
```

GitGud opens the repository in its working directory (or none — add one
from the UI). Launched from a terminal it prints to that console;
`GITGUD_CONSOLE=1` forces a console window and `GITGUD_LOG=<file>` sends all
output to a file. A crash writes a symbolized stack trace to that output and
`gitgud-crash.dmp` next to the exe.

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
```

The package is a self-contained folder of about 21 MB: `gitgud.exe`, every
DLL (including the Visual C++ runtime, so no redistributable install is
needed), `resources/`, `docs/`, `cegui-datafiles/`, `BUILD-INFO.txt` (the
version and source commit), `LICENSE`, and `THIRD_PARTY_NOTICES.txt`.

`THIRD_PARTY_NOTICES.txt` holds the license of every third-party component
that ships. After adding or upgrading a dependency, regenerate it and commit
the result — packaging refuses to run while it's out of date:

```powershell
powershell -ExecutionPolicy Bypass -File tools\update-notices.ps1
```

It takes each vcpkg package's license from the build; where vcpkg only points
at the upstream file, the text lives in `tools/notices/<package>.txt`.

Before the smoke test, packaging checks that every DLL the binaries import is
in the package or part of Windows. The smoke test then starts a copy of the
package from an empty folder with a throwaway `%APPDATA%` and checks that it
came up on its own files. The result is zipped as
`build\dist\GitGud-win64.zip`, with one `GitGud\` folder inside.

## Releases

GitHub Actions (`.github/workflows/build.yml`) builds, runs the engine tests,
packages, and smoke-tests every push and pull request. The runners have no
GPU, so the smoke test borrows Mesa's software OpenGL (`-OpenGLRuntime`); those
DLLs go next to the test's copy of the app only, never into the package.

To release, set the version in `CMakeLists.txt` (`project(... VERSION x.y.z)`)
and `vcpkg.json`, commit, and push a tag:

```powershell
git tag v1.1
git push origin v1.1
```

The workflow then publishes a GitHub release for the tag with
`GitGud-win64.zip` attached. The latest one is always at
<https://github.com/Forasp/GitGudDesktop/releases/latest>.

## Tests

- **Engine (C++)** — Catch2, 69 cases: `build\release\bin\gitgud_tests.exe`
  (or `ctest --test-dir build/release`). The signing and LFS cases need
  `ssh-keygen` and `git-lfs` (Git for Windows ships both) and skip without.
- **UI (Lua, scripted)** — `tests/ui/*.lua` drive the real UI without
  touching your mouse or keyboard and save screenshots:

  ```powershell
  powershell -File tests\ui\make-testrepo.ps1 -Dir C:\temp\gg-test
  $env:GITGUD_SCRIPT = "$PWD\tests\ui\workflows.lua"   # or features / remotes / walkthrough / perf / mod-example
  $env:GITGUD_SHOTS  = "C:\temp\shots"
  $env:GITGUD_LOG    = "C:\temp\gg.log"
  Start-Process build\release\bin\gitgud.exe -WorkingDirectory C:\temp\gg-test
  ```

  Grep the log for `[check]`, `[perf]`, and `failed`. Always point these at a
  throwaway repository — they stage, commit, branch, and push. They also save
  settings, open tabs, and recent repositories to `%APPDATA%\Gitgud`; set
  `$env:APPDATA` to a scratch folder first to keep your own untouched.

## Documentation

`docs/` is the source for both the app's Help menu and the GitHub wiki.
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
- *CMake 4 rejects CEGUI's `cmake_minimum_required`* — keep
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` (quoted, in PowerShell).
- *Lua syntax check without running the app* — vcpkg's Lua has no `luac`;
  compile a tiny `luaL_loadfile` program against
  `build\release\vcpkg_installed\x64-windows\lib\lua.lib`.
