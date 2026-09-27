--- core/settings.lua — the user's app preferences, persisted between runs.
--
-- Stored as "key=value" lines in the per-user config folder (see
-- gitgud.configRead/configWrite). Values are strings on disk; get() turns
-- them back into the type of the default you ask with.
--
--     local settings = require("core.settings")
--     if settings.get("confirmDiscard", true) then ... end
--     settings.set("diffMode", "unified")

local settings = {}

local FILE = "settings"
local values = nil

--- Read the settings file once, lazily.
local function load()
    if values then
        return
    end

    values = {}
    local raw = gitgud.configRead(FILE) or ""
    for line in raw:gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_%.%-]+)=(.*)$")
        if key then
            values[key] = value
        end
    end
end

--- Write every setting back to disk.
local function save()
    local lines = {}
    for key, value in pairs(values) do
        lines[#lines + 1] = key .. "=" .. value
    end
    table.sort(lines)

    gitgud.configWrite(FILE, table.concat(lines, "\n") .. "\n")
end

--- Read a setting.
-- @param key       setting name
-- @param default   returned when unset; its type decides the conversion
--                  (boolean, number, or string)
-- @return the setting's value
function settings.get(key, default)
    load()
    local raw = values[key]

    if raw == nil then
        return default
    end
    if type(default) == "boolean" then
        return raw == "true"
    end
    if type(default) == "number" then
        return tonumber(raw) or default
    end

    return raw
end

--- Change a setting and persist it immediately.
-- @param key    setting name
-- @param value  boolean, number, or string (nil removes the setting)
function settings.set(key, value)
    load()

    local stored = value ~= nil and tostring(value) or nil
    if values[key] == stored then
        return -- unchanged: skip the file write
    end
    values[key] = stored

    save()
end

return settings
