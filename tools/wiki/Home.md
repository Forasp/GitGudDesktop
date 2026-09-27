GitGud Desktop is a Git client you can reshape. The engine is C++ over
libgit2; everything above it — layouts, skin, menus, shortcuts, whole
workflows — is XML and Lua that reloads while the app runs. No recompiling,
no restarting.

It ships with a complete interface in the spirit of GitHub Desktop, with
GitKraken-style extras (commit graph, undo, interactive rebase, merge tool).
Treat it as a starting point: move it around, re-theme it, strip it down, or
build something different on the same engine.

## Where to start

- **[Modding](Modding)** — how the interface is put together, the live edit
  loop, adding your own panels, menus, and commands.
- **[Lua API](Lua-API)** — every `gitgud.*` function and event scripts can use.
- **[Building](Building)** — set up the toolchain and build from source.
- **[Using the Default UI](Using-the-Default-UI)** — a tour of the interface
  GitGud ships with.
- **[Principles](Principles)** — the rules the code is built around.
