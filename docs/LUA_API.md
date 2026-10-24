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
| `checkout(name)` | switch (a remote branch creates a local tracking branch). When uncommitted changes would be overwritten it changes nothing and returns `nil, message, paths` (the files in the way) |
| `checkoutCommit(oid)` | detached HEAD; `nil, message, paths` as for `checkout` |
| `renameBranch(old, new)` / `deleteBranch(name)` | local branches |
| `createTag(name, target?, message?)` / `deleteTag(name)` | annotated when a message is given |
| `merge(branch)` / `squashMerge(branch)` | `{kind, message, conflicts}`, kind `uptodate`, `fastforward`, `merged`, `conflicts`; `nil, message, paths` as for `checkout` |
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
| `pull(remote)` | `pull.*`: merges the upstream when it lives on `remote`, else `remote/<branch>`; `done` detail is `"kind\|message"` (kind as for `merge`), or `"blocked\|"` and the paths in the way, one per line, when uncommitted changes stopped the merge (the fetch still happened) |
| `push(remote, {force = bool, setUpstream = bool})` | `push.*` — goes to the upstream branch when it lives on `remote` (else the same name); sets the upstream on first push, or always with `setUpstream` |
| `pushTags(remote)` | `pushTags.*` |
| `deleteRemoteBranch(remote, branch)` | `deleteRemoteBranch.*` |
| `pushBranch(remote, branch, {force, as})` | `pushBranch.*` — push any local branch (checked out or not) to `as` (default: the same name) without setting an upstream; `done` detail is `"branch|remote"` |
| `folderSummary(name, folder)` | `<name>.*`: the Git repository holding any folder (not only the open one), read on a worker: `done` carries JSON text `{root, commonDir, branch, head, worktree, files, added, removed, remotes = { {name, url} }}`: its working tree's root, the shared `.git` folder, the branch (`""` when detached), HEAD's short id, a linked worktree's name (`""` for the main one), and the files and lines that differ from HEAD (staged, unstaged, and untracked text files; files over 2 MB count as binary); `error` when there's no repository there |
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
| `getScrollMax(name, "horizontal"?)` | the furthest that scroll goes right now: the content's size less the part in view (0 when it all fits) |
| `watchScroll(name)` | from then on, `"<name>.scrolled"` (the new vertical offset) whenever it moves: the user's wheel or drag, `setScroll`, or the widget keeping it in range |
| `setDraggable(name, on = true)` | the widget raises `dragStarted`, `dragging`, `dragEnded` (`"x,y"`) while dragged with the left button — splitters, column dividers |
| `setDraggable(name, true, direction)` | the same, and the matching system resize cursor over it and while it's dragged: `"horizontal"` (left-right arrows), `"vertical"` (up-down), `"both"` (four arrows) |
| `setCursor(name, shape)` | the system cursor over a widget and its children: `"sizewe"`, `"sizens"`, `"sizeall"`, `"hand"`, `"ibeam"`, `"arrow"` (a button inside one of those), or `""` for the UI's own |
| `setVisible` / `setEnabled` / `setChecked(name, bool)` | `setChecked` doesn't raise `toggled` |
| `setProperty(name, prop, value)` / `getProperty(name, prop)` | any widget property |
| `getRect(name)` | `x, y, width, height` on screen, or `nil` |
| `textRects(name, first, last)` | where bytes `first` to `last` (1-based) of a static text's markup, as set with `setText`, are drawn: `{ {x, y, width, height}, … }`, one rectangle per line they wrap onto, relative to the widget (as a child's `Area` is); `{}` when it isn't a static text. For laying clickable spots over words (Bragi's links) |
| `shownText(name)` | the text a widget shows: its markup with the tags left out, `[br]` as a line break, escapes read (a picture is U+FFFC). Its Nth character is the one at index N-1 below |
| `shownRects(name, first, last)` | `textRects` for the characters a static text shows at indices `first` to `last` (0-based, inclusive): for drawing a text selection |
| `textIndexAt(name, x, y)` | where a caret at window pixel `x, y` goes in a static text: `0` before its first character, N after its Nth; above the text `0`, below it the end; `nil` when it isn't a static text |
| `watchPointer(name)` | from then on, a mouse press over the widget or its children raises `"<name>.pointerDown"` (`"x,y,button,clicks,control"`: button 1 left or 3 right, clicks 1 to 3, control 1 when it landed on a button, list, editbox or scrollbar); until that button is up, moves raise `pointerMoved` (`"x,y"`, also outside it) and the release `pointerUp` (`"x,y,button"`). The widgets still get their input. For selecting text |
| `focus(name)` / `bringToFront(name)` | |
| `createWindow(type, name, parent)` / `destroyWindow(name)` | runtime widgets (raise events like layout widgets) |
| `loadLayout(file, parent = "Root")` | attach a layout file (relative to the running UI's `layouts/`; `resources/layouts` for the GitGud UI) |
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
| `accepted` | single-line editboxes; multi-line editboxes with `<UserString name="SubmitOnEnter" value="true"/>` (Shift+Enter then breaks the line) | `""` (Enter) |
| `dragged` | lists | `"fromRow,toRow"` (0-based) — pressed on one row, released on another |
| `hovered` | any widget whose `ReportHover` property was set to `"true"` | `"1"` when the mouse comes over it or its children, `"0"` when it leaves |
| `dragStarted` / `dragging` / `dragEnded` | widgets made draggable with `setDraggable` | `"x,y"` — the cursor, in window pixels |

### Tab between text boxes

Tab and Shift+Tab move to the next and previous text box and select its
text, wrapping around. They stay inside the box's group: the nearest
window with `<UserString name="TabGroup" value="true"/>`, an always-on-top
window (a dialog or popup), or else the top-level view. The order is
`<UserString name="TabIndex" value="n"/>` first, then top to bottom and
left to right. Hidden, disabled, and read-only boxes are skipped. A
single-line box opts out with `<UserString name="TabStop" value="false"/>`;
a multi-line box takes part only with `TabStop` `"true"`, so editors keep
Tab otherwise. Ctrl+Tab stays a shortcut.

## Events, timers, shell

| Function | |
|---|---|
| `on(event, fn)` | subscribe (widget or app events) |
| `off(event)` | drop every handler of the event (the handlers of a window that has gone) |
| `emit(event, detail)` | publish an event (delivered in the same frame) |
| `keepForReload(key, text)` | keep text for the scripts after a hot-reload (`app.reloading`, below); `nil` forgets it |
| `takeKept(key)` | what was kept under `key` before the reload, once (then it's gone), or `nil` |
| `after(ms, fn)` / `every(ms, fn)` → id | timers; `cancelTimer(id)` |
| `now()` | milliseconds, monotonic |
| `openExternal(path)` / `showInFolder(path)` | open a file, folder or web address with its default app (a folder in the file manager, a web address in the browser) / open the file manager with a file or folder selected (Explorer; Finder on macOS; on Linux a file manager that takes the desktop's ShowItems call, else the folder opens) |
| `spawn(commandLine, cwd?)` | start a program |
| `pickFolder(title)` | folder picker; `nil` if cancelled |
| `pickFile(title?, filterName?, pattern?)` | file picker showing files matching `pattern` (`"*.wav"`); `nil` if cancelled |
| `setClipboard(text)` | |
| `clipboardHasText()` | `true` when the clipboard holds text |
| `clipboardImage()` → path, width, height | the picture on the clipboard, saved as a PNG in the local data folder's `chat-images/` (named by its content); `nil` when there is none. Windows only for now |
| `clipboardFiles()` | the files copied in a file manager: `{ paths }` (Windows only for now) |
| `imageSize(path)` → width, height | from an image file's header; `nil, msg` when it isn't one |
| `showImage(name, path, maxWidth, maxHeight)` → width, height, fullWidth, fullHeight | decode an image file, scale it down to fit (never up), and publish it as the image `name` (a `Gitgud/Image`'s `Image` property); the same file at the same size again is free |
| `drawPicture(name, width, height, shapes)` | draw lines and circles into a picture and publish it as the image `name` (sharp at the display's pixel density); `true` or `nil, msg`. Each shape is `{ kind = "line", points = { x1, y1, x2, y2, … }, width, colour }`, `{ kind = "disc", x, y, radius, colour }`, or `{ kind = "ring", x, y, radius, width, colour }`; `colour` is `"AARRGGBB"` and its alpha is the shape's opacity. The Bragi wiki's Graph tab draws with it |
| `pathExists(path)` | `true, "file"` or `true, "folder"`; `false` when nothing is there |
| `isDictionaryWord(text)` | `true` when the text (a word, or words) has no spelling errors in US English, `false` when it has some; `nil` without an answer (not Windows, no dictionary, empty text). Windows' own spell checker |
| `readRepoFile(rel)` / `writeRepoFile(rel, text)` | files inside the open repository only |
| `trashRepoFile(rel)` | move a file inside the open repository to the Recycle Bin (the Trash on macOS) |
| `configRead(name)` / `configWrite(name, text)` | per-user files in `%APPDATA%\Gitgud` (`~/Library/Application Support/Gitgud` on macOS, `~/.config/gitgud` on Linux). A name is letters, digits, `-`, `_` and `.`, or such names joined by `/` for a file in a folder there (`voice-recordings/a.wav`; written folders are created). A write is atomic: a temporary file renamed over the old one, so a crash leaves one or the other |
| `configPath(name?)` | the full path of a config file or folder (the config folder without a name); it may not exist |
| `configList(folder)` | `{ {name, size}, … }`: the files in a folder of the config folder, by name (`{}` when there's none) |
| `configRemove(name)` | delete a config file (not a folder); `true` or `nil, msg` |
| `makeDir(path)` | make a folder and its parents (anywhere); `true` or `nil, msg` |
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
| `appDir()` | the folder the app runs from (holds `resources/`, `docs/`, and on Linux and macOS the bundled `gh/`); on macOS the app bundle's `Contents/Resources` |
| `version` | app version string |
| `platform` | `"windows"`, `"macos"` or `"linux"` |

### App events

`app.started` (detail `"hot-reload"` after a reload), `app.reloading`
(just before a hot-reload, while the old scripts still run: keep what the
next ones need with `keepForReload`), `app.focusGained`,
`app.fileDropped` (path), `key` (combo, e.g. `"ctrl+shift+p"`, also plain
`"up"`, `"down"`, `"pageup"`, `"pagedown"`; see `core/keys.lua`. On macOS
Command is reported as `ctrl`, so bindings work unchanged),
`status.changed`, `repo.changed`, `repo.error`, `credential.missing`,
`credential.rejected`,
`ssh.unknownHost`, `console.output` / `console.done`, `window.state`
(`"maximized"` / `"restored"`),
`window.resized` (`"WxH"`), plus the network events above. Scripts can ask
the UI to hot-reload now (`app.reload`, as if its files had changed), the
window to `window.minimize`, `window.toggleMaximize` (zoom on macOS),
`window.notify` (`"Title\nbody"`: while the window is in the background,
flash its taskbar button and show a desktop notification; Windows only so
far, and never under the test harness), `window.canvas` (`"AARRGGBB"`:
the colour behind the UI, seen while the window resizes; the alpha is
ignored), `window.close`.
Pop-out windows add `window.closed` (id), `window.key` (`"id|combo"` — a
pop-out's shortcuts don't reach `key`), `window.focused` (id), and
`window.popOutResized` (`"id|WxH"`).

### Hot-reload

The app watches the running UI's `layouts/`, `scripts/`, `looknfeel/`,
`schemes/`, `imagesets/`, `prompts/`, and `themes/` (and the base
resources'). Once a change has settled (nothing more changed for 1.5 s,
so copying a whole folder over reloads once), it sends `app.reloading`,
throws the windows and the script VM away, reloads the skin (changed
imagesets too) and the layout, and runs `main.lua` again (`app.started`
with `"hot-reload"`). What lives in C++ carries on: Claude Code sessions,
voice listening and playback. Scripts take them up again
(`agentList`, `voiceInfo`) and bring back their own state with
`keepForReload` / `takeKept`. A change to the program's own files (the exe
and its libraries) can't be reloaded: the log says to restart.

## Windows and interfaces

| Function | |
|---|---|
| `openWindow{id, title, layout, width, height, minWidth, minHeight}` | open a separate OS window showing `layout` (from the UI's `layouts/`); its widgets are named `"<id>:<name>"`. An id that's open is raised. `true` or `nil, msg` |
| `closeWindow(id)` / `focusWindow(id)` / `setWindowTitle(id, title)` | `""` as the id is the main window (for `setWindowTitle`) |
| `windows()` | the open pop-out ids |
| `setWindowBordered(bool)` | the main window's OS frame on (native title bar) or off (the UI draws its own) |
| `currentUi()` | the running interface: `{id, name, description, root, overlay, builtIn}`: id `"default"`, a built-in's folder name, or `"path:<folder>"`; `overlay`: its customizations folder (`""` for a package on disk) |
| `uiOverlay(create?)` | the running interface's customizations (MODDING.md ▸ "Customizing a built-in interface"): `{root, shipped, files = {relative paths}, errors = { {file, error}, … }}` (`errors`: customized files that failed to load this run, the shipped ones used instead; each also arrives as `ui.overlayError`). `create` makes the folder |
| `uiFile(relative)` | the interface's file by its path in the package (`"prompts/master.md"`): the customized one when there is one, else the shipped one (which may not exist) |
| `uiOverlayReset()` | move the customizations folder aside (`<root>.backup-<yyyymmdd-hhmmss>`, returned) and reload; `nil, msg` when there's nothing to reset |
| `uiList()` | the interfaces to choose from (same shape), GitGud's first |
| `switchUi(id, remember = true)` | switch after the current handler returns (every window's widgets and the Lua VM start over); `remember` makes it the one GitGud starts with. `nil, msg` for a folder that isn't a UI package |
| `showUiPicker()` / `previousUi()` | run the interface picker (not remembered); the interface that was running before |
| `firstLaunch()` | `true` until an interface has been chosen |
| `restartApp()` | restart: start the same executable again with the same arguments, working folder and environment (so the same settings and data), then close this copy the way closing its window does (`window.close`). The new copy waits for this one to exit before it starts. `true`, or `nil, msg` when it couldn't be started (nothing closes) |

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

## Stores in Git

Files kept in bare Git repositories in the config folder, each change a
commit, so every file has its history (the Bragi interface's wikis). A
store is named like a config file (`bragi/wikis/app.wiki.git`); `ref` is a
revision, HEAD by default. Failures return `nil, msg`.

| Function | |
|---|---|
| `bareFiles(store, ref?)` | `{ {path, size}, ... }` sorted by path; `{}` for a store not made yet |
| `bareRead(store, file, ref?)` | the file's text, or `nil` when it isn't there |
| `bareCommit(store, changes, message, name?, email?)` | apply `{ {path, content}, ... }` (`content` false removes the file) as one commit, making the store when it's missing; the commit id, or `""` when nothing changed |
| `bareLog(store, file?, max?)` | `{ {id, message, author, time}, ... }` newest first (`time` in seconds since 1970), only the commits that changed `file` when given |

## JSON

| Function | |
|---|---|
| `jsonDecode(text)` / `jsonEncode(value)` | JSON to Lua and back (`nil, msg` on failure). JSON null reads as `nil`; an empty table writes as `{}` |
| `lookup(path, key)` | The value for `key` in a large sorted `.tsv` file of `key<TAB>value` lines (sorted by the keys' bytes), or `nil`; `nil, msg` when the file can't be used. Each file is read once per run. For word lists too big to hold as tables (the Bragi interface's pronunciation dictionaries) |

## Voice

Voice input and spoken replies for the Bragi interface, through a speech
engine: two channels, `listen` (the echo-cancelled microphone up,
transcripts down) and `speak` (text up, speech down to the speaker).
Windows only for now.

The engine runs inside the app: sherpa-onnx (Silero speech detection, a
Zipformer wake word spotter, Parakeet speech recognition, TitaNet speaker
recognition) for `listen`, and for `speak` a small built-in voice
(`small:<name>`: a few-MB model in an interface's `voices/<name>` folder,
`model.onnx` and `phonemes.tsv`, on the processor; its `say` text is
phonemes, and `sampleRate` is the rate it plays at), Chatterbox Turbo in a
voice made from a recording (`voiceMakeVoice`), or the system's voices. Its
libraries live in the `voice` folder beside the exe (sherpa-onnx's CPU
build with ONNX Runtime's GPU build, which runs on the processor) and load
the first time voice starts (never for an interface that doesn't use
voice). Its models aren't part of the app: the Bragi interface downloads
them on the user's OK into the local app data folder and tells the engine
where they are (`voiceEngineSetup`): the listening models, Chatterbox
Turbo (`tts`), and the optional GPU pack for NVIDIA GPUs, ONNX Runtime's
CUDA provider and NVIDIA's CUDA and cuDNN libraries (`gpuDir`); the small
voices' folder comes with the interface (`small`). The Bragi interface's
replies use its built-in voice (`voices/bragi-1`, its text made phonemes by
`bragi/phonemes.lua`) unless another is chosen; it makes Baldr from
`voices/baldr/ref.wav` once Turbo is in. One ONNX
Runtime serves both channels. Listening always runs on the processor and
never waits for the GPU; with the GPU pack, Turbo moves to the GPU the
next time it loads, in the same run, and stays on the processor (with
`voiceEngine().gpuError`) if the GPU doesn't start. A build without the `voice` folder
has no engine: `voiceInfo().available` is `false` and `voiceListen`,
`voiceSpeak`, and `voiceSpeakPrepare` return `nil, "Voice isn't
available"`. The devices and the microphone check work without one.

The engine guards the app against its libraries: one thread for each
channel makes every call into them, each call is caught (exceptions and access violations)
and timed (a call past its limit counts as hung), and every model file is
checked against its SHA-256 before it loads. After an access violation or
a hung call the engine stops for good (until the app restarts) and the
`listen` channel ends with an `error` whose `code` is `engine-fault` or
`engine-hung` and `restart` is `true`. Other codes: `engine-files` (a model
missing or damaged: repair it), `engine-missing` (its libraries missing or
the wrong version), `engine-error` (three failed calls in a row; voice can
start again). If the app ends inside a call, the next start's
`voiceEngine().lastCrash` says which, until `voiceEngineForgetCrash()`
(the user turned voice back on). When the app closes, the engine releases
its models before the teardown; a call it's in then is marked as made at
exit and is never reported as a crash.

| Function | |
|---|---|
| `voiceListen(options?)` | open the `listen` channel; once the engine is `ready`, the microphone streams (16 kHz, 20 ms frames). `options` are `hello` fields: `wakeWord`, `closingPhrase`, `contextTokens`, `messageContextTokens`, `lookbackTokens`, `endWaitSeconds`, `mishearings`, `wakeThreshold`, `vocabulary` (any field passes through). `true` or `nil, msg` |
| `voiceStop()` | microphone off, channel closed |
| `voiceConfig(fields)` | change `hello` fields while listening (a `vocabulary` replaces the last one) |
| `voiceRecord(path?)` | save the mic audio as the engine gets it (each frame once it has gone out) to a WAV file at `path` (16 kHz mono 16-bit; its folder is created), until called without a path or listening stops; then `voice.record` (`{state: off, path, seconds}`). `true` or `nil, msg` |
| `voiceWake()` / `voiceSend(reason?)` / `voiceCancel()` | start a message now (the mic button), end it now (Send; `reason` `button` or `done`, when the app judged it finished), drop it |
| `voiceLookback(id, tokens?)` | ask for the newest transcript, up to `tokens` (default the engine's `contextTokens`); `voice.lookback` answers with the same `id` |
| `voiceTrain(state)` / `voiceEnroll(state)` | wake word training (`start`, `stop`) and voice enrollment (`start`, `stop`, `clear`) |
| `voiceSpeak(id, text, options?)` | speak `text` (opens the `speak` channel on first use); `options`: `voice`, `sampleRate`, `speed` (1 is normal pace), `voicing` (a small voice's `wobble`, `rough`, `roughLow`, `roughHigh`). A `small:` voice's `text` is its phonemes. Send replies a sentence or paragraph at a time |
| `voiceSpeakPrepare()` | open the speak channel and the speaker now (Bragi calls it when listening starts), so the first reply waits for neither; `true` or `nil, msg` |
| `voiceSpeakStop(id?)` | stop that reply, or all of them; playback goes quiet at once |
| `voiceInfo()` | `{available, listening, speaking, playing}` (`available`: a speech engine is there; `playing`: the reply id being heard, or `""`) |
| `voiceEngine()` | the engine inside the app: `{installed, configured, loaded, faulted, faultCode?, fault?, gpu, runtimeDir, turbo, turboDevice, gpuError?, test?, lastCrash?}`. `installed`: its libraries are there (nothing loads to say so); `faulted`: it stopped after an internal error; `gpu`: the CUDA provider started (it stays for the run); `runtimeDir`: where the libraries loaded from (`""` until they load); `turbo`: Chatterbox Turbo is set up; `turboDevice`: where it loaded, `"gpu"` or `"cpu"` (`""` while it isn't loaded); `gpuError`: why it isn't on the GPU it was asked to use; `lastCrash` (`{call, log}`): the call it was in when the app ended without warning last time, and the end of its log (`<app data>/bragi/voice-engine.log`) |
| `voiceEngineSetup(settings)` | the models and how to run them, used from the next time listening starts: `vadModel`, `asrDir`, `kwsDir`, `speakerModel`, `voiceprintsDir`, `workDir`, `files` (`{ {path, size, sha256}, … }`, checked before loading), plus `asrThreads`, `kwsThreads`, `speakerThreads`, `hotwords`, `partialSeconds`, `wakeWord`, `spotterSpellings`, `mishearings`, and the other listening settings. With Chatterbox Turbo: `tts` (`{dir, encoder, embed, lm, decoder, tokenizer, voicesDir, provider, threads, cpuThreads, files}`: its graphs, where made voices go, `"cuda"` or `"cpu"`, and the processor threads on the GPU and without it); with the GPU pack, `gpuDir` (its folder: Turbo moves there the next time it loads, no restart); with small voices, `small` (`{voicesDir, threads}`: the folder whose `<name>` folders are the `small:<name>` voices, and their processor threads). `true` or `nil, msg` |
| `voiceSelfTest(task, wav?)` | load every model and run each once (on generated sound, or on `wav`, 16 kHz mono 16-bit); `<task>.done` carries `{ok, loadMs, decodeMs, text, keywords, speaker, code?, message?}`. `true` or `nil, msg` |
| `voiceVoices()` | the system's voices for spoken replies: `{ {id, name, language}, … }` or `nil, msg` |
| `voiceEngineRelease()` | release the models now (before removing them); they load again when listening starts |
| `voiceEngineForgetCrash()` | the last run's crash (`voiceEngine().lastCrash`) isn't reported again this run |
| `voiceMakeVoice(task, wav, name)` | make a voice from a recording (a WAV file; 10 to 20 s of one person speaking): Chatterbox Turbo's conditioning for it, saved as `<voicesDir>/<name>.voice`; then `say` with `voice` `"turbo:<name>"` speaks in it. `<task>.done` carries `{ok, seconds?, ms?, code?, message?}`. `true` or `nil, msg` |
| `gpuInfo()` | the NVIDIA GPU, from the driver's own library: `{present, driver, cuda, devices = { {name, memory}, … }, error?}` (`cuda`: the newest CUDA the driver runs, `13030` for 13.3) |
| `onnxSetAccuracy(in, out, level, task?)` | copy an ONNX graph with `accuracy_level` set on its quantized matmuls (MatMulNBits); the number changed, or `nil, msg`. With `task`, on a worker: `<task>.progress` (`{phase = "patch", done, total}`), then `<task>.done` with the number changed |
| `voiceTestEngine(mode?)` | tests only (under `GITGUD_SCRIPT`): `"fake"` or `"fault"` swaps in a stand-in engine with a quiet microphone and speaker (`GITGUD_TEST_VOICE` does the same from the start); `nil` goes back |
| `audioDevices()` | `{inputs = { {id, name, default}, … }, outputs = …}`: the microphones and speakers plugged in (`default`: the system's default device, the one voice opens when none is picked); empty lists where devices can't be listed |
| `setAudioDevices(input, output)` | the devices voice opens from its next start; `""` or `nil` is the system default. One that's unplugged falls back to the default. A new speaker closes the `speak` channel; the next `voiceSpeak` plays there |
| `micTest(on)` | the chosen microphone on its own, no engine needed: while on, `audio.level` arrives ten times a second with its level, `0` to `1` (RMS, -60 to 0 dBFS). `true` or `nil, msg` |

The listen functions return `nil, "Voice input is off"` when it is.
Events carry JSON text. From `listen`: `voice.<type>` for the engine's
messages (`ready`, `vad`, `wake`, `partial`, `message`, `cancelled`,
`ambient`, `lookback`, `trainSample`, `trainResult`, `enrollSample`,
`enrollResult`, `error`), plus `voice.mic` (`{state: on|off, device,
route?}`; `route` on `on`: the mic, the echo reference, and the ducking
opt-out), `voice.record` (a `voiceRecord` file ended), `voice.level`
(`{t, rms, max}` for each second of the mic: its
RMS and loudest 20 ms in dBFS, `t` its end in the engine's times) and
`voice.closed` (`{code, reason}`, last). From `speak`: `voice.speech.<type>`
(`start`, `end`, `stopped`, `error`, `closed`). `voice.playback`
(`{state: started|stopped, id}`) says when a reply is heard; the app tells
the `listen` channel too, so the engine knows its own voice. Local failures
are errors with `code` `connect`, `audio`, or `no-ready`.

## Local app data

A per-user folder for large files the app fetches for itself, such as the
Bragi interface's voice models: `%LOCALAPPDATA%\Gitgud` on Windows,
`$XDG_DATA_HOME/gitgud` (`~/.local/share/gitgud`) on Linux, the settings
folder on macOS. Names are relative, with the config folder's rules
(letters, digits, `-`, `_`, `.`, and `/` between parts; no `..`).

| Function | |
|---|---|
| `localDataPath(name?)` | the folder's path, or `name`'s in it |
| `localDataInfo(name)` | `nil` or `{dir, size, mtime}` |
| `localDataList(name)` | the names in a folder (empty if none) |
| `localDataRead(name)` / `localDataWrite(name, text)` | a file's text (`nil` if none); write it atomically (`true` or `nil, msg`) |
| `localDataRemove(name)` / `localDataMove(from, to)` | remove a file or folder; move one (`to` is replaced). `true` or `nil, msg` |
| `downloadFile(task, {url, file, sha256, size?})` | download an https `url` to the local data name `file` through `<file>.part`, carrying on from an earlier try; check the size and SHA-256 (a wrong file is deleted), then rename. `<task>.progress` (`{phase: download\|verify, done, total}`) a few times a second; `<task>.done` carries the path |
| `downloadCancel(task)` | stop a download, or any of the tasks below; `<task>.error` is then `"cancelled"`. What a download got is kept for the next try; a half-done copy or unpack is removed |
| `fileSha256(task, path)` | `<task>.done` carries the SHA-256 of the file at `path`; `<task>.progress` (`{phase: verify, done, total}`) as it reads |
| `copyToLocalData(task, path, name)` | copy the file at `path` to `name` (through `<name>.part`); `<task>.progress` (`{phase: copy, done, total}`) |
| `extractArchive(task, path, name)` | unpack the archive at `path` (`.zip`, `.tar.bz2`, ...) into the folder `name`, emptied first; `<task>.progress` (`{phase: unpack, done, total}`): the bytes of the archive the unpacker has read, so a `.tar.bz2` reports as it decodes |

## Agent

Claude Code sessions: `claude -p` kept open with stream-json both ways.
Scripts name each session; names survive script reloads, and so do the
sessions: they keep running through a hot-reload, and the reloaded scripts
find them with `agentList` and take them up again.

| Function | |
|---|---|
| `agentStart(name, options?)` | start a session; `options`: `cwd`, `model`, `permissionMode`, `effort` (`low` ... `max`), `settings` (extra Claude Code settings: a file or JSON text), `resume` (a session id), `resumeAt` (with `resume`: only its messages up to and including this transcript entry, by its `uuid` from `agentHistory`; the session goes on from there, the rest left on a branch behind: a rewind), `forkSession` (`true`, with `resume`: it goes on as a new session with the history, the resumed one left as it was), `systemPrompt` (replaces Claude Code's own), `appendSystemPrompt`, `mcpConfig` (a file or JSON text; default: the app's Git tools, below; `false` for none), `persist` (`false`: Claude Code saves no transcript, for helper sessions), `lean` (`true`: no tools, MCP servers but `mcpConfig`'s, skills, CLAUDE.md, or auto memory, in an empty folder unless `cwd` is given; for helper sessions), `tools` (the built-in tools it keeps, such as `"Read,Grep,Glob"`; with `lean`, none when unset), `uiTools` (`true`: the tools the UI declared with `declareTools` too, below; for the main agent session only), `repository` (the folder its Git and P4 tools act on; default its `cwd`; `false`: the app's open repository), `program` (default `claude`). `true` or `nil, msg` |
| `agentSend(name, text, images?)` | a user turn; while a turn runs, Claude Code takes it at the next step. `images`, a list of image files, go before the text as image blocks (scaled down to what the model takes) |
| `agentRespond(name, requestId, allow, message?)` | answer a permission request (`message` tells the model why it was denied) |
| `agentAnswer(name, requestId, answers)` | answer Claude's questions (`AskUserQuestion`): `answers` maps each question's text to the chosen label (several joined with `", "`) or your own words; `agentRespond` never allows it |
| `agentInterrupt(name)` | end the running turn (a waiting permission request is denied first); `nil, msg` between turns |
| `agentSetMode(name, mode)` / `agentSetModel(name, model)` | change the permission mode or model for the next steps |
| `agentControl(name, subtype, fields?)` | ask Claude Code anything its control protocol takes (`get_usage`, `apply_flag_settings`, ...), `fields` (a table, or JSON text when it needs a `null`) beside the subtype in the request; returns the request id, and the reply comes as `agent.control` |
| `agentStopTask(name, taskId)` | stop one of its tasks, a sub-agent or a background command, by the `task_id` of its `task_started` system message (Claude Code's `stop_task`); `task_notification` with status `stopped` follows, or `agent.error` when Claude Code can't |
| `agentStop(name)` | close its input, end it after 1.5 s; `agent.exit` follows |
| `agentInfo(name)` | `{name, running, turnActive, sessionId, pendingPermission, pid, pending, options}`, or `nil` for a name never started. `pid` is the process's id (0 once it ended); `pending` the permission requests waiting, oldest first: `{ {requestId, tool, input}, … }` (`input` as JSON text); `options` what `agentStart` was given (`program`, `cwd`, `model`, `permissionMode`, `effort`, `settings`, `resume`, `resumeAt`, `forkSession`, `systemPrompt`, `appendSystemPrompt`, `mcpConfig`, `tools`, `persist`, `lean`; a `lean` one started without a `cwd` has the folder it was given) |
| `agentList()` | every session started under a name, running or not, by name, each as `agentInfo` gives it |
| `declareTools(tools)` | the UI's own tools for Claude Code (below): a list of MCP tool definitions `{name, description, inputSchema, annotations?}`, replacing any declared before (`{}` for none). `true` or `nil, msg` |
| `toolReply(id, text, isError?)` | answer a call of one of the UI's tools (`tools.call`, below); `false` when it no longer waits |
| `agentSessions(cwd)` | Claude Code's saved sessions for a working folder, the most recently active first: `{ {id, title, asked, updated, active, cwd}, … }` (`title` Claude Code's, else the first thing asked; `asked` the first thing asked, past what was put in front of it; `updated` when the file was last written, `active` when its last message was, both in seconds since 1970; `cwd` the folder its lines name, `""` when none). Resume one with `agentStart`'s `resume` |
| `agentProjects(perProject = 30, maxProjects = 100)` | every project folder with saved sessions, the most recently active first: `{ {cwd, folder, updated, sessions}, … }`; `cwd` from its transcripts (`""` when none names it), `folder` its folder's name, `sessions` as `agentSessions`' (its newest `perProject`) |
| `agentHistory(cwd, id)` | a saved session's main conversation: `{ {kind, text, id, name, input, isError}, … }`; `kind` is `user`, `assistant`, `tool` (`id`, `name`, `input` as JSON text), `toolResult` (`id`, `text`, `isError`), or `compacted` (`text` the trigger, `manual` or `auto`; `input` its metadata as JSON text, `preTokens` and `postTokens` among it); a slash command reads as `user` text as typed (`/compact keep it short`), its output as `assistant`; `images`, the paths of the pictures in a user message or tool result (stored in `chat-images/`); `uuid`, its transcript entry, and `parentUuid`, the one before it (`""` when none). Only the branch the session goes on from is read (a rewound one's, without what was rewound). Looked for in `cwd`'s folder, then in every project's |
| `agentForkTranscript(cwd, id, upTo, toDir)` | copy a saved session up to and including the entry `upTo` (its `uuid`; `""` for all of it) as a new session of the folder `toDir`, its lines given the new id and folder: Claude Code resumes a session only in its own folder. Its new id, or `nil, msg` |
| `agentSessionProcesses(id)` | how many other processes have a session id on their command line (Claude Code running it in another window; Windows and Linux) |
| `agentTitle(text)` | a conversation's title from a user message: its first line, cut to about 80 characters, skipping blocks Claude Code or apps put in front of it (system reminders, task notifications, command output); `""` when that's all there is |
| `agentConfigDir()` | Claude Code's config folder (`CLAUDE_CONFIG_DIR`, else `~/.claude`) |
| `agentContextFiles(cwd?)` | the instruction, memory, and settings files Claude Code loads for a folder (those that exist): `{ {kind, path}, … }`, `kind` `user`, `userRule`, `project`, `local`, `projectRule`, `memory`, or `settings` |

Saved sessions are read from `CLAUDE_CONFIG_DIR` (or `.claude` in the
home folder), `projects/<folder>/<id>.jsonl`, where `<folder>` is the
working folder with every character but letters and digits turned into
`-`. That name can't be turned back into the folder, so `agentProjects`
reads the folder from the transcripts' own lines (`cwd`). What a
transcript's first lines say is kept in memory while the file is
unchanged, so listing again is quick. Sub-agents' lines are left out.

Events are `agent.<type>` with JSON text (`jsonDecode` it): the fields
below plus `session`, the name.

| Event | Fields |
|---|---|
| `agent.init` | `sessionId`, `model`, `permissionMode`, `cwd`, `tools`, `apiKeySource` (`none` with the claude.ai sign-in), `version`, `outputStyle`, `mcpServers` (`{name, status}`), `slashCommands`, `skills`, `plugins` (`{name, path}`), `agents` |
| `agent.block` | `type` (`text`, `tool_use`, `thinking`), `name`: a streamed block of the main agent starts |
| `agent.text` / `agent.thinking` | `text`: a streamed piece of the main agent's text or thinking |
| `agent.message` | `text`, `parent`, `uuid`: a whole text block (`parent` is the Agent tool call's id for sub-agents, else `""`; `uuid` the message's, the same again when compaction sends a kept message again). A slash command's output (`/context`, `/usage`) comes as one, its `agent.usage` from model `<synthetic>` with no tokens |
| `agent.tool` | `id`, `name`, `input`, `parent` |
| `agent.usage` | `model`, `usage` (as Claude Code sends it: `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`), `parent`, `messageId`: one model call's tokens, once per call (sub-agents' too: `parent` is their Agent call's id) |
| `agent.toolResult` | `id`, `text`, `content` (as sent, but each base64 image block replaced with `{ type = "image", path }`), `isError`, `parent`, `images` (the paths) |
| `agent.permission` | `requestId`, `tool`, `input`, `suggestions`, `toolUseId` |
| `agent.result` | `subtype`, `isError`, `interrupted`, `text`, `sessionId`, `costUsd`, `turns`, `durationMs`, `usage`, `modelUsage` (per model, as sent; `contextWindow` among its fields): the turn ended |
| `agent.rateLimit` | `info`: the subscription's usage limits, Claude Code's `rate_limit_info` as sent: `status` (`allowed`, `allowed_warning`, `rejected`), `rateLimitType`, `utilization`, `resetsAt` (the limiting window), and `unifiedWindows` with `five_hour` and `seven_day`, each `{ utilization, resetsAt }` (the fraction used, usually 0 to 1; epoch seconds). Sent when a window's rounded percent or reset time moves; a window the account doesn't have is left out, and API-key sessions get none |
| `agent.system` | `subtype`, `raw`: other system messages; the session's tasks among them (`task_started` with `task_id`, `tool_use_id`, `description`, `task_type`, `is_backgrounded`; `task_progress`; `task_updated` with `patch`; `task_notification` with `status` `completed`, `failed`, or `stopped`; `background_tasks_changed` with the running ones); compaction (`status` with `status` `"compacting"` while it runs, then `compact_boundary` with `compact_metadata`: `trigger` `manual` or `auto`, `pre_tokens`, `post_tokens`) |
| `agent.control` | the reply to an `agentControl` request: `requestId`, `subtype`, `ok`, `response` (Claude Code's, as sent), `error` (when not `ok`) |
| `agent.error` | `message`: Claude Code refused a request |
| `agent.stderr` | `line` |
| `agent.exit` | `code`: the process ended |

### Git and P4 tools for Claude Code

Sessions get the app's own MCP server, `repo`, unless `mcpConfig` says
otherwise. Claude Code runs `gitgud-mcp` (next to the app's exe), which
forwards each call over a named pipe to the running app. At startup the
app writes the config to `mcp/<app>-tools-<process id>.json` in its
settings folder, and each session gets one of its own beside it
(`...-s-<session>.json`, running `gitgud-mcp --session <name>`); all are
deleted on exit. A call says which session made it, so the tools act on
that session's repository (`agentStart`'s `repository`, by default its
`cwd`), else on the repository open in the app. All tools only read; like any MCP tool, each call goes through the
permission prompt unless the session's permission mode or settings allow
it (their names are `mcp__repo__<tool>`).

| Tool | Arguments | |
|---|---|---|
| `status` | | folder, backend, branch, ahead/behind, operation in progress, changed files |
| `diff` | `scope` (`all`, `staged`, `unstaged`), `path`, `commit`, `context` | unified diff of uncommitted changes, or of one commit |
| `log` | `max` (default 30), `ref`, `path` | history, newest first |
| `show` | `commit`, `patch` | one commit: message, parents, files, optionally the diff |
| `branches` | `remotes` (default `true`) | branches or streams, with upstreams |
| `p4_changes` | | Perforce: pending changelists with opened and shelved files |

Output is cut at 100 KB. Failures (no repository open, the app closed, a
bad argument) come back as tool errors with a message.

### The UI's own tools for Claude Code

A UI can give the main agent session tools of its own, next to the Git and
P4 tools on the same server: it declares them with `declareTools(tools)`
(MCP tool definitions: `name`, `description`, `inputSchema` of type
`object`, optional `annotations`, optional `sessions`: a list of session
names that see it, the others neither list nor call it; at most 32; names
are letters, digits, `_` and `-`, and not a Git or P4 tool's). Each declaration replaces the last;
switching UIs or reloading the scripts drops them. A session started with
`uiTools = true` sees them; its config is
`mcp/<app>-tools-<process id>-ui.json`, which runs `gitgud-mcp --ui-tools`,
and it asks the app for the list at each `tools/list` and `tools/call`.
Other sessions (the helpers) never get them.

The engine checks only that a call is for a declared tool and that its
arguments are an object; what the arguments may be is the script's to
check. A call goes to the script as the event `tools.call` (`{id, tool,
arguments, session}`, JSON text, the arguments as the agent sent them,
`session` the calling session's name), and the
script answers with `toolReply(id, text, isError?)` within 15 s (`false`
when the call no longer waits).

The Bragi UI declares its tools through `bragi/uitools.lua`, which
declares every module's together and hands each call to the module that
owns the tool. A definition marked `noCard = true` (one that only reads,
or only changes Bragi's own settings with an Undo) runs without a
permission card: it's on each session's allow list (`--settings`
`permissions.allow`), and granted if Claude Code asks anyway. The wiki
tools (`bragi/wikitool.lua`), Bragi's read-only master tools, and
`bragi_ui_paths` (`bragi/customize.lua`: the shipped interface folder,
the customizations folder, and the files customized) are marked so. Two
are for its own settings ("speak 20% faster"), in
`bragi/settingstool.lua`:

| Tool | Arguments | |
|---|---|---|
| `bragi_settings_get` | `setting` (optional) | the current values (and the voices to choose from) |
| `bragi_settings_set` | `setting`, `value` | change one setting |

Only this allow-list (`settingsTool.SETTINGS`, which also writes the tools'
descriptions and schema) can be read or changed:

| `setting` | Value | Setting key |
|---|---|---|
| `speechSpeed` | 0.8 to 1.5 (two places) | `bragi.speechSpeed` |
| `voice` | a voice id or name from the speech engine's list, `""` for its default | `bragi.voice` |
| `narrate` | `true` or `false` | `bragi.narrate` |
| `summaryLength` | `short` or `medium` | `bragi.summaryLength` |
| `endWaitSeconds` | 2 to 10 (one place) | `bragi.endWaitSeconds` |
| `showHeard` | `true` or `false` | `bragi.showHeard` |
| `quickAnswers` | `true` or `false` | `bragi.quickAnswers` |
| `theme` | `light` or `dark` | the UI's theme |
| `updateSeconds` | 3 to 120 (whole seconds); a value outside is set to the nearer end, not refused | `bragi.updateSeconds` |

The script checks every call (`settingsTool.check`): anything else, or a
value outside the range or choices, is refused with a message saying
what's allowed (`updateSeconds` is clamped instead, and the reply says so). A change applies at once, as Settings would, and shows in
the conversation with Undo; a theme change waits for the turn to end,
since switching rebuilds the window.

Like any MCP tool, each call goes through the permission prompt; the app
allows neither these nor the Git and P4 tools in advance.

The rest are Bragi's, the master conversation's (`bragi/master.lua`), kept
to its session (`sessions = { "bragi-master" }`) and allowed in advance
there (its folder's `.claude/settings.local.json`):

| Tool | Arguments | |
|---|---|---|
| `bragi_projects` | | the projects on this machine, and the projects folder |
| `bragi_conversations` | `project`, `limit` | conversations, newest first: id, title, project, last activity, state, whether Bragi sent them something |
| `bragi_read_conversation` | `id`, `exchanges` (default 3) | a conversation's last exchanges, cut to a few thousand characters |
| `bragi_send` | `id`, `message` | a message to a conversation (a saved one resumes in the background) |
| `bragi_start` | `project`, `message`, `title` | a new conversation in a project |
| `bragi_clone` | `url`, `name` | clone a repository by its Git address into `bragi.projectsFolder` (by default `Projects` in the home folder) |
| `bragi_open_project` | `project`, `show` | open a project as the Repo view's repository; `project` may be a local repository folder's full path, added to the projects when it isn't one |

## Backends and Perforce

The calls above work on Git repositories and on Perforce workspaces alike
(see [Perforce workspaces](P4.md) for how each maps). On Perforce, commit ids
are changelist numbers, and calls a backend can't do return `nil, "message"`.

| Function | |
|---|---|
| `backend()` | `"git"`, `"p4"`, or `""` when nothing is open |
| `supports(feature)` | whether the open repository can do it: `lineStaging`, `amend`, `undoCommit`, `reset`, `reflog`, `interactiveRebase`, `submodules`, `lfs`, `remotes`, `push`, `renameBranch`, `signing`, `changelists` (server-side changelists: Perforce only), … |
| `config("p4.port" / "p4.user" / "p4.client" / "p4.stream" / "p4.depotRoot")` | the workspace's server, user, workspace, stream, and the depot folder its root maps (`setConfig` changes port, user, `p4.charset`) |
| `p4Available()` | `true, path` when the p4 command-line client is found (else `false, ""`) |
| `p4Info()` | `p4 info` fields (`userName`, `clientName`, `clientStream`, `serverVersion`, …) plus `port`, `streams` |
| `p4Changes()` | the default changelist, then numbered pending ones: `{ {change, description, user, time, files = { {path, depotFile, action, type, rev, unresolved, locked} }, shelved = { {path, depotFile, action} } }, … }` (`change` is `"default"` or the number) |
| `p4NewChange(description, paths?)` | create a pending changelist (open `paths` move into it); returns its number |
| `p4SetDescription(change, text)` / `p4DeleteChange(change)` | edit / delete a pending changelist |
| `p4Reopen(paths, change?)` / `p4Edit` / `p4Add` / `p4Delete` | move to, check out in, open for add or delete in a changelist (`change` defaults to `"default"`) |
| `p4Move(from, to, change?)` | rename/move (checks the file out first) |
| `p4Revert(paths, keepLocal?)` / `p4RevertUnchanged(change?)` | revert files / revert unchanged open files (returns their paths) |
| `p4Reconcile(paths?)` | open offline edits, new files, and deletions (`paths` empty: the whole workspace) |
| `p4Submit(change, description, paths?)` | submit (only `paths` when given; the rest move to default); returns the submitted number |
| `p4Shelve(change, paths?, revert?)` / `p4Unshelve(from, to?, paths?)` / `p4DeleteShelf(change, paths?)` | shelve a numbered changelist / unshelve (returns `{applied, conflicted}`) / delete shelved files |
| `p4Shelves(allUsers?)` / `p4ShelvedFiles(change)` | shelved changelists `{ {change, description, user, time} }` / a shelf's files |
| `p4Lock(paths, lock)` | lock (`true`) or unlock open files |
| `p4FileStates(dir?, recursive?)` | `{ {path, depotFile, haveRev, headRev, headAction, headType, openAction, openChange, otherOpen, otherLock} }` |
| `p4Sync(paths?, revision?)` | get latest or a revision in the background: `p4Sync.done` (detail: files left alone because you changed them) / `p4Sync.error` |
| `p4ListStreams{port, user, charset?}` / `p4ListDepots{…}` / `p4ListWorkspaces{…}` | ask a server, no workspace needed: `p4Streams.done` (`stream\tname\tparent\ttype` lines), `p4Depots.done` (`name\ttype`), `p4Workspaces.done` (`name\troot\tstream\thost`) |
| `p4CreateWorkspace{port, user, password?, charset?, client?, root, stream? \| depotPath + branchRoot?, create?, sync?}` | create a workspace (and with `create` its stream) in the background: `p4CreateWorkspace.done` (detail: the root; open it with `openRepo`) |
| `p4Login(port, user, password)` / `p4Trust(port, fingerprint?)` | log in (ticket kept in memory) / trust an `ssl:` server |

Perforce passwords go through the usual credential events with the host
`"p4:<P4PORT>"` (`credential.missing`, `credential.rejected`), from any call,
not only network ones; `setCredential("p4:" .. port, user, password)` saves
one.

## Test harness

`simulateClick(x, y, "left" | "right" | "double", window?)`,
`simulateText(text, window?)`, `simulateKey(combo, window?)` (a key such as
`"enter"` or `"shift+enter"`, to the focused widget only), `simulateDrag(x1, y1, x2, y2, window?)` (press,
move, release with the left button), `simulateMove(x, y, window?)` (the mouse
moves there, no button), `simulateScroll(x, y, delta, window?)` (mouse
wheel; positive scrolls up), and `screenshot(path, window?)` (PNG of the next
frame) drive the UI — or pop-out `window` — from a script run via
`GITGUD_SCRIPT` (see `docs/BUILDING.md` ▸ Tests). `skipTime(ms)` moves
`now()` and the timers' clock ahead as if `ms` had passed (only under
`GITGUD_SCRIPT`), and `nextTimer()` is the ms until the next timer is due
(-1: none); `tests/ui/harness.lua` uses them to move on once a step's
checks pass.

## Profiling

See [PROFILING.md](PROFILING.md). `profileStart()`, `profileStop()` and
`profileToggle()` start and stop a capture (between frames; the reports'
folder comes as `profiler.saved`); `profiling()` returns whether one runs,
its seconds so far and the last report's folder. `stallThreshold([ms])`
reads or sets the stall watchdog's threshold (0: off); `stallCount()`
returns the stalls reported so far and the last report's text.
`uiStats()` returns how many windows the main window has and how many of
them are drawn (visible, with every parent visible).
