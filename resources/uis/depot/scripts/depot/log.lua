--- depot/log.lua — the Log pane: every command the UI runs, as the git
-- command it corresponds to, followed by its outcome.
-- Newest at the bottom; kept to the last few hundred lines.
--
--     log.command("git commit -m \"Fix\"")
--     log.info("Submitted change 3f2a1c0")
--     log.error("push failed: ...")
--     log.report(okText, gitgud.stage(paths))  -- logs, and returns success

local C = require("core.palette")
local icons = require("depot.icons")
local status = require("core.status")
local text = require("core.text")

local log = { name = "log" }

local MAX_LINES = 400
local lines = {}

--- Append a line and scroll to it.
-- @param markup  row markup
local function push(markup)
    lines[#lines + 1] = text.rowHeight(18) .. markup
    if #lines > MAX_LINES then
        table.remove(lines, 1)
    end
    gitgud.setList("LogList", lines)
    gitgud.selectListItem("LogList", #lines, true)
    gitgud.selectListItem("LogList", nil, false)
end

--- A command being run (grey bullet).
-- @param command  the command line
function log.command(command)
    push(text.colour(C.dim, "  •  ") .. text.colour(C.text2, command))
end

--- A result line (green arrow).
-- @param message  plain text
function log.info(message)
    push(text.colour(C.ok, "  →  ") .. text.colour(C.text, message))
end

--- A warning (amber).
-- @param message  plain text
function log.warn(message)
    push(" " .. icons.inline("Warning", 14) .. " " .. text.colour(C.warn, message))
end

--- An error (red); also shown in the status bar.
-- @param message  plain text
function log.error(message)
    push(" " .. icons.inline("Cancel", 14) .. " " .. text.colour(C.err, message))
    status.error(message)
end

--- Log the result of a gitgud call returning (value | nil, message).
-- @param okMessage  logged on success (nil = nothing)
-- @param result     first return value
-- @param err        second return value
-- @return result (nil on failure)
function log.report(okMessage, result, err)
    if result == nil or result == false then
        log.error(err or "The command failed.")
        return nil
    end
    if okMessage then
        log.info(okMessage)
        status.ok(okMessage)
    end

    return result
end

--- Quote a path or message for a displayed command line.
-- @param s  string
-- @return quoted if needed
function log.quote(s)
    if s:find("[%s\"]") then
        return "\"" .. s:gsub("\"", "\\\"") .. "\""
    end

    return s
end

--- Clear the pane.
function log.clear()
    lines = {}
    gitgud.setList("LogList", lines)
end

--- Wire the pane's context menu.
function log.init()
    gitgud.on("LogList.rightClicked", function(value)
        local x, y = require("ui.menu").parseClick(value)
        require("ui.menu").popup({
            {
                label = "Copy Log",
                action = function()
                    local plain = {}
                    for _, line in ipairs(lines) do
                        plain[#plain + 1] = (line:gsub("%[[^%]]*%]", ""))
                    end
                    gitgud.setClipboard(table.concat(plain, "\n"))
                end,
            },
            { label = "Clear Log", action = log.clear },
        }, x, y)
    end)
    log.info("GitGud Desktop (Depot layout) ready.")
end

return log
