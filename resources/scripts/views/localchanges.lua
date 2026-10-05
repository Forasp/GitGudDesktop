--- views/localchanges.lua: when a switch, merge, or pull stops because it
-- would overwrite uncommitted changes: say which files are in the way and
-- offer to stash them and carry on.
--
-- gitgud.checkout / merge / squashMerge return (nil, message, paths) in that
-- case, and a pull finishes with "blocked|" and the paths, one per line.
--
--   localchanges.offer(what, paths, continue)
--     what      the stopped operation, for the text ("Pulling from origin")
--     paths     the files in the way
--     continue  function() that runs the operation again once the changes
--               are stashed

local dialog = require("ui.dialog")
local repo = require("core.repo")
local text = require("core.text")

local localchanges = {}

local MAX_LISTED = 8

--- The paths as an indented list, the overflow counted.
-- @param paths  file paths
-- @return text
local function listing(paths)
    local lines = {}
    for i = 1, math.min(#paths, MAX_LISTED) do
        lines[#lines + 1] = "    " .. paths[i]
    end
    if #paths > MAX_LISTED then
        lines[#lines + 1] = "    and " .. text.plural(#paths - MAX_LISTED, "more file")
    end
    return table.concat(lines, "\n")
end

--- Offer to stash the changes in the way and run the operation again.
-- @param what      the stopped operation, e.g. "Switching to main"
-- @param paths     the files in the way
-- @param continue  function() run after stashing
function localchanges.offer(what, paths, continue)
    local branch = repo.state().branch
    dialog.show({
        title = "Your changes would be overwritten",
        message = what .. " would overwrite uncommitted changes to "
            .. (#paths == 1 and "this file:" or "these files:") .. "\n"
            .. listing(paths) .. "\n\n"
            .. "Stash your changes and continue? They're kept in a stash on "
            .. (branch ~= "" and branch or "this branch") .. " until you restore them.",
        ok = "Stash and continue",
        onOk = function()
            if not require("views.stash").stashAll() then
                return false, "Couldn't stash your changes."
            end
            continue()
            return true
        end,
    })
end

return localchanges
