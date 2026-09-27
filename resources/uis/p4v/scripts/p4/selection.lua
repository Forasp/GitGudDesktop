--- p4/selection.lua — what the user has selected, wherever they did it.
--
-- P4V's actions (Check Out, Diff, History, Revision Graph, ...) work on the
-- current selection, whether it was made in the depot tree, a table, or the
-- pending changelists. Views report their selection here; the toolbar,
-- menus, address bar, and status bar read it.
--
-- An item is { path = "src/a.cpp", folder = bool, revision = oid?,
-- change = changelist id?, shelf = branch?, source = "tree" | ... }.
-- Paths are repository-relative ("" = the root). The depot path shown to the
-- user is "//<repo>/<path>".

local app = require("core.app")
local repo = require("core.repo")

local selection = {}

local items = {}
local source = nil

--- Replace the selection.
-- @param from   which view it came from ("tree", "files", "pending", ...)
-- @param list   array of items
function selection.set(from, list)
    source = from
    items = list or {}
    app.publish("selection.changed", items, from)
end

--- The selected items.
-- @return array
function selection.items()
    return items
end

--- Which view made the selection.
-- @return source name or nil
function selection.source()
    return source
end

--- The first selected item.
-- @return item or nil
function selection.primary()
    return items[1]
end

--- The selected files' paths (folders left out).
-- @return array of paths
function selection.files()
    local out = {}
    for _, item in ipairs(items) do
        if not item.folder and item.path then
            out[#out + 1] = item.path
        end
    end

    return out
end

--- Every changed file under the selection (folders expand to the changed
-- files inside them).
-- @return array of paths
function selection.changedFiles()
    local out = {}
    local seen = {}
    for _, item in ipairs(items) do
        local prefix = item.path or ""
        for _, file in ipairs(repo.state().files) do
            local inside = file.path == prefix
                or (item.folder and (prefix == "" or file.path:sub(1, #prefix + 1) == prefix .. "/"))
            if inside and not seen[file.path] then
                seen[file.path] = true
                out[#out + 1] = file.path
            end
        end
    end

    return out
end

--- "//<repo>/<path>".
-- @param path  repository-relative path
-- @return depot path
function selection.depotPath(path)
    local name = repo.state().name ~= "" and repo.state().name or "depot"
    if not path or path == "" then
        return "//" .. name
    end

    return "//" .. name .. "/" .. path
end

--- Turn a typed depot path back into a repository path ("" = root), or nil
-- when it names another repository.
-- @param typed  "//repo/src", "src/a.cpp", "/src"
-- @return relative path or nil
function selection.fromDepotPath(typed)
    local path = typed:gsub("\\", "/"):gsub("^%s+", ""):gsub("%s+$", "")
    local name = repo.state().name
    local prefix = "//" .. name
    if path:sub(1, 2) == "//" then
        if path:lower() == prefix:lower() then
            return ""
        end
        if path:sub(1, #prefix + 1):lower() ~= (prefix .. "/"):lower() then
            return nil
        end
        path = path:sub(#prefix + 2)
    end
    path = path:gsub("^/+", ""):gsub("/+$", ""):gsub("/%.%.%.$", "")

    return path
end

return selection
