--- p4/views/panes.lua — the right pane's tabs (Files, History, Pending,
-- Submitted, Branches, Labels, Workspaces) and the bottom pane's (Log,
-- Dashboard). One panel shows at a time; views refresh their panel when it
-- becomes visible (the in-script signal "pane.shown" with the tab id), so
-- hidden tabs cost nothing on every repository refresh.
--
--     panes.show("history")      -- switch tabs
--     panes.current()            -- "history"
--     panes.isShown("pending")

local app = require("core.app")
local settings = require("core.settings")
local tabs = require("p4.tabs")

local panes = { name = "panes" }

local RIGHT = {
    { id = "files", label = "Files", icon = "Folder", panel = "FilesPanel" },
    { id = "history", label = "History", icon = "History", panel = "HistoryPanel" },
    { id = "pending", label = "Pending", icon = "ChangePending", panel = "PendingPanel" },
    { id = "submitted", label = "Submitted", icon = "ChangeSubmitted", panel = "SubmittedPanel" },
    { id = "branches", label = "Branches", icon = "Branch16", panel = "BranchesPanel" },
    { id = "labels", label = "Labels", icon = "Label16", panel = "LabelsPanel" },
    { id = "workspaces", label = "Workspaces", icon = "Workspace", panel = "WorkspacesPanel" },
}

local BOTTOM = {
    { id = "log", label = "Log", panel = "LogList" },
    { id = "dashboard", label = "Dashboard", panel = "DashboardList" },
}

--- Show a right-pane tab.
-- @param id  tab id
function panes.show(id)
    if not tabs.isVisible("RightTabs", id) then
        tabs.setVisible("RightTabs", id, true)
        settings.set("p4.tab." .. id, true)
    end
    tabs.select("RightTabs", id)
end

--- The visible right-pane tab.
-- @return id
function panes.current()
    return tabs.current("RightTabs")
end

--- Is a right-pane tab the visible one?
-- @param id  tab id
-- @return boolean
function panes.isShown(id)
    return panes.current() == id
end

--- Show or hide a tab from the strip (View menu).
-- @param id  tab id
function panes.toggleTab(id)
    local visible = not tabs.isVisible("RightTabs", id)
    tabs.setVisible("RightTabs", id, visible)
    settings.set("p4.tab." .. id, visible)
    if not visible and panes.current() == id then
        for _, item in ipairs(RIGHT) do
            if item.id ~= id and tabs.isVisible("RightTabs", item.id) then
                tabs.select("RightTabs", item.id)
                break
            end
        end
    end
end

--- Is a tab in the strip?
-- @param id  tab id
-- @return boolean
function panes.tabVisible(id)
    return tabs.isVisible("RightTabs", id)
end

--- The right-pane tab definitions (for the View menu).
-- @return array of { id, label }
function panes.tabs()
    return RIGHT
end

--- Show a bottom tab.
-- @param id  "log" | "dashboard"
function panes.showBottom(id)
    tabs.select("BottomTabs", id)
end

function panes.init()
    tabs.create("RightTabs", RIGHT, function(id)
        for _, item in ipairs(RIGHT) do
            gitgud.setVisible(item.panel, item.id == id)
        end
        settings.set("p4.rightTab", id)
        app.publish("pane.shown", id)
    end)
    for _, item in ipairs(RIGHT) do
        tabs.setVisible("RightTabs", item.id, settings.get("p4.tab." .. item.id, true))
    end

    tabs.create("BottomTabs", BOTTOM, function(id)
        for _, item in ipairs(BOTTOM) do
            gitgud.setVisible(item.panel, item.id == id)
        end
        app.publish("pane.shown", id)
    end)
end

--- After the first refresh: the remembered tab.
function panes.start()
    tabs.select("RightTabs", settings.get("p4.rightTab", "pending"))
    tabs.select("BottomTabs", "log")
end

return panes
