# Using the P4V UI

GitGud's second interface is laid out like Perforce's P4V, in the Dagobah
palette. It works on the same repositories as the default UI; Git has no
server-side changelists, so a few P4V ideas are mapped onto Git as described
under *How P4V ideas map to Git*. Switch to it from the interface picker
(first launch, or *File ▸ Switch user interface…* in the default UI); switch
back from *Edit ▸ Preferences ▸ Switch User Interface…* or *File ▸ Switch
User Interface…*.

## The window

- **Menu bar** — File, Edit, Search, View, Actions, Connection, Tools,
  Window, Help. Everything is also in the command palette (Ctrl+K).
- **Toolbar** — Refresh, Get Latest, Submit, Check Out, Add, Delete, Revert,
  Diff, History, Time-lapse, Rev Graph, Shelve, Integrate, Fetch, Push.
  Buttons grey out when they don't apply to the selection.
- **Address bar** — the selected file or folder as a depot path
  (`//repo/src/main.cpp`). Type a path and press Enter to go to it.
- **Tree pane** — *Depot* shows the repository's files as of the latest
  submitted changelist; *Workspace* shows your working folder, new files
  included. Icons show each file's state: checked out / edited (red check),
  opened for add (red plus), opened for delete (red cross), not added yet
  (?), unresolved (!), and out of date (yellow — changed on the remote
  branch since you last got it). The row above the tree names the workspace
  and branch; click it to switch workspaces.
- **Tabs** — *Files*, *History*, *Pending*, *Submitted*, *Branches*,
  *Labels*, *Workspaces* (View menu shows or hides each).
- **Log / Dashboard** — the Log lists every command GitGud ran, as the git
  command it amounts to, and its result. The Dashboard sums up the
  workspace: what to get, what to push, pending and shelved work, files to
  resolve, and your recent submits (double-click a line to act on it).
- **Splitters** — drag the bars between panes; sizes are remembered.

Tables sort by clicking a column header and resize by dragging the header
dividers. Ctrl+click and Shift+click select several rows; right-click for
the commands that apply.

## Pending changelists

*Pending* lists your changelists: the **default** one and numbered ones you
create (*New Changelist…*, Ctrl+N). Each shows its open files and, once
shelved, its shelved files.

- Edited files join the default changelist by themselves — Git needs no
  check out. **Check Out** (Ctrl+E) opens an unchanged file too, so it's in
  a changelist before you edit it.
- New files show as *not added* until you **Mark for Add**; turn on
  *Preferences ▸ Show new files in the default changelist* to list them all.
- **Mark for Delete** removes the file (to the Recycle Bin) and opens the
  deletion; **Rename/Move** moves a file and opens both sides.
- Drag files onto another changelist to move them, or right-click ▸ *Move
  to Changelist…*.
- **Revert** (Ctrl+R) throws away a file's changes; reverting an add only
  un-opens it (the file stays on disk). *Revert Unchanged Files* drops
  checked-out files you didn't edit.
- **Submit** (Ctrl+S) commits exactly the files you leave checked in the
  form, with the description as the commit message; *Push after
  submitting* sends it on. Edit ▸ Undo takes a submit back (the changes stay
  pending).

## Shelving

**Shelve** snapshots a changelist's files without submitting them: GitGud
commits them on top of your current changelist onto a branch of their own,
`shelves/<you>/<change>` (Preferences sets the prefix), and — with *Share
the shelf* checked — pushes that branch so teammates can see it. Your files,
the branch you're on, and your other changes stay exactly as they were.
Shelving again replaces the shelf. *Revert checked out files after they are
shelved* clears them from your workspace, as in P4V.

- **Unshelve** brings the shelved files back into the workspace (into the
  changelist, or the default one). Files you haven't edited take the
  shelved version; files you have get a three-way merge, and where both
  changed the same lines the file gets conflict markers to edit.
- **Delete Shelved Files** deletes the shelf's branch — locally and, if it
  was shared, on the remote.
- *Show changelists: All users* adds shelves other people shared (every
  `shelves/…` branch on the remote); unshelve them the same way.
- A changelist with a shelf can't be submitted until the shelf is deleted
  (as in P4V).

## History, submitted changelists, labels, branches

- **History** (Ctrl+T) — every revision of the selected file (numbered #1…#n
  along its history, like P4V) or folder, with Details and Files below.
  Double-click a revision to diff it against the one before; select two for
  *Diff Revisions*. Right-click to get a revision, open the time-lapse view
  or revision graph, branch or label from it, copy it to the current branch
  (cherry-pick), or back it out.
- **Submitted** — submitted changelists (commits), filtered by folder, user,
  and the current branch or all branches. *More…* loads older ones.
- **Branches** — local and remote branches with their latest changelist,
  owner, and sync state. Double-click switches the workspace to one;
  right-click to merge/integrate it, squash, rebase, compare (folder diff),
  track, rename, or delete.
- **Labels** — Git tags. Label any changelist from its context menu; *Push
  Labels* shares them.
- **Workspaces** — this repository's worktrees and every repository you've
  opened. Double-click to switch; *New Worktree…* adds a second workspace
  for the same repository.

## Windows

These open as separate windows (Window ▸ lists them; Esc closes one):

- **Diff** (Ctrl+D against the have revision, Ctrl+Shift+D against any) —
  both versions side by side as whole files, the words that changed
  highlighted. F7 / Shift+F7 step through the differences; *Ignore
  whitespace*, *Swap*, and *Edit File* are on its toolbar.
- **Revision Graph** (Ctrl+Shift+R) — the file's history across branches: a
  row per branch, a box per revision (rounded where the file was added,
  slanted where a branch started, pointed where it was merged in), arrows
  for branch points and merges. Click a box for its Details and
  Integrations; double-click to diff it. The Branch Filter hides rows; zoom
  with Ctrl+= / Ctrl+-; the Navigator shows the whole graph.
- **Time-lapse View** (Ctrl+Shift+T) — the file at each revision, every line
  labelled with the revision that last changed it, shaded by age or showing
  only that revision's changes. Drag the slider or use Page Up / Page Down.
- **Folder Diff** — every file that differs between two changelists,
  labels, branches, or a changelist and your workspace.

## How P4V ideas map to Git

| P4V | Here |
|---|---|
| Workspace | a working tree (repository folder or worktree) |
| Depot / #head | the repository at the latest changelist on your branch (HEAD) |
| Changelist number | a commit id (the first 8 digits shown) |
| Pending changelist | a local list of files, kept on this machine only |
| Check out | open the file in a changelist (no lock: Git has none) |
| Get Latest | pull from the branch's upstream |
| Submit | commit the changelist's files (then optionally push) |
| Shelve | a commit on a `shelves/…` branch, optionally pushed |
| Integrate / Copy | merge / cherry-pick |
| Back out | revert |
| Label | tag |
| Branch spec / stream | branch |
| Resolve | accept yours, theirs, or your edited merge of a conflicted file |

## Keyboard shortcuts

| | |
|---|---|
| Ctrl+Shift+G | Get Latest |
| Ctrl+E / Ctrl+R | Check Out / Revert |
| Ctrl+N / Ctrl+S | New Pending Changelist / Submit |
| Ctrl+D / Ctrl+Shift+D | Diff against the have revision / against… |
| Ctrl+T / Ctrl+Shift+T / Ctrl+Shift+R | History / Time-lapse / Revision Graph |
| Ctrl+Shift+I | Merge/Integrate |
| Ctrl+Shift+F / Ctrl+P | Fetch / Push |
| Ctrl+F / Ctrl+L / Ctrl+G | Find File / Go to Depot Path / Go to Changelist |
| Ctrl+1 / Ctrl+2 | Depot / Workspace tree |
| Ctrl+J / Ctrl+Shift+L | Log pane / tree pane |
| Ctrl+K | Command palette |
| Ctrl+Z / Ctrl+Y | Undo / redo |
| Ctrl+, | Preferences |
| F5 | Refresh |
