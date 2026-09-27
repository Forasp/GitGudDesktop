--- core/status.lua — the status bar.
--
-- Transient messages go on the left and fade back to "Ready." after a few
-- seconds (errors stay until the next message); the right side shows the
-- repository summary and is set by views/toolbar.lua.
--
--     local status = require("core.status")
--     status.ok("Pushed to origin.")
--     status.error("Push failed: " .. message)

local C = require("core.palette")
local text = require("core.text")

local status = {}

local RESET_MS = 6000
local resetTimer = nil

--- Show a message in a colour, optionally clearing it after a while.
-- @param colour     AARRGGBB hex
-- @param message    plain text (escaped for you)
-- @param sticky     true to keep it until the next message
local function show(colour, message, sticky)
    gitgud.setText("StatusLabel", text.colour(colour, message))

    if resetTimer then
        gitgud.cancelTimer(resetTimer)
        resetTimer = nil
    end

    if not sticky then
        resetTimer = gitgud.after(RESET_MS, function()
            resetTimer = nil
            gitgud.setText("StatusLabel", text.colour(C.dim, "Ready."))
        end)
    end
end

--- A neutral progress/info message.
-- @param message  plain text
function status.info(message)
    show(C.text2, message, false)
end

--- A success message.
-- @param message  plain text
function status.ok(message)
    show(C.ok, message, false)
end

--- A warning (stays a little longer: until the next message).
-- @param message  plain text
function status.warn(message)
    show(C.warn, message, true)
end

--- An error (stays until the next message).
-- @param message  plain text
function status.error(message)
    show(C.err, message, true)
end

--- Report the result of a gitgud call that returns (value | nil, message).
-- @param okMessage  shown on success (nil = say nothing)
-- @param result     first return value of the gitgud call
-- @param err        second return value
-- @return true when the call succeeded
function status.report(okMessage, result, err)
    if result == nil or result == false then
        status.error(err or "The operation failed.")
        return false
    end

    if okMessage then
        status.ok(okMessage)
    end

    return true
end

--- Set the right-hand summary.
-- @param markup  CEGUI markup (callers escape their own text)
function status.summary(markup)
    gitgud.setText("StatusRight", markup)
end

return status
