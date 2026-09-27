# The `gitgud` Lua API

Scripts reach the app only through the global `gitgud` table. Conventions:

- **Sync calls** return a value (or `true`) on success, or `nil, "message"`.
  Report failures with `status.report(okMessage, gitgud.call(...))`.
- **Every successful change** to the repository publishes `status.changed`
  (the app refreshes on it).
- **Network calls** return at once and report `"<op>.started"`,
  `"<op>.done"` (detail = result text), or `"<op>.error"` (detail = message).
- **Indices are 1-based** (hunks, lines, stashes, list rows) unless noted.
- **Revisions** accept anything Git does: a branch, tag, OID, `HEAD~2`, ….

## Repository state

| Function | Returns |
|---|---|
| `isOpen()` | `true` when a repository is open |
| `repoPath()` | working-tree root (forward slashes), or `""` |
| `repoState()` | `"none"`, `"merge"`, `"rebase"`, `"cherrypick"`, `"revert"`, `"other"` |
| `status()` | `{ {path, staged, unstaged, code}, … }` — code `A` `M` `D` `?` (untracked) `U` (conflicted) |
| `diff(path, which, opts)` | `{path, oldPath, status, binary, hunks = { {header, oldStart, newStart, lines = { {origin, content, oldLineno, newLineno} } } }}`. `which`: `nil` = unstaged, `"staged"`, `"head"` = both (what the UI shows). `opts`: `{ignoreWhitespace, context}` |
| `aheadBehind()` | `{ahead, behind, hasUpstream, upstream, upstreamRemote}` for the current branch (`upstream` like `"origin/main"`) |
| `compareBranch(ref)` | `{ahead, behind}` of HEAD relative to `ref` |
| `currentBranch()` | branch name (works on an unborn branch); `""` when detached |
| `branches()` | `{ {name, isHead, isRemote, upstream, oid, time, ahead, behind}, … }` |
| `history(max)` / `history{max, skip, from, hide}` | newest first: `{ {oid, shortOid, summary, message, author, email, time, parents}, … }`. `from` = start revision (default HEAD); `hide` = exclude commits reachable from it |
| `commitDiff(oid, opts)` | array of diff tables (same shape as `diff`) vs the first parent, renames detected. `opts.path` limits it to one file |
| `refLabels()` | `{ {oid, name, kind}, … }` — kind `branch`, `remote`, `tag`, `head` |
| `tags()` | `{ {name, oid, message}, … }` (message empty for lightweight tags) |
| `remotes()` | `{ {name, url}, … }` |
| `stashList()` | `{ {index, message, oid}, … }` |
| `stashDiff(index)` | array of diff tables: tracked edits + untracked files |
| `conflicts()` | array of conflicted paths |
| `config(key)` | effective Git config value (repository, then global); `""` if unset |
| `globalConfig(key)` | value from `~/.gitconfig` (works with no repository) |
| `headOid()` | the commit HEAD points at, `""` on an unborn branch |
| `reflog(ref = "HEAD", max = 50)` | newest first: `{ {old, new, message, committer, time}, … }` |
| `fileLog(path, max = 300)` | commits (newest first, same shape as `history`) whose change touched `path` |
| `blame(path, revision = "workdir")` | `{lines = {…}, hunks = { {oid, shortOid, summary, author, time, start, count, uncommitted}, … }}` — `start` is a 1-based line; `"workdir"` blames the file on disk (unsaved lines are `uncommitted`), else any revision (`"<oid>^"` works) |
| `readConflict(path)` | a conflicted file for the merge tool: `{path, binary, oursDeleted, theirsDeleted, trailingNewline, chunks = { {conflict, lines, ours, theirs, base}, … }}` — agreed text in `lines`, contested text in `ours` / `theirs` (`base` = common ancestor). Resolve by writing the result (`writeRepoFile`) and `stage`-ing it |
| `submodules()` | `{ {name, path, url, headOid, workdirOid, initialized, modified, dirty}, … }` |
| `worktrees()` | `{ {name, path, branch, locked, valid, main}, … }` — the main working tree first |
| `lfsAvailable()` | `true` when git-lfs was found (LFS files are then cleaned / smudged through it) |
| `listTree(revision = "HEAD", dir = "")` | a folder's entries in a revision: `{ {name, path, isDir, isSubmodule, oid, size}, … }`, folders first |
| `fileAt(path, revision)` | the file's bytes in that version (`"workdir"`, `"index"`, `"head"`, any commit-ish, `"<oid>^"`), or `nil` when it doesn't exist there |
| `diffVersions(oldPath, oldRevision, newPath, newRevision, opts)` | a diff table (as `diff`) between any two versions of a file; a missing side diffs as an add or delete. `opts`: `{ignoreWhitespace, context}` (a huge `context` gives the whole file) |
| `changedFiles(oldRevision, newRevision, prefix = "")` | `{ {path, oldPath, status}, … }` — which files differ (renames detected). `newRevision` may be `"workdir"` (untracked files included), `oldRevision` `""` (nothing) |
| `revisionGraph{path, remotes = true, exclude = {branches}, max = 300, selected, columnWidth, rowHeight, nodeWidth, nodeHeight, nodeTop, image, colours}` | a file's history across branches, drawn as a revision graph and published as image `image` (default `"GitgudRevisionGraph"`). Returns `{image, width, height, columnWidth, rows = { {name, head, remote, x, y, w, h} }, nodes = { history row + {row, column, revision, action, x, y, w, h} }, edges = { {from, to, merge} } }` — `action` is `A` `M` `D` or `I` (merged in); positions are pixels in the picture, for your labels and click targets. `colours`: `{background, bandA, bandB, bandSelected, rowLine, node, nodeHead, nodeBorder, deleted, bar, edge, branchEdge, selectedFill, selectedBorder}` (hex) |

## Staging and commits

| Function | Effect |
|---|---|
| `stage(path \| {paths})` / `unstage(path \| {paths})` | include / exclude whole files |
| `stagedLines(path)` | indices (into the flattened lines of `diff(path, "head")`) currently in the index |
| `setStagedLines(path, {indices}, lineCount)` | make exactly those lines staged; `lineCount` = total lines in that diff (a mismatch fails instead of staging the wrong lines) |
| `discardLines(path, {indices}, lineCount)` | revert those lines in the working tree and index |
| `stageHunk(path, i)` / `unstageHunk(path, i)` | older hunk API (indices into the unstaged / staged diff) |
| `discard(path \| {paths})` | throw away all changes; new files go to the Recycle Bin |
| `ignore(pattern)` | append to `.gitignore` |
| `commit(message)` | commit the index; returns the OID (creates the merge commit during a merge) |
| `amend(message)` | replace the last commit (keeps its author); returns the OID |
| `undoCommit()` | soft-reset the last commit; returns its message |
| `revert(oid)` / `cherryPick(oid)` | returns the new OID, or `""` when it stopped on conflicts |
| `resetTo(oid, "soft" \| "mixed" \| "hard")` | move the current branch |
| `setBranchTarget(branch, oid)` | point a local branch at `oid` (creating it if needed); the checked-out branch moves its working tree with a *safe* checkout, which refuses rather than overwrite local edits. The building block of Undo |
| `rebaseTodo(base)` | the commits an interactive rebase onto `base` would rewrite (first-parent line, oldest first); fails on merge commits |
| `interactiveRebase(base, steps)` | `steps` = `{ {action, oid, message}, … }`, oldest first, exactly the `rebaseTodo` commits in any order; `action` = `pick`, `reword`, `squash`, `fixup`, `drop`. Builds the new commits in memory first: returns `{kind, message, conflicts}` with kind `done`, `uptodate`, or `conflicts` (nothing changed) |

Commits (including amend, merge, revert, cherry-pick, and both rebases) are
signed when Git's config says so: `commit.gpgsign = true`, with `gpg.format`
`openpgp` (gpg) or `ssh` (ssh-keygen) and `user.signingkey`. A signing failure
fails the commit with the tool's message.

## Branches, tags, merging

| Function | Effect |
|---|---|
| `createBranch(name, start?)` | from HEAD or any revision |
| `checkout(name)` | switch (a remote branch creates a local tracking branch) |
| `checkoutCommit(oid)` | detached HEAD |
| `renameBranch(old, new)` / `deleteBranch(name)` | local branches |
| `createTag(name, target?, message?)` / `deleteTag(name)` | annotated when a message is given |
| `merge(branch)` / `squashMerge(branch)` | `{kind, message, conflicts}` — kind `uptodate`, `fastforward`, `merged`, `conflicts` |
| `rebase(branch)` / `continueRebase()` | `{kind, message, conflicts}` — kind `uptodate`, `done`, `conflicts` |
| `resolveConflict(path, "ours" \| "theirs")` | take one side and stage it |
| `abortOperation()` | abort a merge / rebase / cherry-pick / revert |
| `abortMerge()` | hard-reset to HEAD and clear merge state |
| `addRemote(name, url)` / `removeRemote(name)` | removing also drops its remote branches and the upstreams that pointed at it |
| `setRemoteUrl(name, url)` / `renameRemote(name, newName)` | both keep its branches and the upstreams that track it |
| `setUpstream(branch, "remote/branch")` | make a local branch track a remote branch; `""` or nil stops tracking |
| `setConfig(key, value)` / `setGlobalConfig(key, value)` | empty value removes the key |
| `stashSave(message?)` / `stashApply(i)` / `stashPop(i)` / `stashDrop(i)` | untracked files included |
| `shelve(branch, {paths}, message)` | commit the working-tree versions of `paths` on top of HEAD onto local branch `branch` (created or moved) and return the commit id — HEAD, the index, and the files don't change. The Depot UI's shelves |
| `unshelve(revision, {paths}?)` | bring a shelf commit's changes (vs its parent) into the working tree: untouched files take the shelved version, edited ones get a three-way merge. Returns `{applied, conflicted, skipped}` (path arrays; `conflicted` files have conflict markers) |

## Network (asynchronous)

| Function | Events |
|---|---|
| `fetch(remote)` | `fetch.*` |
| `fetchAll()` | `fetch.*` — every remote; `error` names the ones that failed (the rest are still fetched) |
| `pull(remote)` | `pull.*` — merges the upstream when it lives on `remote`, else `remote/<branch>`; `done` detail is `"kind\|message"` (kind as for `merge`) |
| `push(remote, {force = bool, setUpstream = bool})` | `push.*` — goes to the upstream branch when it lives on `remote` (else the same name); sets the upstream on first push, or always with `setUpstream` |
| `pushTags(remote)` | `pushTags.*` |
| `deleteRemoteBranch(remote, branch)` | `deleteRemoteBranch.*` |
| `pushBranch(remote, branch, {force, as})` | `pushBranch.*` — push any local branch (checked out or not) to `as` (default: the same name) without setting an upstream; `done` detail is `"branch|remote"` |
| `updateSubmodule(name, init = true)` | `updateSubmodule.*` — clone (if `init`) and check out the recorded commit |
| `clone(url, path)` | `clone.*` — `done` detail is the path |

Credentials: `setCredential(host, user, pass)`, `hasCredential(host)`,
`eraseCredential(host)`, `hostForRemote(remote)`. When a server needs
credentials that aren't stored, `credential.missing` fires with the host.
When it refuses the saved ones, they're erased and `credential.rejected`
fires with the host. For github.com, `views/github.lua` signs in through
the browser with the GitHub CLI.

SSH remotes use your SSH agent first, then `~/.ssh/id_ed25519`, `id_ecdsa`,
`id_rsa`. An encrypted key's passphrase is looked up (and asked for, via
`credential.missing` with detail `"ssh-key:<key path>"`) like a password:
store it with `setCredential("ssh-key:<key path>", "ssh", passphrase)`. A
server whose host key isn't in `~/.ssh/known_hosts` fires `ssh.unknownHost`
with detail `"host\nfingerprint\nknown_hosts line"`; `trustHostKey(line)`
appends the line, and the retry connects. A host key that *changed* is
refused outright. `sshKeys()` lists `~/.ssh/*.pub` as `{ {name, path,
publicKey, hasPrivate}, … }`.

## Repository lifecycle

`openRepo(path)`, `initRepo(path)`, `closeRepo()` — handled by the app, which
then fires `repo.changed` (detail = path, `""` when closed) or `repo.error`.

Worktrees: `addWorktree(name, path, branch?)` (the branch is created from
HEAD when missing), `removeWorktree(name)` (refuses when it has uncommitted
changes; deletes its folder).

## Commit graph

`graph{max = 400, remotes = true, tags = true, wip = false, laneWidth = 16,
rowHeight = 28, maxLanes = 12, colours = {"AARRGGBB", …}, background,
headRing, prefix = "GitgudGraph"}` walks every branch (plus remote branches
and tags if asked), lays the commits out in lanes, and draws one picture per
row, published as image `"<prefix>/<row>"`. Returns `{width, lanes, rows}`;
each row is a `history` row plus `lane`, `colour` (1-based indices), `image`,
`merge`, `head`. With `wip = true` the first row is `{wip = true}`: a hollow
dot above HEAD for uncommitted changes. Show a row's picture inline:
`"[image-size='w:<width> h:<rowHeight>'][image='" .. row.image .. "']"`.

## Widgets

| Function | |
|---|---|
| `setText(name, markup)` / `getText(name)` | text supports CEGUI markup: `[colour='AARRGGBB']`, `[font='Gitgud-UI-Bold']`, `[image='Set/Name']`, `[image-size='w:16 h:16']`, `[vert-formatting='CentreAligned']`; escape literal `[` |
| `setList(name, {rows})` | replace a list's rows (keeps the scroll position) |
| `setListItem(name, i, markup)` | replace one row |
| `selectListItem(name, i \| nil, scrollIntoView = true)` | select without raising `selected` |
| `getSelectedIndex(name)` | 1-based, or `nil` |
| `getSelectedIndices(name)` / `selectListItems(name, {rows})` | every selected row (1-based) of a list with the `MultiSelect` property (Ctrl+click adds, Shift+click extends); select exactly these rows |
| `getScroll(name, "horizontal"?)` / `setScroll(name, px, "horizontal"?)` | vertical (or horizontal) scroll of a list or pane |
| `setDraggable(name, on = true)` | the widget raises `dragStarted`, `dragging`, `dragEnded` (`"x,y"`) while dragged with the left button — splitters, column dividers |
| `setVisible` / `setEnabled` / `setChecked(name, bool)` | `setChecked` doesn't raise `toggled` |
| `setProperty(name, prop, value)` / `getProperty(name, prop)` | any widget property |
| `getRect(name)` | `x, y, width, height` on screen, or `nil` |
| `focus(name)` / `bringToFront(name)` | |
| `createWindow(type, name, parent)` / `destroyWindow(name)` | runtime widgets (raise events like layout widgets) |
| `loadLayout(file, parent = "Root")` | attach a layout file (relative to the running UI's `layouts/`; `resources/layouts` for the default UI) |
| `suspendLayout(name, bool)` | pause/resume child layout around bulk changes |
| `linkScroll(listA, listB)` | keep two lists scrolled together |
| `isImage(path)` | true for image file types |
| `textInputFocused()` | `true` while an editbox has keyboard focus (so shortcuts like Ctrl+Z leave typing alone) |
| `imageDiff(path, beforeRev, afterRev)` | decode both versions (`"workdir"`, `"index"`, `"head"`, `"<oid>"`, `"<oid>^"`) and publish images `GitgudDiff/Before`, `/After`, `/Difference`, `/Onion`; returns `{width, height, beforeWidth, beforeHeight, afterWidth, afterHeight, hasBefore, hasAfter, changed, total}` |

### Widget events

`gitgud.on("<Widget>.<action>", function(value) … end)`:

| Action | Raised by | `value` |
|---|---|---|
| `clicked` | buttons | `""` |
| `clicked` | lists | `"x,y,row"` (row 0-based, `-1` = none) |
| `rightClicked` | any widget | `"x,y,row"` (row `-1` outside lists) |
| `doubleClicked` | any widget | row (lists) or `"-1"` |
| `toggled` | checkboxes | `"1"` / `"0"` |
| `selected` | lists | row, 0-based (`-1` = cleared) |
| `changed` | editboxes | the new text (not raised for `setText`) |
| `accepted` | single-line editboxes | `""` (Enter) |
| `dragged` | lists | `"fromRow,toRow"` (0-based) — pressed on one row, released on another |
| `dragStarted` / `dragging` / `dragEnded` | widgets made draggable with `setDraggable` | `"x,y"` — the cursor, in window pixels |

## Events, timers, shell

| Function | |
|---|---|
| `on(event, fn)` | subscribe (widget or app events) |
| `emit(event, detail)` | publish an event (delivered in the same frame) |
| `after(ms, fn)` / `every(ms, fn)` → id | timers; `cancelTimer(id)` |
| `now()` | milliseconds, monotonic |
| `openExternal(path)` / `showInFolder(path)` | default app / Explorer |
| `spawn(commandLine, cwd?)` | start a program |
| `pickFolder(title)` | folder picker; `nil` if cancelled |
| `setClipboard(text)` | |
| `pathExists(path)` | |
| `readRepoFile(rel)` / `writeRepoFile(rel, text)` | files inside the open repository only |
| `trashRepoFile(rel)` | move a file inside the open repository to the Recycle Bin |
| `configRead(name)` / `configWrite(name, text)` | per-user files in `%APPDATA%\Gitgud` |
| `docs()` | `{ {name, path}, … }` for the shipped docs folder |
| `findProgram(name)` | full path of a program on PATH (or bundled with Git for Windows), or `nil` |
| `runProgram({program, args…}, cwd?, stdin?)` | run to completion: `{code, output, error}`, or `nil, msg` if it can't start. Blocks — quick tools only |
| `runCommand(commandLine, cwd = repo)` | run through the shell on a worker (one at a time): output streams as `console.output` events, `console.done` carries the exit code |
| `cancelCommand()` / `commandRunning()` | stop the running command (and its children) / is one running |
| `startProgram(name, {program, args…}, cwd?)` | run without a shell or stdin on a worker: output streams as `<name>.output`, `<name>.done` carries the exit code (-1 if it couldn't start or was stopped); `true` or `nil, msg` |
| `stopProgram(name)` | stop that program and its children; `true` if it was running |
| `httpGet(name, url)` | HTTPS GET on a worker: `<name>.done` carries the body, `<name>.error` the reason |
| `installTool(name, {url, sha256, tool, version})` | download a .zip, check its SHA-256, unpack it into `<app data>/tools/<tool>/<version>` and remove older versions; `<name>.done` carries the folder |
| `installedTools(tool)` | `{ {version, dir}, … }` installed by `installTool` |
| `homeDir()` | the user's home folder |
| `version` | app version string |

### App events

`app.started` (detail `"hot-reload"` after a reload), `app.focusGained`,
`app.fileDropped` (path), `key` (combo, e.g. `"ctrl+shift+p"`, also plain
`"up"`, `"down"`, `"pageup"`, `"pagedown"` — see `core/keys.lua`),
`status.changed`, `repo.changed`, `repo.error`, `credential.missing`,
`credential.rejected`,
`ssh.unknownHost`, `console.output` / `console.done`, `window.state`
(`"maximized"` / `"restored"`),
`window.resized` (`"WxH"`), plus the network events above. Scripts can ask
the window to `window.minimize`, `window.toggleMaximize`, `window.close`.
Pop-out windows add `window.closed` (id), `window.key` (`"id|combo"` — a
pop-out's shortcuts don't reach `key`), `window.focused` (id), and
`window.popOutResized` (`"id|WxH"`).

## Windows and interfaces

| Function | |
|---|---|
| `openWindow{id, title, layout, width, height, minWidth, minHeight}` | open a separate OS window showing `layout` (from the UI's `layouts/`); its widgets are named `"<id>:<name>"`. An id that's open is raised. `true` or `nil, msg` |
| `closeWindow(id)` / `focusWindow(id)` / `setWindowTitle(id, title)` | `""` as the id is the main window (for `setWindowTitle`) |
| `windows()` | the open pop-out ids |
| `setWindowBordered(bool)` | the main window's OS frame on (native title bar) or off (the UI draws its own) |
| `currentUi()` | the running interface: `{id, name, description, root, builtIn}` — id `"default"`, a built-in's folder name, or `"path:<folder>"` |
| `uiList()` | the interfaces to choose from (same shape), the default first |
| `switchUi(id, remember = true)` | switch after the current handler returns (every window's widgets and the Lua VM start over); `remember` makes it the one GitGud starts with. `nil, msg` for a folder that isn't a UI package |
| `showUiPicker()` / `previousUi()` | run the interface picker (not remembered); the interface that was running before |
| `firstLaunch()` | `true` until an interface has been chosen |

See `docs/MODDING.md` ▸ "Your own interface" for UI packages.

## Updates

Used by `views/updates.lua` (Help ▸ Check for Updates…).

| Function | |
|---|---|
| `updateInfo()` | `{current, packaged, staged, downloading, otherCopies}`: this version; whether it's a release build (only those update); the downloaded version waiting to be installed (`""` if none); a download is running; other copies open from this folder |
| `updateCheck()` | check in the background: `update.check.done` with tab-separated `"none\t<latest>"` or `"available\t<version>\t<notes url>\t<bytes>\t<files>"`, or `update.check.error` |
| `updateDownload()` | download the changed files in the background: `update.progress` (`"<done> <total>"` bytes), then `update.download.done` (the version) or `update.download.error` (`"cancelled"` after `updateCancel()`) |
| `updateCancel()` / `updateDiscard()` | stop a download / throw away a downloaded update |
| `updateRestart()` | install now: `true` (then quit, e.g. `emit("window.close", "")`) or `nil, msg, otherCopies` when other copies are open |
| `updateReport()` | once after an update was installed or failed: `"ok <version>"` or `"failed <message>"`, plus `"edited <folder>"` when edited files were saved; else `nil` |

## Test harness

`simulateClick(x, y, "left" | "right" | "double", window?)`,
`simulateText(text, window?)`, `simulateScroll(x, y, delta, window?)` (mouse
wheel; positive scrolls up), and `screenshot(path, window?)` (PNG of the next
frame) drive the UI — or pop-out `window` — from a script run via
`GITGUD_SCRIPT` — see `docs/BUILDING.md` ▸ Tests.
