--- tests/ui/remotes.lua — several remotes through the real UI.
--
-- Same harness as features.lua (GITGUD_SCRIPT and GITGUD_SHOTS; run it in a
-- repository made by make-testrepo.ps1, whose main tracks a local bare
-- origin). Adds a second local bare remote next to it and covers: the Add
-- remote dialog, fetching every remote, pushing to a remote without and with
-- tracking it, tracking a remote branch, the publish-to chooser, renaming and
-- removing a remote. Prints "[check] ..." lines that the log can be grepped for.

local repo = require("core.repo")

local OUT = os.getenv("GITGUD_SHOTS") or "."
local steps = {}
local marks = {}

--- Queue a step.
-- @param delay  milliseconds to wait before running it
-- @param label  name for the log
-- @param fn     function() doing the step
local function step(delay, label, fn)
    steps[#steps + 1] = { delay = delay, label = label, fn = fn }
end

--- Save a screenshot of the next frame.
-- @param name  file name without extension
local function shot(name)
    gitgud.screenshot(OUT .. "/" .. name .. ".png")
end

--- Log a pass/fail line.
-- @param label  what was checked
-- @param ok     result
local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

--- Click the middle of a widget.
-- @param name  widget
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end

--- Does a remote-tracking branch exist?
-- @param name  e.g. "second/main"
-- @return boolean
local function hasRemoteBranch(name)
    for _, branch in ipairs(gitgud.branches()) do
        if branch.isRemote and branch.name == name then
            return true
        end
    end

    return false
end

--- Run git with arguments (blocking).
-- @param args  array of arguments after "git"
-- @return the runProgram result
local function git(args)
    local command = { gitgud.findProgram("git") }
    for _, a in ipairs(args) do
        command[#command + 1] = a
    end
    return gitgud.runProgram(command, repo.state().path)
end

--- Run step i, then schedule the next.
-- @param i  step index
local function run(i)
    local s = steps[i]
    if not s then
        print("[ui-test] finished")
        gitgud.emit("window.close", "")
        return
    end

    gitgud.after(s.delay, function()
        print("[ui-test] " .. i .. ": " .. s.label)
        local ok, err = pcall(s.fn)
        if not ok then
            print("[ui-test] step " .. i .. " failed: " .. tostring(err))
            check("step " .. i .. " ran without errors", false)
        end
        run(i + 1)
    end)
end

-- ---------------------------------------------------------------- steps --

step(1200, "start: one remote, main tracks origin", function()
    local state = repo.state()
    marks.branch = state.branch
    check("starts with only origin", #state.remotes == 1 and state.remotes[1].name == "origin")
    check("main tracks origin", state.aheadBehind.upstreamRemote == "origin")

    marks.second = state.path .. "-second.git"
    gitgud.runProgram({ "cmd", "/c", "rmdir", "/s", "/q", marks.second }, state.path)
    local result = git({ "init", "--bare", marks.second })
    check("made a second bare repository", result ~= nil and result.code == 0)
end)

step(400, "open Add remote", function()
    require("views.remotes").add()
end)

step(600, "fill in the dialog", function()
    check("Add remote dialog is open", gitgud.getProperty("Dialog", "Visible") == "true")
    gitgud.setText("DialogField1", "second")
    gitgud.setText("DialogField2", marks.second)
    shot("r01-add-remote")
end)

step(400, "add it", function()
    clickWidget("DialogOkButton")
end)

step(1500, "added and fetched", function()
    check("dialog closed", gitgud.getProperty("Dialog", "Visible") == "false")
    check("second is listed", repo.remote("second") ~= nil)
    check("the fetch finished", require("views.sync").busy() == nil)
    check("the toolbar says fetch all", gitgud.getText("SyncLabel") == "FETCH ALL")
    shot("r02-two-remotes")
end)

step(300, "fetch every remote", function()
    require("views.sync").fetch()
end)

step(1500, "fetched all", function()
    check("fetch all finished", require("views.sync").busy() == nil)
    check("origin's branches are still there", hasRemoteBranch("origin/" .. marks.branch))
end)

step(300, "push main to second without tracking it", function()
    require("views.sync").pushTo("second", false)
end)

step(1500, "pushed to second", function()
    check("second/main exists", hasRemoteBranch("second/" .. marks.branch))
    check("main still tracks origin", repo.state().aheadBehind.upstreamRemote == "origin")
end)

step(300, "push to second and track it", function()
    require("views.sync").pushTo("second", true)
end)

step(1500, "tracking second", function()
    local ab = repo.state().aheadBehind
    check("main now tracks second", ab.upstreamRemote == "second" and ab.upstream == "second/" .. marks.branch)
    check("push and pull now go to second", repo.upstreamRemote() == "second")
end)

step(300, "track origin again from the branch menu", function()
    local items = nil
    for _, branch in ipairs(gitgud.branches()) do
        if branch.isRemote and branch.name == "origin/" .. marks.branch then
            items = require("views.branches").branchMenu(branch)
        end
    end
    local tracked = false
    for _, item in ipairs(items or {}) do
        if item.label == "Track from " .. marks.branch then
            item.action()
            tracked = true
        end
    end
    check("remote branch menu offers Track from", tracked)
end)

step(600, "back on origin", function()
    check("main tracks origin again", repo.state().aheadBehind.upstreamRemote == "origin")
end)

step(300, "publish a new branch: pick a remote", function()
    local ok = gitgud.createBranch("multi-pub")
    ok = ok and gitgud.checkout("multi-pub")
    check("made branch multi-pub", ok == true)
    require("core.app").requestRefresh()
end)

step(600, "open the chooser", function()
    check("multi-pub has no upstream", not repo.state().aheadBehind.hasUpstream)
    check("toolbar asks to choose", gitgud.getText("SyncValue") == "Choose a remote")
    require("views.sync").push()
end)

step(600, "chooser shown", function()
    check("the remote chooser is open", gitgud.getProperty("MenuPanel", "Visible") == "true")
    check("nothing was pushed yet", not hasRemoteBranch("origin/multi-pub") and not hasRemoteBranch("second/multi-pub"))
    shot("r03-publish-chooser")
end)

step(300, "pick second", function()
    -- Items: heading, origin, second.
    clickWidget("MenuItem3")
end)

step(1500, "published to second", function()
    check("multi-pub went to second", hasRemoteBranch("second/multi-pub"))
    check("multi-pub tracks second", repo.state().aheadBehind.upstreamRemote == "second")
    gitgud.checkout(marks.branch)
    require("core.app").requestRefresh()
end)

step(600, "rename second to mirror", function()
    require("views.remotes").edit("second")
end)

step(600, "edit dialog", function()
    check("Edit remote dialog is open", gitgud.getProperty("Dialog", "Visible") == "true")
    check("it shows the URL", gitgud.getText("DialogField2") == marks.second)
    gitgud.setText("DialogField1", "mirror")
    clickWidget("DialogOkButton")
end)

step(900, "renamed", function()
    check("second is now mirror", repo.remote("mirror") ~= nil and repo.remote("second") == nil)
    check("its branches moved", hasRemoteBranch("mirror/multi-pub") and not hasRemoteBranch("second/multi-pub"))
    local tracking = nil
    for _, branch in ipairs(gitgud.branches()) do
        if branch.name == "multi-pub" then
            tracking = branch.upstream
        end
    end
    check("multi-pub follows the rename", tracking == "mirror/multi-pub")
end)

step(300, "remove mirror", function()
    require("views.remotes").remove("mirror")
end)

step(600, "confirm", function()
    check("remove asks first", gitgud.getProperty("Dialog", "Visible") == "true")
    clickWidget("DialogOkButton")
end)

step(900, "removed", function()
    check("mirror is gone", repo.remote("mirror") == nil and not hasRemoteBranch("mirror/multi-pub"))
    check("main still tracks origin", repo.state().aheadBehind.upstreamRemote == "origin")
    check("toolbar is back to one remote", gitgud.getText("SyncLabel"):find("ORIGIN", 1, true) ~= nil)
    shot("r04-one-remote-again")
    gitgud.deleteBranch("multi-pub")
    gitgud.runProgram({ "cmd", "/c", "rmdir", "/s", "/q", marks.second }, repo.state().path)
end)

run(1)
