--- ui/commands.lua — the command palette (Ctrl+K or F1).
--
-- One search box over everything the app can do:
--   * every menu command (with its shortcut), so nothing is only a menu away
--   * commands modules register here (commands.register)
--   * whatever the UI's candidate sources add when the palette opens
--     (commands.addSource) — the default UI adds "Check out <branch>",
--     "Open <repository>", and "Show <file>" (views/menus.lua)
-- Matching is fuzzy (the letters in order, not necessarily together); word
-- starts and runs of letters rank higher. With an empty box, recently run
-- commands come first.
--
-- Mods add their own entries:
--     local commands = require("ui.commands")
--     commands.register({ label = "Count lines", action = fn, keywords = "stats" })
--
-- A source adds live entries every time the palette opens:
--     commands.addSource(function(add)
--         add("Branch", "Check out main", fn, "local")  -- group, label, action, detail
--     end)

local C = require("core.palette")
local keys = require("core.keys")
local menu = require("ui.menu")
local placeholder = require("ui.placeholder")
local popup = require("ui.popup")
local settings = require("core.settings")
local text = require("core.text")

local commands = {}

local MAX_RESULTS = 60
local MAX_RECENT = 8

local registered = {}   -- commands.register() entries
local sources = {}      -- commands.addSource() functions
local candidates = {}   -- everything searchable (built when the palette opens)
local results = {}      -- what the list shows, in order
local selected = 1

--- Add a command to the palette.
-- @param entry  { label, action, keywords?, enabled? (function), group? }
function commands.register(entry)
    registered[#registered + 1] = entry
end

--- Add a source of palette entries, asked every time the palette opens.
-- @param source  function(add) calling add(group, label, action, detail?,
--                shortcut?, enabled?) for each entry
function commands.addSource(source)
    sources[#sources + 1] = source
end

--- Recently run command labels, newest first.
-- @return array of labels
local function recent()
    local out = {}
    for label in (settings.get("paletteRecent", "")):gmatch("[^\30]+") do
        out[#out + 1] = label
    end

    return out
end

--- Remember a label as most recently run.
-- @param label  command label
local function remember(label)
    local list = { label }
    for _, other in ipairs(recent()) do
        if other ~= label and #list < MAX_RECENT then
            list[#list + 1] = other
        end
    end

    settings.set("paletteRecent", table.concat(list, "\30"))
end

--- Score `query` against `s` (nil when the letters don't all appear, in order).
-- @param s      candidate text
-- @param query  what was typed (lower case)
-- @return number or nil (higher is better)
local function score(s, query)
    if query == "" then
        return 0
    end

    local hay = s:lower()
    local plain = hay:find(query, 1, true)
    if plain then
        -- A contiguous match beats any scattered one; earlier is better.
        return 1000 - plain + (plain == 1 and 200 or 0)
    end

    local total = 0
    local position = 1
    local previous = -1
    for i = 1, #query do
        local c = query:sub(i, i)
        local found = hay:find(c, position, true)
        if not found then
            return nil
        end
        local bonus = 1
        if found == previous + 1 then
            bonus = bonus + 5
        end
        local before = found > 1 and hay:sub(found - 1, found - 1) or " "
        if before:match("[%s/%-_%.›]") then
            bonus = bonus + 8
        end
        total = total + bonus
        previous = found
        position = found + 1
    end

    return total - #hay * 0.05
end

--- Gather everything searchable right now.
local function collect()
    candidates = {}

    --- Add one candidate.
    local function add(group, label, action, detail, shortcut, enabled)
        candidates[#candidates + 1] = {
            group = group,
            label = label,
            action = action,
            detail = detail or "",
            shortcut = shortcut,
            enabled = enabled ~= false,
            search = group .. " " .. label .. " " .. (detail or ""),
        }
    end

    for _, entry in ipairs(menu.entries()) do
        local item = entry.item
        add(entry.menu, item.label, item.action, nil, item.shortcut, menu.isEnabled(item))
    end

    for _, entry in ipairs(registered) do
        local enabled = true
        if entry.enabled then
            enabled = entry.enabled()
        end
        add(entry.group or "Command", entry.label, entry.action, entry.keywords, entry.shortcut, enabled)
    end

    for _, source in ipairs(sources) do
        source(add)
    end
end

--- Rank the candidates for the query and fill the list.
-- @param query  typed text
local function search(query)
    query = text.trim(query):lower()
    results = {}

    if query == "" then
        local byLabel = {}
        for _, candidate in ipairs(candidates) do
            byLabel[candidate.group .. "\31" .. candidate.label] = candidate
        end
        for _, key in ipairs(recent()) do
            if byLabel[key] then
                results[#results + 1] = byLabel[key]
            end
        end
        for _, candidate in ipairs(candidates) do
            if #results >= MAX_RESULTS then
                break
            end
            if candidate.group ~= "File" and candidate.group ~= "Branch" then
                local already = false
                for _, shown in ipairs(results) do
                    already = already or shown == candidate
                end
                if not already then
                    results[#results + 1] = candidate
                end
            end
        end
    else
        local scored = {}
        for _, candidate in ipairs(candidates) do
            local s = score(candidate.search, query)
            if s then
                scored[#scored + 1] = { candidate = candidate, score = s + (candidate.enabled and 50 or 0) }
            end
        end
        table.sort(scored, function(a, b)
            return a.score > b.score
        end)
        for i = 1, math.min(#scored, MAX_RESULTS) do
            results[i] = scored[i].candidate
        end
    end

    local rows = {}
    for i, candidate in ipairs(results) do
        local labelColour = candidate.enabled and C.text or C.disabled
        local row = text.rowHeight(30) .. text.colour(C.dim, "  " .. candidate.group .. "  ›  ")
            .. text.colour(labelColour, candidate.label)
        if candidate.shortcut then
            row = row .. text.colour(C.dim, "    " .. keys.label(candidate.shortcut))
        end
        rows[i] = row
    end
    if #rows == 0 then
        rows[1] = text.rowHeight(30) .. text.colour(C.dim, "  Nothing matches.")
    end

    gitgud.setList("PaletteList", rows)
    selected = 1
    gitgud.selectListItem("PaletteList", #results > 0 and 1 or nil, true)
end

--- Close the palette.
function commands.close()
    if popup.isOpen("PalettePopup") then
        popup.close()
    end
end

--- Run result `i`.
-- @param i  1-based result
local function run(i)
    local candidate = results[i]
    if not candidate then
        return
    end
    if not candidate.enabled then
        require("core.status").warn("\"" .. candidate.label .. "\" isn't available right now.")
        return
    end

    remember(candidate.group .. "\31" .. candidate.label)
    commands.close()
    candidate.action()
end

--- Open the palette.
function commands.open()
    if popup.isOpen("PalettePopup") then
        commands.close()
        return
    end
    if require("ui.dialog").isOpen() then
        return
    end

    collect()
    placeholder.setText("PaletteEdit", "")
    search("")
    popup.open("PalettePopup", { focus = "PaletteEdit" })
end

--- Move the selection.
-- @param delta  rows to move
local function move(delta)
    if #results == 0 then
        return
    end

    selected = math.max(1, math.min(#results, selected + delta))
    gitgud.selectListItem("PaletteList", selected, true)
end

--- Wire the palette. Called once by main.lua.
function commands.init()
    placeholder.bind("PaletteEdit", "PalettePlaceholder")

    gitgud.on("PaletteEdit.changed", function(value)
        search(value)
    end)

    gitgud.on("PaletteEdit.accepted", function()
        run(selected)
    end)

    gitgud.on("PaletteList.clicked", function(value)
        local _, _, row = menu.parseClick(value)
        if row then
            run(row)
        end
    end)

    gitgud.on("key", function(combo)
        if not popup.isOpen("PalettePopup") then
            return
        end
        if combo == "down" then
            move(1)
        elseif combo == "up" then
            move(-1)
        elseif combo == "pagedown" then
            move(10)
        elseif combo == "pageup" then
            move(-10)
        end
    end)

    keys.bind("ctrl+k", commands.open, "Command palette")
    keys.bind("f1", commands.open, "Command palette")
end

return commands
