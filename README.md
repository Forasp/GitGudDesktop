# GitGud Desktop

A GitHub Desktop-style Git client for **any** Git server — no account
required. The engine is C++17 over libgit2; the interface is CEGUI layouts
(XML) driven by Lua scripts, so the whole UI can be reshaped, re-themed, or
extended **without recompiling**, and it reloads live while you edit.

## What it does

- **Changes** — filterable file list with include checkboxes, line- and
  hunk-level staging in split or unified diffs, discard (to the Recycle
  Bin), ignore, commit with description and co-authors, amend, undo.
- **Image diffs** — before/after, a pixel-difference view, and onion skin.
- **History** — commits with branch/tag labels, per-commit files and diffs,
  filter, branch comparison; revert, cherry-pick, tag, branch-from, reset,
  checkout.
- **Branches** — switch (with stash-and-switch), create, rename, delete
  (locally and on the remote), merge, squash-merge, rebase, update from the
  default branch.
- **Conflicts** — banner with continue/abort, a 3-pane merge tool (mine,
  theirs, result — click the blocks you want, or edit the result), or
  mine/theirs / your editor.
- **Commit graph** — every branch as coloured lanes with branch/tag labels
  and a WIP row, as an optional view (Ctrl+3) next to Changes / History.
- **Branch tree** — branches, remotes, tags, stashes, submodules, and
  worktrees on the left; drag a branch onto another to merge or rebase.
- **Undo / redo** (Ctrl+Z) for commits, checkouts, merges, rebases, resets,
  and branch changes.
- **Command palette** (Ctrl+K) over every command, branch, repository, and
  changed file.
- **Interactive rebase** — reorder, reword, squash, fixup, drop; nothing
  changes until the new history is complete.
- **File history and blame**, **word-level diff** highlighting,
  **repository tabs**, and a **console** for anything else.
- **Stash**, **tags**, **sync** (fetch/pull/push/force push/publish,
  background fetch) over HTTPS or **SSH** (agent or key files, host
  trust prompts), **Git LFS**, **signed commits** (gpg or SSH),
  **submodules**, **worktrees**, **clone / create / add** repositories,
  repository settings, credentials in the OS store.
- Menus and keyboard shortcuts for everything, context menus, drag-and-drop.

See [docs/USAGE.md](docs/USAGE.md) for the tour.

## Get it

The latest Windows build is on the `dist` branch: a ready-to-run folder,
with no source and no history. Fetch just that:

```powershell
git clone --branch dist --single-branch --depth 1 <repository url> GitGud
GitGud\gitgud.exe
```

## Build

Needs Windows, Visual Studio 2022+ (C++ workload), and Git. One command sets
up everything: the dev environment, the CEGUI submodule with GitGud's
patches, the CEGUI build, and the app.

```powershell
.\setup.cmd            # or: .\setup.cmd -Preset full -Test
```

Day to day, `cmake --build --preset release`. `.\package.cmd -Publish`
refreshes the `dist` branch. Details: [docs/BUILDING.md](docs/BUILDING.md).

## Layout

```
src/
  git/        libgit2 wrapper: status, diffs, line staging, commits, branches,
              history, tags, stash, merge/rebase, network
  lua/        the Lua VM and the `gitgud` binding table
  ui/         IUiBackend (the UI seam) + the CEGUI backend
  imaging/    image decoding and pixel comparison for image diffs
  app/        event bus + worker threads
  platform/   credential store, shell integration, crash handler
  main.cpp    window, render-on-demand loop, hot reload
resources/
  layouts/    XML widget tree (main.xml imports the regions)
  scripts/    Lua behaviour (main.lua + core/, ui/, views/, mods/)
  looknfeel/  the skin, one XML file per widget family
  schemes/    Gitgud.xml — widget types and skin files
tests/        Catch2 engine tests; tests/ui scripted UI tests
docs/         building, principles, usage, modding, Lua API
```

## Docs

- [BUILDING](docs/BUILDING.md) — toolchain, CEGUI, presets, tests
- [PRINCIPLES](docs/PRINCIPLES.md) — the rules the code follows
- [USAGE](docs/USAGE.md) — using the app, shortcuts
- [MODDING](docs/MODDING.md) — layouts, skin, Lua modules, your own features
- [LUA_API](docs/LUA_API.md) — every `gitgud.*` function and event
