--- views/about.lua — the About dialog and the Help menu's document list.
--
-- Public API: about.show(), about.docItems()

local dialog = require("ui.dialog")
local status = require("core.status")
local text = require("core.text")

local about = { name = "about" }

--- Show the About dialog.
function about.show()
    dialog.show({
        title = "GitGud Desktop " .. gitgud.version,
        message = "A moddable Git client for any Git server.\n\n"
            .. "Engine: libgit2 (C++17). Interface: CEGUI layouts (resources/layouts) and Lua "
            .. "scripts (resources/scripts) — edit them while the app runs and it reloads.\n\n"
            .. "See Help for the build, usage, and modding guides.",
        ok = "Close",
        cancel = false,
    })
end

--- One Help-menu item per file in the shipped docs/ folder.
-- @return item list (opens each document in the default app)
function about.docItems()
    local items = {}

    for _, doc in ipairs(gitgud.docs()) do
        local name = doc.name:gsub("%.md$", ""):gsub("_", " ")
        items[#items + 1] = {
            label = name:sub(1, 1):upper() .. name:sub(2):lower(),
            action = function()
                local ok, err = gitgud.openExternal(doc.path)
                status.report("Opened " .. doc.name .. ".", ok, err)
            end,
        }
    end

    if #items == 0 then
        items[1] = { label = "(no documents found)", enabled = false }
    end

    return items
end

return about
