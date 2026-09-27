--- core/undo.lua — Undo / Redo for repository actions (Ctrl+Z / Ctrl+Shift+Z).
--
-- Every action that moves branches goes through undo.track(label, fn):
-- the positions of HEAD and every local branch are noted before and after,
-- and if anything moved, the pair becomes one undo step. Undoing puts the
-- branches (and the checked-out branch) back where they were; redoing
-- moves them forward again. This covers commits, amends, checkouts,
-- merges, rebases, resets, reverts, cherry-picks, and creating, deleting,
-- or renaming branches — without guessing from the reflog.
--
-- Safety rules (docs/PRINCIPLES.md, "never lose work silently"):
--   * a step only undoes while the branches are still exactly as that step
--     left them; if something else moved them, it says so and does nothing
--   * branch moves use a SAFE checkout, which refuses rather than overwrite
--     uncommitted changes
--   * commits undo "softly": their changes come back as staged changes
--
-- Stacks are kept per repository (in memory; they don't survive a restart).
--
--     local undo = require("core.undo")
--     undo.track("Commit", function() return gitgud.commit(message) end,
--                { soft = true })
--
-- Signal: app.publish("undo.changed") whenever the stacks change.

local app = require("core.app")

local undo = {}

local LIMIT = 50

local stacks = {}   -- repository path -> { done = {}, undone = {} }

--- The stacks of the open repository.
-- @return { done, undone } (created on demand)
local function current()
    local path = gitgud.repoPath()
    if not stacks[path] then
        stacks[path] = { done = {}, undone = {} }
    end

    return stacks[path]
end

--- Where HEAD and every local branch point right now.
-- @return snapshot { branch, head, branches = { name = oid } }
function undo.snapshot()
    local snap = {
        branch = gitgud.currentBranch(),
        head = gitgud.headOid(),
        branches = {},
    }

    for _, branch in ipairs(gitgud.branches()) do
        if not branch.isRemote then
            snap.branches[branch.name] = branch.oid
        end
    end

    return snap
end

--- Are two snapshots the same?
-- @param a  snapshot
-- @param b  snapshot
-- @return boolean
local function same(a, b)
    if a.branch ~= b.branch or a.head ~= b.head then
        return false
    end
    for name, oid in pairs(a.branches) do
        if b.branches[name] ~= oid then
            return false
        end
    end
    for name, _ in pairs(b.branches) do
        if a.branches[name] == nil then
            return false
        end
    end

    return true
end

--- Run an action and record it as one undo step if it moved anything.
-- @param label  what it was, for menus and tooltips ("Commit", "Merge main")
-- @param fn     function() doing the action; its return values pass through
-- @param opts   optional { soft = true } for commits: undo keeps the
--               changes staged instead of moving the working tree;
--               onUndo / onRedo: functions run after undoing / redoing
-- @return whatever fn returned
function undo.track(label, fn, opts)
    if not gitgud.isOpen() then
        return fn()
    end

    local before = undo.snapshot()
    local results = table.pack(fn())
    local after = undo.snapshot()

    if not same(before, after) then
        local stack = current()
        stack.done[#stack.done + 1] = {
            label = label,
            before = before,
            after = after,
            soft = opts and opts.soft or false,
            onUndo = opts and opts.onUndo,
            onRedo = opts and opts.onRedo,
        }
        if #stack.done > LIMIT then
            table.remove(stack.done, 1)
        end
        stack.undone = {}
        app.publish("undo.changed")
    end

    return table.unpack(results, 1, results.n)
end

--- Move the repository from state `from` to state `to`.
-- @param from  snapshot we expect to be in
-- @param to    snapshot to restore
-- @param soft  true: move only HEAD's branch, keeping the index (commits)
-- @return true, or nil and a message
local function restore(from, to, soft)
    local ok = true
    local err = nil

    if soft and from.branch == to.branch and to.head ~= "" then
        return gitgud.resetTo(to.head, "soft")
    end
    if soft and to.head == "" then
        return nil, "Can't undo the very first commit this way; use Edit > Undo last commit."
    end

    -- HEAD first, so a branch we're about to delete isn't checked out.
    if to.branch ~= "" and to.branch ~= from.branch then
        local target = to.branches[to.branch]
        if target and from.branches[to.branch] ~= target then
            ok, err = gitgud.setBranchTarget(to.branch, target)
            if not ok then
                return nil, err
            end
        end
        ok, err = gitgud.checkout(to.branch)
        if not ok then
            return nil, err
        end
    elseif to.branch == "" and to.head ~= "" and (from.branch ~= "" or from.head ~= to.head) then
        ok, err = gitgud.checkoutCommit(to.head)
        if not ok then
            return nil, err
        end
    elseif to.branch ~= "" and to.branch == from.branch and from.head ~= to.head then
        ok, err = gitgud.setBranchTarget(to.branch, to.head)
        if not ok then
            return nil, err
        end
    end

    -- Then every other branch: move, recreate, or delete.
    for name, oid in pairs(to.branches) do
        if name ~= to.branch and from.branches[name] ~= oid then
            ok, err = gitgud.setBranchTarget(name, oid)
            if not ok then
                return nil, err
            end
        end
    end
    for name, _ in pairs(from.branches) do
        if to.branches[name] == nil and name ~= to.branch then
            ok, err = gitgud.deleteBranch(name)
            if not ok then
                return nil, err
            end
        end
    end

    return true
end

--- The step Undo would reverse, or nil.
-- @return step { label, ... }
function undo.peekUndo()
    if not gitgud.isOpen() then
        return nil
    end
    local stack = current()

    return stack.done[#stack.done]
end

--- The step Redo would repeat, or nil.
-- @return step { label, ... }
function undo.peekRedo()
    if not gitgud.isOpen() then
        return nil
    end
    local stack = current()

    return stack.undone[#stack.undone]
end

--- Reverse the most recent step.
-- @return true | nil, message
function undo.undo()
    local step = undo.peekUndo()
    if not step then
        return nil, "Nothing to undo."
    end
    if not same(undo.snapshot(), step.after) then
        return nil, "Can't undo \"" .. step.label .. "\": the branches have changed since. "
            .. "Undo is only possible right after an action."
    end

    local ok, err = restore(step.after, step.before, step.soft)
    if not ok then
        return nil, err
    end

    local stack = current()
    table.remove(stack.done)
    stack.undone[#stack.undone + 1] = step
    if step.onUndo then
        step.onUndo()
    end
    app.publish("undo.changed")

    return true
end

--- Repeat the most recently undone step.
-- @return true | nil, message
function undo.redo()
    local step = undo.peekRedo()
    if not step then
        return nil, "Nothing to redo."
    end
    if not same(undo.snapshot(), step.before) then
        return nil, "Can't redo \"" .. step.label .. "\": the branches have changed since."
    end

    local ok, err = restore(step.before, step.after, step.soft)
    if not ok then
        return nil, err
    end

    local stack = current()
    table.remove(stack.undone)
    stack.done[#stack.done + 1] = step
    if step.onRedo then
        step.onRedo()
    end
    app.publish("undo.changed")

    return true
end

--- Forget the history of the open repository (e.g. after a hot reload).
function undo.clear()
    stacks[gitgud.repoPath()] = nil
    app.publish("undo.changed")
end

return undo
