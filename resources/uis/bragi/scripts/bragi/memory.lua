--- bragi/memory.lua: Claude Code's instructions and memory,
-- the Instructions and memory section of Settings.
--
-- The same files Claude Code reads (gitgud.agentContextFiles): yours for
-- every project (CLAUDE.md and rules in its config folder), the open
-- repository's (CLAUDE.md, .claude/CLAUDE.md, CLAUDE.local.md, and
-- .claude/rules, in the folder and above), and its auto memory. Each opens
-- in the Settings editor (bragiSettings.edit); the main files can be made
-- when they don't exist yet. Changes take effect in the next session.
--
-- Public API: memory.cards() (for bragi/settings.lua), memory.files()

local repo = require("core.repo")

local memory = { name = "bragi.memory" }

local KIND = {
    user = "Yours, for every project",
    userRule = "Your rule, for every project",
    project = "This project's, shared with everyone who clones it",
    ["local"] = "Yours for this project, not committed",
    projectRule = "This project's rule",
    memory = "What Claude Code remembered here",
}

--- A path as short as it reads: the home folder as ~.
local function shortPath(path)
    local home = (os.getenv("USERPROFILE") or os.getenv("HOME") or ""):gsub("\\", "/")
    path = tostring(path):gsub("\\", "/")
    if home ~= "" and path:sub(1, #home):lower() == home:lower() then
        path = "~" .. path:sub(#home + 1)
    end
    return path
end

--- path relative to base, or nil when it isn't inside it.
local function relative(path, base)
    if not base or base == "" then
        return nil
    end
    path = tostring(path):gsub("\\", "/")
    base = tostring(base):gsub("\\", "/"):gsub("/+$", "") .. "/"
    if path:sub(1, #base):lower() == base:lower() then
        return path:sub(#base + 1)
    end
    return nil
end

local function join(dir, name)
    dir = tostring(dir):gsub("[/\\]+$", "")
    return dir .. "/" .. name
end

--- The open repository's files and yours, as Claude Code finds them.
function memory.files()
    local path = repo.state().path
    return gitgud.agentContextFiles(path ~= "" and path or nil)
end

local function edit(path, title)
    require("bragi.settings").edit({ title = title, path = path })
end

local function fileRow(file)
    local name = file.kind == "memory" and file.path:match("[^/\\]+$")
        or relative(file.path, repo.state().path) or relative(file.path, gitgud.agentConfigDir())
        or shortPath(file.path)
    return {
        kind = "action",
        title = name,
        -- Auto memory's folder name is long and says nothing: kind only.
        sub = (KIND[file.kind] or file.kind) .. (file.kind == "memory" and "." or (": " .. shortPath(file.path))),
        button = "Edit",
        run = function()
            edit(file.path, shortPath(file.path))
        end,
    }
end

local function createRow(path, title, sub)
    return {
        kind = "action",
        title = title,
        sub = sub,
        button = "Create",
        run = function()
            edit(path, shortPath(path))
        end,
    }
end

--- The section's cards, built from the files on disk.
function memory.cards()
    local files = memory.files()
    local mine, project, remembered = {}, {}, {}
    local have = {}
    for _, file in ipairs(files) do
        have[file.path:gsub("\\", "/"):lower()] = true
        if file.kind == "user" or file.kind == "userRule" then
            mine[#mine + 1] = fileRow(file)
        elseif file.kind == "memory" then
            remembered[#remembered + 1] = fileRow(file)
        elseif file.kind ~= "settings" then
            project[#project + 1] = fileRow(file)
        end
    end
    local function missing(path)
        return not have[path:gsub("\\", "/"):lower()]
    end

    local userFile = join(gitgud.agentConfigDir(), "CLAUDE.md")
    if missing(userFile) then
        table.insert(mine, 1, createRow(userFile, "Your CLAUDE.md",
            "Instructions for every project, in " .. shortPath(userFile) .. "."))
    end

    local state = repo.state()
    if state.open then
        local shared = join(state.path, "CLAUDE.md")
        local dotted = join(state.path, ".claude/CLAUDE.md")
        if missing(shared) and missing(dotted) then
            project[#project + 1] = createRow(shared, "CLAUDE.md for " .. state.name,
                "Instructions for this project, committed with it.")
        end
        local mineHere = join(state.path, "CLAUDE.local.md")
        if missing(mineHere) then
            project[#project + 1] = createRow(mineHere, "CLAUDE.local.md for " .. state.name,
                "Your own notes for this project; add it to .gitignore.")
        end
    else
        project[#project + 1] = { kind = "info", title = "No repository open",
            sub = "Open one in the Repo view to see its instructions and memory." }
    end
    if #remembered == 0 then
        remembered[1] = { kind = "info", title = "Nothing yet",
            sub = state.open and "Claude Code writes here as it learns about this project."
                or "Open a repository to see what Claude Code remembered there." }
    end

    return {
        { heading = state.open and ("This project: " .. state.name) or "This project", rows = project },
        { heading = "You, every project", rows = mine },
        { heading = "Auto memory", rows = remembered },
    }
end

function memory.init()
end

function memory.refresh()
end

return memory
