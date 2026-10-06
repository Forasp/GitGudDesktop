# Modding GitGud Desktop

The whole interface is files you can edit while the app runs: XML for the
widget tree and skin, Lua for behaviour. This guide covers where everything
lives, the dev loop, and how to add your own features.

| I want to… | Edit | Restart? |
|---|---|---|
| Move, resize, or recolour a widget | `resources/layouts/**.xml` | no — hot-reloads |
| Change what something does | `resources/scripts/**.lua` | no — hot-reloads |
| Add a feature (panel, menu, shortcut) | a new Lua module + XML file, one line in `main.lua` | no |
| Re-theme a widget type | `resources/looknfeel/*.xml` | yes (app restart) |
| Replace the whole interface | a UI package (see 9. Your own interface) | no |
| Add a Git capability Lua doesn't have | C++ (`src/git`, `src/lua`) | rebuild |

## 1. Where things live

```
resources/
  layouts/
    main.xml              the window: imports every region, in draw order
    main/                 title bar, toolbar, repository tabs, banner, branch
                          tree, sidebar, content, commit graph, console,
                          status bar
    sidebar/  content/    the regions' parts (Changes, History, diff, image
                          diff, merge tool, file history / blame…)
    popups/   dialogs/    dropdowns, the command palette, modal dialogs
                          (generic dialog, repository settings, interactive
                          rebase)
    mods/                 your layouts (example_stats.xml)
  scripts/
    main.lua              entry point: registers modules, starts the app
    core/                 app (modules + refresh), repo snapshot, settings,
                          status bar, keys, palette, text, shell helpers,
                          undo (Undo/Redo journal), worddiff
    ui/                   popup, menu, dialog, placeholder, geometry,
                          commands (the command palette)
    views/                one module per feature (changes, history, diff,
                          graph, navigator, tabs, mergetool, inspector,
                          rebase, console, ssh, lfs, …); frame.lua places
                          the big regions
    mods/                 your modules (example_stats.lua)
  looknfeel/              one skin file per widget family (Button.xml, …)
  schemes/Gitgud.xml      lists the skin files; maps "Gitgud/Button" etc.
  imagesets/              the icon atlas (regenerate with make-atlas.ps1)
  uis/                    other interfaces: depot/ (the Depot UI) and
                          picker/ (the chooser shown on first launch)
  ui.ini                  the GitGud UI's name and description
```

## 2. The dev loop

The running app watches the `resources/` copy next to `gitgud.exe`
(`build/release/bin/resources`). Edit there for instant feedback, or edit the
source tree and run `cmake --build --preset release` (it re-syncs resources
without recompiling). Saving any layout or script reloads the UI: the layout
is rebuilt and the Lua VM restarts from `main.lua`.

Errors show up in the console you launched the app from (or the
`GITGUD_LOG` file): `[lua] error in handler for 'X': file:line: message`
with a traceback, and `[CeguiBackend] layout '...' failed: ...`.

## 3. Layouts

A layout is a tree of `<Window type="..." name="...">` elements with
`<Property>` children. Every window's **name is its ID** in Lua
(`gitgud.setText("StatusLabel", …)`) and the prefix of its events
(`CommitButton.clicked`). Names are one global namespace — prefix yours.

Split big layouts into files and import them where the part belongs:

```xml
<Window type="DefaultWindow" name="MainArea">
    <LayoutImport filename="main/sidebar.xml"/>
</Window>
```

Each imported file needs exactly one root window. Later siblings draw on top
of earlier ones.

**Area** positions a window inside its parent: `{{scale,px},{scale,px},
{scale,px},{scale,px}}` for left, top, right, bottom, where scale is 0..1 of
the parent's size and px is added after. `{{0,12},{1,-40},{1,-12},{1,-8}}`
is "12 px from the left and right, a 32 px strip 8 px above the bottom".
From Lua, `ui/geometry.lua` builds these for you.

Widget types come from the scheme: `Gitgud/Label`, `Button`, `Editbox`,
`MultiLineEditbox`, `Checkbox`, `StaticText` (panels), `ListWidget`,
`ScrollablePane`, `Icon`, `Image`, `Glow`. Their properties (colours, fonts,
formatting) are listed at the top of each look in `resources/looknfeel`.

## 4. Lua: how the scripts are organised

`main.lua` only wires things up:

```lua
local app = require("core.app")
app.use(require("views.changes"))   -- … one line per feature …
app.use(require("mods.my_feature")) -- yours
app.start()
```

`require("a.b")` loads `resources/scripts/a/b.lua`. A **module** is a table
with any of these fields:

```lua
local M = { name = "my_feature" }
M.layout = "mods/my_feature.xml"  -- attached under M.parent (default "Root")
function M.init() end             -- once, after the layout is attached
function M.refresh(state) end     -- after every repository refresh
return M
```

`state` is the repository snapshot from `core/repo.lua` — `open`, `path`,
`name`, `branch`, `files`, `aheadBehind`, `operation`, `conflicts`,
`stashes`, `remotes`, `headOid` — so modules don't each re-query Git.
Anything that changes the repository should end with
`app.requestRefresh()`: requests in the same frame collapse into one
refresh. `app.publish` / `app.subscribe` pass signals between modules
(`tab.changed`, `diff.optionsChanged`, `stash.closed`, `sync.changed`,
`undo.changed`, `frame.changed`, `frame.graphChanged`, …).

**Where regions go** is decided in one place, `views/frame.lua`: bands above
the main area (`frame.setBand("tabs" | "notice", height)`), the branch tree,
graph mode, and the console. Don't set `MainArea`, `Sidebar`, or
`ContentPane` Areas yourself — ask frame, or it will put them back.

**Full-pane tools** over the diff (like the merge tool and blame) use
`content.openOverlay(panelName, onClose)` / `content.closeOverlay()`: one at
a time, Escape closes, and what was underneath repaints afterwards.

**Anything that moves branches** should go through
`undo.track(label, fn, opts)` (`core/undo.lua`) so Ctrl+Z can reverse it.

### The toolkit

| Module | Gives you |
|---|---|
| `ui/menu.lua` | `menu.addMenu(id, label)`, `menu.addItem(id, {label, shortcut, action, enabled, checked})`, `menu.popup(items, x, y)` for context menus, `menu.parseClick(value)` |
| `ui/dialog.lua` | `dialog.show{title, message, fields, checks, ok, onOk}`, `dialog.confirm`, `dialog.prompt`, `dialog.alert`, `dialog.showModal` / `hideModal` for your own modal windows |
| `ui/popup.lua` | `popup.open(name, {anchor, focus, onClose})` — dropdowns that close on click-away / Escape |
| `ui/placeholder.lua` | grey hint text in empty editboxes |
| `core/keys.lua` | `keys.bind("ctrl+alt+x", fn)` (menu items with a `shortcut` bind automatically), `keys.label(combo)` for showing one ("Ctrl+Alt+X", or "⌥⌘X" on macOS), `keys.text(s)` to show the shortcuts written in a text the macOS way, `keys.adaptTooltips(names)` for layout tooltips |
| `core/status.lua` | `status.ok / info / warn / error(msg)`, `status.report(okMsg, gitgud.call(...))` |
| `core/settings.lua` | `settings.get(key, default)` / `settings.set(key, value)`, persisted per user |
| `core/text.lua` | `text.colour(C.cyan, s)`, `text.escape`, `text.plural`, `text.ago`, path helpers |
| `core/palette.lua` | the colour tokens (`C.text`, `C.dim`, `C.cyan`, `C.add`, …) |
| `core/shell.lua` | `shell.openInEditor`, `openTerminal`, `showInFolder`, `copy` |
| `core/undo.lua` | `undo.track(label, fn, {soft, onUndo, onRedo})` — make an action undoable |
| `ui/commands.lua` | `commands.register{label, action, keywords, enabled, group}` — add to the command palette (menu items appear there automatically); `commands.addSource(function(add) … end)` for entries worked out each time it opens (branches, files) |
| `views/console.lua` | `console.run(commandLine, onDone)` — run a command in the console and get its exit code |

## 5. Adding a feature: the example mod

`scripts/mods/example_stats.lua` + `layouts/mods/example_stats.xml` add a
**Tools ▸ Repository statistics** panel. Enable it by uncommenting its line in
`main.lua`. The whole mod:

- **Layout** — a hidden panel (`StatsPanel`) with a title, a text body, and a
  Close button. The module sets `layout = "mods/example_stats.xml"`, so
  `app.start()` attaches it under `Root`.
- **Menu + shortcut** — in `init()`:
  ```lua
  menu.addMenu("tools", "Tools")
  menu.addItem("tools", {
      label = "Repository statistics",
      shortcut = "ctrl+alt+s",
      enabled = function() return repo.state().open end,
      action = show,
  })
  ```
- **Behaviour** — `show()` fills `StatsBody` from `gitgud.history`,
  `gitgud.branches`, and `gitgud.tags`, then opens the panel with
  `dialog.showModal("StatsPanel", hide)` (dimmed backdrop, Escape closes).
  `refresh(state)` repaints it while it's open.

Copy those two files to start your own.

### Common recipes

- **React to a widget**: `gitgud.on("MyButton.clicked", fn)`. Lists raise
  `selected` (0-based row), `clicked` / `rightClicked` (`"x,y,row"` — parse
  with `menu.parseClick`), and `doubleClicked`; editboxes raise `changed`
  and `accepted`; checkboxes raise `toggled` (`"1"`/`"0"`).
- **Add a context menu** to any widget: on `rightClicked`, call
  `menu.popup(items, x, y)`.
- **Ask the user something**: `dialog.prompt("Title", "Label", "", "OK",
  function(value) ... return true end)` — return `false, "message"` to keep
  it open with an error.
- **Build rows at runtime**: `gitgud.createWindow("Gitgud/Button", "MyRow1",
  "MyPanel")`, then `setProperty` / `setText`. For long lists prefer a
  `ListWidget` with markup rows — it stays fast with thousands of rows.
- **Do something periodically**: `gitgud.every(60000, fn)`;
  `gitgud.after(ms, fn)` for once.
- **Style text**: `text.colour(C.warn, "careful")`; list rows can include
  images (`[image='Gitgud-Images/Check']`) and `text.rowHeight(28)`.

## 6. Skinning

Each file in `resources/looknfeel` defines the look of one widget family
(`Button.xml`, `Lists.xml`, …) — its imagery sections, text areas, and the
**properties** layouts can set (`NormalFillColour`, `NormalTextColour`, …).
Change a property's `initialValue` to re-theme every widget of that type; set
the property on one widget in a layout to restyle just that one. To add a
widget type: add a `WidgetLook` in a looknfeel file, list the file in
`schemes/Gitgud.xml` if it's new, and add a `FalagardMapping`. Icons live in
`imagesets/Gitgud.png`, drawn by `make-atlas.ps1` and indexed by
`imagesets/Gitgud.xml`. **Skin changes need an app restart.**

## 7. Adding a Git capability (C++)

When Lua can't do something, add it to the engine and expose it:

1. `src/git/Repository.h` — declare the operation (plain types in and out,
   throw `GitError` on failure); implement it in the matching
   `src/git/Repository*.cpp`; add a Catch2 test in `tests/`.
2. `src/lua/LuaRepoBindings.cpp` — add an `L...` function (usually one line
   via `RepoAction` / `RepoQuery`) and register it in `AddRepoBindings`.
3. Document it in `docs/LUA_API.md`, rebuild, and call `gitgud.yourThing()`.

UI-only primitives follow the same pattern through `src/ui/IUiBackend.h`,
`src/ui/cegui/CeguiBackend.cpp`, and `src/lua/LuaUiBindings.cpp`.

## 8. Testing your changes

`tests/ui/*.lua` show how to drive the app from a script with
`gitgud.simulateClick`, `gitgud.simulateText`, `gitgud.emit`, and
`gitgud.screenshot` — see `docs/BUILDING.md` ▸ Tests. Point them at a
throwaway repository.

## 9. Your own interface

Mods extend the interface you have; a **UI package** replaces it. GitGud
ships two: the GitGud UI (`resources/` itself, id `default`) and the Depot UI
(`resources/uis/depot/`, see `docs/DEPOT.md`). Switch with **File ▸ Switch user
interface…** (GitGud UI) or **Edit ▸ Preferences ▸ Switch User
Interface…** (Depot UI); the first launch asks.

A package is a folder:

```
my-ui/
  ui.ini                 name=My UI
                         description=What it's for (shown in the picker)
  scripts/main.lua       the entry point, like resources/scripts/main.lua
  layouts/main.xml       the window's root layout (a "Root" window)
  looknfeel/*.xml        optional: skin overrides, loaded over the base skin
  imagesets/*.xml        optional: your own images (with resourceGroup="ui-imagesets")
```

Point GitGud at it from the picker's **Use an interface from a folder…**
(or `gitgud.switchUi("path:C:/src/my-ui")`); the choice is remembered. Put
it in `resources/uis/<id>/` to ship it as a built-in.

What a package gets for free:

- **The GitGud UI's Lua.** `require` searches your `scripts/` first, then
  `resources/scripts`, so `core/`, `ui/` (menus, dialogs, the command
  palette), and even `views/` modules are there to reuse — the Depot UI uses
  `views/sync.lua` for push/pull and sign-in, `views/repositories.lua` for
  clone/open. A file of your own with the same name wins: the Depot UI's
  `scripts/core/palette.lua` recolours every shared widget.
- **The GitGud UI's layouts.** Your `layouts/` is where layout files
  resolve; the GitGud UI's are resource group `gitgud-layouts`:
  ```xml
  <LayoutImport filename="dialogs/dialog.xml" resourceGroup="gitgud-layouts"/>
  ```
  The shared Lua needs a few of them: `popups/blocker.xml` (menus, popups),
  `dialogs/shade.xml` + `dialogs/dialog.xml` (dialogs), `popups/palette.xml`
  (the command palette), and a `MenuBar` window for `ui/menu.lua`. Copy one
  into your `layouts/` to restyle it — the Lua finds widgets by name.
- **A skin of its own.** A look in `looknfeel/` with the same name as a base
  look (`Gitgud/Button`, `Gitgud/ListView`, …) replaces it while your UI
  runs — colours, fonts, imagery — and the base comes back when you switch
  away. Fonts you can name in looks and layouts: `Gitgud-UI` (Inter),
  `Gitgud-UI-Bold`, `-Small`, `-Title`, `-Large`, `Gitgud-Mono` (JetBrains
  Mono), and the platform font `Gitgud-System` (Segoe UI), `-Bold`, `-Small`.
- **Pop-out windows.** `gitgud.openWindow{id, title, layout, width, height}`
  opens a real OS window showing a layout from your `layouts/`; its widgets
  are named `"<id>:<name>"` (so one layout can back several windows), and
  `window.closed` / `window.key` tell you when it closes and what it was
  typed at. The Depot UI's Diff, Revision Graph, Time-lapse, and Folder Diff
  windows are built this way (`scripts/depot/windows*`).
- **The window frame.** `gitgud.setWindowBordered(true)` gives the main
  window the OS title bar (the GitGud UI draws its own).

A minimal package:

```lua
-- my-ui/scripts/main.lua
local app = require("core.app")
require("core.keys").init()
require("ui.popup").init()
require("ui.dialog").init()

gitgud.setWindowBordered(true)
gitgud.on("HelloButton.clicked", function()
    require("ui.dialog").alert("Hello", "Branch: " .. gitgud.currentBranch())
end)
gitgud.on("SwitchButton.clicked", gitgud.showUiPicker)
app.start()
```

```xml
<!-- my-ui/layouts/main.xml -->
<GUILayout version="4">
    <Window type="DefaultWindow" name="Root">
        <Property name="Area" value="{{0,0},{0,0},{1,0},{1,0}}"/>
        <Window type="Gitgud/Button" name="HelloButton">
            <Property name="Area" value="{{0,20},{0,20},{0,180},{0,52}}"/>
            <Property name="Text" value="Hello"/>
        </Window>
        <Window type="Gitgud/Button" name="SwitchButton">
            <Property name="Area" value="{{0,190},{0,20},{0,370},{0,52}}"/>
            <Property name="Text" value="Switch interface…"/>
        </Window>
        <LayoutImport filename="popups/blocker.xml" resourceGroup="gitgud-layouts"/>
        <LayoutImport filename="dialogs/shade.xml" resourceGroup="gitgud-layouts"/>
        <LayoutImport filename="dialogs/dialog.xml" resourceGroup="gitgud-layouts"/>
    </Window>
</GUILayout>
```

Always give people a way back (`gitgud.showUiPicker()`); if the
remembered package is missing or incomplete at launch, GitGud starts the
picker instead. Everything hot-reloads as
usual; `looknfeel/` and `imagesets/` changes take a restart (or a switch
away and back).

## 10. Pitfalls

- **A misspelled widget name fails silently** — calls on unknown names are
  no-ops. Check the name first when something "doesn't update".
- **Escape repository text** with `text.escape` (or use `text.colour`):
  a literal `[` would be read as a markup tag.
- **Row numbers**: list events are 0-based (`selected`) or 1-based
  (`clicked`/`rightClicked` via `menu.parseClick`); `gitgud.selectListItem`
  and `getSelectedIndex` are 1-based.
- **Setting text from Lua doesn't raise `changed`** — use
  `placeholder.setText` for editboxes with a placeholder.
- **Hot reload restarts Lua from scratch**; keep state derivable from Git or
  store it with `core/settings.lua`.
- **Screenshots and UI changes are one frame apart** — in test scripts, don't
  change the UI in the same step that takes a screenshot.
- `Centre`, not `Center`, in alignment properties; `&amp;` for `&` in XML.
