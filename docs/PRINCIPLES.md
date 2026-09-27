# Guiding principles

The rules the codebase is built around. When a change bends one of these,
it should be on purpose.

## 1. The engine doesn't know there's a UI

All Git work lives in C++ (`src/git/`, a RAII wrapper over libgit2) and is
UI-agnostic and unit-tested against throwaway repositories. It returns plain
data, throws `GitError`, and never leaks raw `git_*` pointers.

## 2. The UI is data; behaviour is script

- The widget tree is **XML** (`resources/layouts`), split into one file per
  region and stitched together with `<LayoutImport>`.
- The look is **XML** (`resources/looknfeel`, `resources/schemes`); every
  colour that matters is a widget property.
- All behaviour is **Lua** (`resources/scripts`): `main.lua` is an entry point
  that composes feature modules.

Changing how the app looks or behaves should never need a C++ rebuild, and
saving a layout or script reloads it live.

## 3. One narrow bridge

Lua reaches C++ only through the `gitgud` table (`src/lua/*Bindings.cpp`,
documented in `LUA_API.md`). Adding a capability means adding a binding, not
reaching around it. C++ talks back with events (`gitgud.on`). The same
contract (sync calls return `value` or `nil, message`; network calls report
`<op>.done` / `<op>.error`) holds everywhere.

## 4. Nothing blocks the UI thread

Network operations run on worker threads with their own repository handles
and report back through the thread-safe event bus. Everything else that runs
on the UI thread is kept cheap: lists are filled in one batch, refreshes are
coalesced, unchanged views aren't redrawn, and large diffs sit behind a
"show anyway" gate.

## 5. Idle costs nothing

The main loop renders on demand: it sleeps until input, a worker result, a
timer, or an animation needs a frame. A window you aren't touching uses
next to no CPU.

## 6. The index is the truth

What's included in the next commit is what's in Git's index — the checkboxes
and line toggles edit it directly. Close the app mid-way and the state is
still there for any other Git tool.

## 7. Never lose work silently

Discarding asks first (configurable) and sends new files to the Recycle Bin.
History-rewriting operations (reset, rebase, force push) explain what they
do before they do it. Operations that stop half-way (merge, rebase, revert,
cherry-pick) show a banner with the way forward and the way back. Anything
that moves branches is recorded for Undo, and undoing never overwrites
uncommitted work (branch moves use a safe checkout that refuses instead).
The interactive rebase builds its new history in memory first, so a failure
changes nothing. Signing or LFS failures fail the commit rather than
quietly committing unsigned or oversized content.

## 8. Any Git server, no account

GitGud speaks plain Git (HTTPS with credentials kept in the OS credential
store, SSH with your agent or key files, or local paths). There's
deliberately no GitHub sign-in. Where Git itself relies on other tools —
gpg / ssh-keygen for signing, git-lfs for large files — GitGud uses the same
tools and the same Git config, so the command line and GitGud agree.

## 9. Legible code

- C++: Hungarian naming and Allman braces, enforced by `.clang-tidy` /
  `.clang-format`.
- Lua: one declaration per line, no one-line `if … end`, a blank line between
  unrelated steps, and a header comment on every function.
