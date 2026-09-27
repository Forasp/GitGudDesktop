--- p4/views/dashboard.lua — the Dashboard tab of the bottom pane: what needs
-- your attention in this workspace (P4V's dashboard): pending work, shelves,
-- files to resolve, whether you're behind the upstream, and your recent
-- submits. Double-click a line to act on it.

local C = require("core.palette")
local app = require("core.app")
local changelists = require("p4.changelists")
local icons = require("p4.icons")
local panes = require("p4.views.panes")
local repo = require("core.repo")
local text = require("core.text")
local util = require("p4.util")

local dashboard = { name = "dashboard" }

local rows = {}     -- { markup, action }
local visible = false

local function line(icon, markup, action)
    rows[#rows + 1] = {
        markup = text.rowHeight(22) .. " " .. icons.inline(icon) .. "  " .. markup,
        action = action,
    }
end

local function heading(title)
    rows[#rows + 1] = { markup = text.rowHeight(24) .. text.font("Gitgud-System-Bold", " " .. title) }
end

local function render()
    if not visible then
        return
    end
    rows = {}
    local state = repo.state()
    if not state.open then
        line("Info", text.colour(C.dim, "No workspace is open."))
        gitgud.setList("DashboardList", { rows[1].markup })
        return
    end

    heading("Workspace")
    line("Workspace", text.colour(C.text, state.name) .. text.colour(C.dim, "   " .. state.path))
    line("Branch16", text.colour(C.text, "Branch: " .. (state.branch ~= "" and state.branch or "detached")))

    local ab = state.aheadBehind or {}
    if ab.hasUpstream then
        if (ab.behind or 0) > 0 then
            line("FileOutdated", text.colour(C.warn, text.plural(ab.behind, "changelist") .. " to get from "
                .. ab.upstream .. " — Get Latest"), require("p4.actions").getLatest)
        else
            line("FileSynced", text.colour(C.ok, "Up to date with " .. ab.upstream))
        end
        if (ab.ahead or 0) > 0 then
            line("Push", text.colour(C.text, text.plural(ab.ahead, "submitted changelist") .. " not pushed yet — Push"),
                require("p4.commands").push)
        end
    elseif state.headOid ~= "" then
        line("Info", text.colour(C.dim, "This branch doesn't track a remote branch yet."))
    end
    local fetched = require("views.sync").lastFetched()
    line("Fetch", text.colour(C.dim, fetched and ("Last fetched " .. text.ago(fetched)) or "Not fetched this session — Fetch"),
        require("p4.commands").fetch)

    heading("Pending work")
    local files, lists, shelves = 0, 0, 0
    for _, cl in ipairs(changelists.all()) do
        files = files + #cl.files
        if cl.id ~= 0 then
            lists = lists + 1
        end
        if cl.shelf then
            shelves = shelves + 1
        end
    end
    local showPending = function()
        panes.show("pending")
    end
    line("ChangePending", text.colour(C.text, text.plural(files, "open file") .. " in "
        .. text.plural(lists + 1, "pending changelist")), showPending)
    if shelves > 0 then
        line("ChangeShelved", text.colour(C.text, text.plural(shelves, "shelved changelist")), showPending)
    end
    if #state.conflicts > 0 then
        line("FileConflict", text.colour(C.err, text.plural(#state.conflicts, "file") .. " to resolve"),
            function()
                require("p4.commands").resolve()
            end)
    end
    if state.operation ~= "none" then
        line("Warning", text.colour(C.warn, "A " .. state.operation .. " is in progress: resolve and submit, or abort it"),
            require("p4.commands").abort)
    end

    heading("Your recent submits")
    local email = gitgud.config("user.email")
    local shown = 0
    for _, commit in ipairs(gitgud.history({ max = 60 }) or {}) do
        if commit.email == email and shown < 5 then
            shown = shown + 1
            local oid = commit.oid
            line("ChangeSubmitted", text.colour(C.text, util.change(oid) .. "  " .. util.summary(commit.summary))
                .. text.colour(C.dim, "   " .. text.ago(commit.time)), function()
                require("p4.views.submitted").reveal(oid)
            end)
        end
    end
    if shown == 0 then
        line("Info", text.colour(C.dim, "None in the latest 60 changelists."))
    end

    local items = {}
    for i, row in ipairs(rows) do
        items[i] = row.markup
    end
    gitgud.setList("DashboardList", items)
end

function dashboard.init()
    gitgud.on("DashboardList.doubleClicked", function(value)
        local row = rows[(tonumber(value) or -1) + 1]
        if row and row.action then
            row.action()
        end
    end)
    app.subscribe("pane.shown", function(id)
        if id == "dashboard" then
            visible = true
            render()
        elseif id == "log" then
            visible = false
        end
    end)
    app.subscribe("changelists.changed", render)
end

function dashboard.refresh()
    render()
end

return dashboard
