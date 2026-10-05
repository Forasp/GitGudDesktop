GitGud Desktop is a Git client you can reshape. The engine is C++ over
libgit2; everything above it — layouts, skin, menus, shortcuts, whole
workflows — is XML and Lua that reloads while the app runs. No recompiling,
no restarting.

It ships with two interfaces similar to other popular revision control
software. The GitGud one has changes and history side by side, a commit
graph, undo, interactive rebase, and a merge tool. The Depot interface has
pending changelists, shelving, a revision graph, and separate diff windows.
Pick one on first launch and switch whenever you like.
Treat it as a starting point: move it around, re-theme it, strip it down, or
build something different on the same engine.

## Where to start

- **[Modding](Modding)**: how the interface is put together, the live edit
  loop, adding your own panels, menus, and commands.
- **[Lua API](Lua-API)**: every `gitgud.*` function and event scripts can use.
- **[Building](Building)**: set up the toolchain and build from source.
- **[Using the GitGud Interface](Using-the-GitGud-Interface)**: a tour of the interface
  GitGud ships with.
- **[Using the Depot UI](Using-the-Depot-UI)**: the changelist-based interface, and how
  its changelists and shelves map onto Git.
- **[Principles](Principles)**: the rules the code is built around.
