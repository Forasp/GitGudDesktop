--- tests/ui/p4.lua: the GitGud UI on a Perforce workspace, through the
-- real UI.
--
-- Run it in a workspace made by make-p4workspace.ps1 (gitgud.exe <dir>\ws)
-- with GITGUD_UI=default, a scratch APPDATA, the P4TICKETS/P4TRUST/P4ENVIRO
-- and GITGUD_P4 variables that script prints, GITGUD_SCRIPT pointing here,
-- and GITGUD_SHOTS for screenshots. It checks the backend, the Changes list,
-- staging (opening) a file, submitting, history, branches, and the
-- Git-only commands being disabled. Prints "[check] ..." lines for the log.

local OUT = os.getenv("GITGUD_SHOTS") or "."

local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

local function shot(name)
    gitgud.screenshot(OUT .. "/" .. name .. ".png")
end

local function find(list, path)
    for _, e in ipairs(list or {}) do
        if e.path == path then
            return e
        end
    end
    return nil
end

local steps = {
    function()
        check("backend is p4", gitgud.backend() == "p4")
        check("p4 is available", gitgud.p4Available())
        check("current branch is the stream", gitgud.currentBranch() == "main")
        local status = gitgud.status()
        local readme = find(status, "README.md")
        local notes = find(status, "notes.txt")
        check("edited file listed as modified", readme ~= nil and readme.code == "M")
        check("new file listed as untracked", notes ~= nil and notes.code == "?")
        check("line staging is off", not gitgud.supports("lineStaging"))
        check("push is off", not gitgud.supports("push"))
        check("changelists are on", gitgud.supports("changelists"))
        shot("p4-changes")
    end,
    function()
        local ok, err = gitgud.stage({ "README.md", "notes.txt" })
        check("stage opens the files (" .. tostring(err) .. ")", ok == true)
        local opened = 0
        for _, cl in ipairs(gitgud.p4Changes() or {}) do
            opened = opened + #cl.files
        end
        check("two files open in changelists", opened == 2)
    end,
    function()
        local change, err = gitgud.commit("Edit the readme from the UI test")
        check("commit submits (" .. tostring(err) .. ")", change ~= nil and change:match("^%d+$") ~= nil)
        check("nothing left to commit", #gitgud.status() == 0)
        local history = gitgud.history(10)
        check("history shows the submit", history[1] and history[1].summary == "Edit the readme from the UI test")
        shot("p4-history")
    end,
    function()
        local names = {}
        for _, b in ipairs(gitgud.branches() or {}) do
            names[b.name] = true
        end
        check("streams are branches", names.main and names.dev)
        local tags = gitgud.tags() or {}
        check("labels are tags", tags[1] and tags[1].name == "v1")
        local info = gitgud.p4Info()
        check("p4Info knows the user", info and info.userName == "tim")
    end,
    function()
        gitgud.emit("window.close", "")
    end,
}

local function run(i)
    if not steps[i] then
        return
    end
    gitgud.after(i == 1 and 2500 or 800, function()
        local ok, err = pcall(steps[i])
        if not ok then
            check("step " .. i .. " ran without errors: " .. tostring(err), false)
        end
        run(i + 1)
    end)
end

run(1)
