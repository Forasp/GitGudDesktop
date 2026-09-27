--- depot/status.lua — the status bar's right side (branch, sync, open files)
-- and logging of the network operations the shared sync module runs.

local C = require("core.palette")
local changelists = require("depot.changelists")
local log = require("depot.log")
local status = require("core.status")
local text = require("core.text")

local depotStatus = { name = "depotstatus" }

function depotStatus.refresh(state)
    if not state.open then
        status.summary(text.colour(C.dim, "No workspace"))
        return
    end
    local ab = state.aheadBehind or {}
    local parts = { state.branch ~= "" and state.branch or "detached" }
    if ab.hasUpstream then
        parts[#parts + 1] = (ab.ahead or 0) .. " ahead, " .. (ab.behind or 0) .. " behind " .. ab.upstream
    end
    local open = 0
    for _, cl in ipairs(changelists.all()) do
        open = open + #cl.files
    end
    parts[#parts + 1] = text.plural(open, "open file")
    status.summary(text.colour(C.text2, table.concat(parts, "   ·   ")))
end

function depotStatus.init()
    -- The shared views/sync.lua reports to the status bar; the Log shows
    -- the outcomes too.
    for _, op in ipairs({ "fetch", "push", "pull", "pushTags", "clone", "deleteRemoteBranch", "pushBranch" }) do
        gitgud.on(op .. ".done", function(detail)
            if op == "pushBranch" then
                local branch, remote = (detail or ""):match("^(.-)|(.*)$")
                log.info("Shelf " .. (branch or "") .. " shared on " .. (remote or "the remote") .. ".")
            elseif op == "pull" then
                log.info((detail or ""):match("|(.*)$") or detail or "Pulled.")
            else
                log.info(detail ~= "" and detail or (op .. " finished."))
            end
        end)
        gitgud.on(op .. ".error", function(detail)
            log.error(op .. " failed: " .. tostring(detail))
        end)
    end
end

return depotStatus
