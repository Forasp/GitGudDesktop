# Using GitGud Desktop

GitGud works like GitHub Desktop, against any Git server. This is the tour.

## The window

- **Title bar** — File, Edit, View, Repository, Branch, and Help menus.
- **Toolbar** — *Current repository* (switch or add), *Current branch*
  (switch, create, merge, rebase), and the sync button, which fetches — or
  pulls when you're behind, pushes when you're ahead, and publishes a new
  branch. On the right: **Undo** / **Redo**, **Graph**, **Console**, and
  **Commands** (the command palette).
- **Repository tabs** — appear under the toolbar once two or more
  repositories are open.
- **Branch tree** — the column on the far left: branches, remotes, tags,
  stashes, submodules, and worktrees (View ▸ Branch tree, Ctrl+Shift+L).
- **Sidebar** — the *Changes* and *History* tabs.
- **Content pane** — the diff of whatever is selected.
- **Banner** — appears during a merge, rebase, cherry-pick or revert, or on a
  detached HEAD, with buttons to continue, open the merge tool, or abort.
- **Console** — docked along the bottom when open (Ctrl+J).

## Repositories

*Current repository ▾* lists every repository you've opened (filter by
typing). **Add** clones, creates (optionally with a README and a starter
`.gitignore`), or adds an existing folder — or just drop a folder onto the
window. Right-click a repository to reveal it, open a terminal, open it in
your editor, or remove it from the list (the folder isn't touched).
*Repository settings…* edits the `origin` URL, a per-repository name/email,
and `.gitignore`.

## The command palette

**Ctrl+K** (or F1, or the *Commands* button) opens one search box over
everything: every menu command, "Check out …" for each branch, "Open …" for
each repository in your list, and "Show …" for each changed file. Type a few
letters in order (`cgr` finds *Commit graph*), move with ↑/↓, press Enter.
With an empty box, the commands you used last come first.

## Undo and redo

**Ctrl+Z** undoes the last thing you did to your branches — a commit, amend,
checkout, merge, rebase (including an interactive one), reset, revert,
cherry-pick, or creating, renaming, or deleting a branch — and **Ctrl+Shift+Z**
(or Ctrl+Y) redoes it. The toolbar buttons say what they'd undo. Undoing a
commit keeps its changes staged and puts its message back in the box.

Undo only works right after an action: if the branches moved since (say, you
committed from the command line), it says so and does nothing. It never
overwrites uncommitted changes — if they're in the way, it refuses. Plain
Ctrl+Z inside a text box still edits the text.

## Repository tabs

Right-click a repository in the *Current repository* list and choose *Open in
a new tab* (or click **+** on the tab strip) to keep several repositories
open. Each tab remembers whether it was on Changes, History, or the graph.
Ctrl+Tab / Ctrl+Shift+Tab switch tabs, Ctrl+W closes one. Your tabs come
back next time.

## Making a commit

1. The Changes tab lists every changed file with its status (A added, M
   modified, D deleted, R renamed, U conflicted). Type in the filter box to
   narrow it down.
2. **The checkbox decides what's included.** Click a file's box (or the
   column it sits in) to include the whole file; "N changed files" toggles
   everything.
3. **Include parts of a file** in the diff: click a changed row to include or
   exclude it (in split view a row with a removed and an added line toggles
   both; unified view toggles single lines). Each block of changed lines has
   a small box (in the split view's middle column, or at the start of the
   block in unified view) that includes or excludes that block; the big box
   on a hunk's `@@` header does the whole hunk. Included lines get a solid coloured line number. A dash in a file's
   box means it's partly included.
4. Write a summary (the counter warns past 50 characters) and an optional
   description. **+ Co-author** adds a `Co-authored-by:` trailer.
5. **Commit** (Ctrl+Enter). Tick *Amend last commit* to fold the changes into
   the previous commit instead — the message box fills with the old message.

Right after committing, **Undo** puts the commit back as staged changes with
its message in the box.

Right-click a file to discard its changes (new files go to the Recycle Bin),
ignore it or its whole extension, see its **history** or **blame**, track its
kind of file with Git LFS, copy its path, reveal it, or open it.
Double-click opens it in your editor. *Discard all changes* is in the Edit
menu.

If you sign commits (*File ▸ Commit signing…*), every commit GitGud makes is
signed — with gpg, or with an SSH key.

## Diffs

- **View ▾** switches between split and unified diffs and can hide
  whitespace-only changes.
- **Changed words** inside a modified line are highlighted more strongly than
  the rest of the line (View ▸ Highlight changed words turns it off).
- Files stored with **Git LFS** show "Git LFS file" with the old and new
  sizes instead of the pointer text.
- **Images** (png, jpg, gif, bmp, tga, psd, …) show as pictures: **2-up**
  (before and after), **Difference** (changed pixels in neon pink over a
  dimmed copy), or **Onion skin** (both blended), with sizes and the share
  of pixels changed.
- Very large diffs wait behind a *Show the diff* button.

## History

The History tab lists commits with their branch and tag labels. Select one
to see its message, author, and files; pick a file to see its diff. Filter by
message, author, or SHA; *Load more commits* pages back further.

**Compare with a branch…** shows the commits the other branch has that you
don't (*behind*) or the reverse (*ahead*), and offers *Merge into current
branch*.

Right-click a commit to **revert** it, **cherry-pick** it onto your branch,
**create a branch** or **tag** from it (delete tags there too), **reset** your
branch to it (later commits' changes stay as uncommitted changes), **check it
out** (detached HEAD), start an **interactive rebase** from it, or copy its SHA
or summary. Right-click a file in a commit for its history or blame as of
that commit.

## The commit graph

**View ▸ Commit graph** (Ctrl+3, or the *Graph* button) shows every branch's
history at once as coloured lanes, with branch and tag labels in their
lane's colour; your checked-out branch has a ✓ and HEAD's dot a ring.
Remote branches and tags can be hidden with the two checkboxes. The
selected commit's details and diff show underneath, just like in History,
and the right-click menu is the same. If you have uncommitted changes, the
top row is **// WIP** with +added ~modified −deleted counts; click it to go
to Changes. Type in the find box to dim the commits that don't match (Enter
jumps to the next match); ↑/↓ move through commits. Double-click a commit with
a branch label to check that branch out. *Close graph* (or Ctrl+3 again)
returns to Changes / History.

## File history and blame

Right-click a file (in Changes or in a commit) and choose **Show file
history**: every commit that changed it on the left, and what that commit did
to it on the right. **Blame** shows the file with who last changed each line,
in which commit, and how long ago — newer changes are brighter; lines you
haven't committed say so. Click a line to see its commit in the status bar,
double-click to open it in the graph; right-click for *Blame as of this
commit* / *before this commit*. Escape closes the view.

## Branches

*Current branch ▾* lists the default branch, your most recent branches, the
rest, and remote-only branches. Click one to switch; if uncommitted changes
would be overwritten, GitGud offers to stash them first. **New branch**
branches from the current one (your changes come along).

*Merge into current…* and *Rebase current…* switch the list into a pick-a-
branch mode. Right-click any branch to merge, squash-and-merge, rebase onto
it, compare, rename, delete (optionally on the remote too), show it in the
graph, or copy its name. The Branch menu also has *Update from default
branch*.

### The branch tree

The left column lists local branches (✓ the current one, ↑↓ against its
upstream), remote branches grouped by remote, tags, stashes, and — when the
repository has them — submodules and worktrees. Click a section title to
fold it; type in the box to filter. Click a branch or tag to find its commit
in the graph; double-click a branch to check it out. Right-click anything for
its actions (tags: check out, branch from, delete, push; stashes: view,
apply, pop, delete; submodules: clone / update, open; worktrees: open,
remove).

**Drag a branch onto another** to merge or rebase: drop onto your current
branch to merge the dragged one into it; drag your current branch onto
another to rebase onto it (or merge that one in); any other pair offers to
check out the target first.

### Interactive rebase

Right-click a commit and choose **Interactive rebase from here…** (or
*Branch ▸ Interactive rebase…*, Ctrl+Alt+I, for your last N commits). Every
newer commit on your branch is listed, newest at the top. For each, choose
**Pick** (keep), **Reword** (edit the message below — typing a new message
does this for you), **Squash** (fold into the commit below it, joining the
messages), **Fixup** (fold in, keeping only the message below), or **Drop**.
Reorder by dragging rows, with the arrow buttons, or Alt+↑/↓. Nothing
changes until **Rewrite history**: the new commits are built first, so if a
reordering doesn't apply cleanly you get an explanation and your branch is
untouched. The rewrite is one Undo step. If the branch was already pushed,
force push afterwards.

### Worktrees and submodules

*Repository ▸ Add worktree…* checks a branch out into a second folder, so
you can work on two branches without stashing; it opens in a new tab.
Submodules show whether they're cloned and at the commit their parent
records; *Update* clones or updates them.

## Conflicts

When a merge, pull, rebase, revert, or cherry-pick conflicts, the banner
shows how many files are conflicted and the files appear with a red **U**.
Click one (or *Open merge tool* in the banner) to open the **merge tool**:

- top left, **mine** (your branch); top right, **theirs** (incoming); below,
  the **result**. Everything both sides agree on is already merged.
- For each conflict, **click the block you want** on either side — click both
  to keep both (in the order you clicked), click again to drop one. The ↑ / ↓
  buttons jump between conflicts; *All mine* / *All theirs* decide everything at once.
- **Edit result** turns the bottom pane into an editor for anything the
  sides don't cover.
- **Save and mark resolved** writes the file and stages it.

Binary files and "changed on one side, deleted on the other" offer keeping
one side instead. You can still right-click a file for *Resolve using mine* /
*theirs*, or fix it in your editor and choose *Mark as resolved*. When all
files are resolved, commit (or *Continue rebase*). *Abort* in the banner puts
everything back.

## Stashing

*Repository ▸ Stash all changes* saves everything, untracked files included,
for the current branch. A *Stashed changes* row then appears above the
commit box; **View** shows what's in it, with **Restore** and **Discard**.

## Syncing and signing in

The sync button (or Repository ▸ Push / Pull / Fetch all) pushes and pulls
the current branch through the remote its upstream lives on, and fetches
every remote. A branch that isn't published yet goes to `origin`; when the
repository has several remotes, GitGud asks which one (and tracks it from
then on). GitGud fetches in the background every 15 minutes. *Force push…*
overwrites the remote branch after you've rewritten history; *Push tags*
publishes tags.

**Several remotes** (a fork and its parent, a mirror, a second host): the
branch tree's REMOTE section lists every remote, marking the one the current
branch tracks. Right-click the section for *Add remote…*, or a remote to
fetch it, pull from it, push to it (optionally tracking it from then on),
push tags to it, edit its name or URL, or remove it. *Repository ▸ Push to…*
and *Pull from…* pick a remote for one operation. Right-click a remote branch
and choose *Track from …* to make the current branch follow it; right-click
a local branch to stop tracking. Renaming a remote or changing its URL keeps
its branches and everything that tracks it. When a server wants credentials you haven't saved, GitGud asks for a
username and password (use an access token for hosted services) and stores
them in the Windows Credential Manager.

**SSH remotes** (`git@host:owner/repo.git`) use your SSH agent, then your
keys in `~/.ssh`. *File ▸ SSH keys…* lists them, copies a public key to paste
into your Git host, and generates a new one. The first time you connect to a
server GitGud shows its host key fingerprint and asks whether to trust it;
if a known server's key ever *changes*, it refuses and warns you. A key's
passphrase is asked for once and kept in the Credential Manager.

**Git LFS**: with git-lfs installed (it comes with Git for Windows), files
your `.gitattributes` sends to LFS are stored as pointers when you commit and
downloaded when you check out, like the command line does. *Repository ▸ Git
LFS* tracks new patterns, pulls LFS files, and shows `git lfs status`. When
you push, GitGud uploads the LFS files first.

## The console

**View ▸ Console** (Ctrl+J) opens a command line docked at the bottom. Type a
command and press Enter: it runs in the repository's folder and its output
streams in. ↑/↓ recall earlier commands, **Stop** cancels the running one,
`cls` clears. Commands can't ask for input (there's no terminal behind them);
for interactive tools use *Repository ▸ Open in terminal*.

## Options

*File ▸ Options…* (Ctrl+,): your commit name and email and the default
branch name (global Git config), the commands for your editor and terminal
(`%s` is replaced by the path), and whether to confirm discards and force
pushes and to fetch in the background. *File ▸ SSH keys…* and *File ▸
Commit signing…* set up SSH and signed commits.

## Keyboard shortcuts

| | |
|---|---|
| Ctrl+1 / Ctrl+2 / Ctrl+3 | Changes / History / Commit graph |
| Ctrl+K or F1 | Command palette |
| Ctrl+Z / Ctrl+Shift+Z (Ctrl+Y) | Undo / redo |
| Ctrl+J | Console |
| Ctrl+Shift+L | Branch tree |
| Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+W | Next / previous / close repository tab |
| Ctrl+Alt+I | Interactive rebase |
| Ctrl+T / Ctrl+B | Repository list / Branch list |
| Ctrl+Enter | Commit |
| Ctrl+F | Filter changed files |
| Ctrl+Shift+A | Include all changes |
| Ctrl+Shift+Backspace | Discard all changes |
| Ctrl+P / Ctrl+Shift+P / Ctrl+Shift+T | Push / Pull / Fetch |
| Ctrl+Shift+S | Stash all changes |
| Ctrl+Shift+N / R / D | New / rename / delete branch |
| Ctrl+Shift+U | Update from default branch |
| Ctrl+Shift+B | Compare to branch |
| Ctrl+Shift+M / H / I | Merge / squash-merge / rebase |
| Ctrl+N / Ctrl+O / Ctrl+Shift+O | New / add / clone repository |
| Ctrl+Shift+F / Ctrl+Shift+E / Ctrl+\` | Show in Explorer / editor / terminal |
| Ctrl+, | Options |
| F5 | Refresh |
| F11 | Maximize / restore |
| Escape | Close the open popup or dialog |
