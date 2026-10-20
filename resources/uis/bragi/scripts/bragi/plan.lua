--- bragi/plan.lua: a conversation's plan, the checklist of the agent's
-- steps pinned under its latest message.
--
-- Claude Code keeps its plan with one of two sets of tools (2.1.x sends the
-- second unless its tasks are switched off):
--
--   TodoWrite   { todos = { { content, status, activeForm } } }: the whole
--               list each time
--   TaskCreate  { subject, description, activeForm }: one step more, its id
--               in the result ("Task #3 created successfully: ...")
--   TaskUpdate  { taskId, status, subject, activeForm }: one step changed;
--               status "deleted" takes it out
--
-- status is pending, in_progress or completed. TaskList and TaskGet only
-- read it. A sub-agent's own plan isn't the conversation's.
--
-- The box (an item of kind "plan", bragi/agent.lua) is one per
-- conversation: it stays last, above the cards that wait on you, and is
-- redrawn in place on each change. Each step shows a filled check when
-- done (greyed out), a turning ring while in progress (its activeForm),
-- and a dashed circle while pending. Once every step is done it folds to
-- "Plan done (n steps)", which opens again on a click; a click on the head
-- folds or opens it any time. A saved conversation's plan is rebuilt from
-- its transcript (bragi/agent.lua replays the calls through plan.apply).
--
-- For Bragi's voice: plan.news(state, name, input) is what a call changes,
-- for the narrator (prompts/narration.md: a new plan is talked through, an
-- update names only the step it's on), and plan.describe(state) where it
-- stands, for recaps and news (bragi/master.lua's describe).
--
-- Public API: plan.isTool(name), plan.apply(state, name, input, toolId),
-- plan.created(state, toolId, result), plan.news(state, name, input),
-- plan.summary(state, name, input), plan.counts(state), plan.finished(state),
-- plan.describe(state), plan.draw(item, width), plan.VERBS

local C = require("core.palette")
local geometry = require("ui.geometry")
local text = require("core.text")

local plan = { name = "bragi.plan" }

local PAD = 14
local HEAD = 40       -- the head row: "Plan", how far it got
local ROW_MIN = 24    -- a step's row, at least
local ROW_GAP = 4
local ICON = 16
local TEXT_X = PAD + ICON + 10
local SPIN_MS = 90    -- a frame of the turning ring
local SPIN_FRAMES = 8

-- The calls that change the plan, and those that only read it.
local CHANGES = { TodoWrite = true, TaskCreate = true, TaskUpdate = true }
local READS = { TaskList = true, TaskGet = true }

--- The step rows' words for the plan's tools (bragi/agent.lua's TOOL_VERB).
plan.VERBS = {
    TodoWrite = { "Updated the plan", "Updating the plan" },
    TaskCreate = { "Added to the plan", "Adding to the plan" },
    TaskUpdate = { "Updated the plan", "Updating the plan" },
    TaskList = { "Read the plan", "Reading the plan" },
    TaskGet = { "Read the plan", "Reading the plan" },
}

--- Whether a tool keeps the plan (changes or reads it).
function plan.isTool(name)
    return CHANGES[name] == true or READS[name] == true
end

local function str(v)
    return type(v) == "string" and v or (v ~= nil and tostring(v) or "")
end

local function status(v)
    v = str(v)
    return (v == "completed" or v == "in_progress") and v or "pending"
end

--- A new, empty plan.
local function newState()
    return { steps = {}, byTool = {} }
end

--- A copy of a plan's steps (for what a call would change).
local function copy(state)
    local out = newState()
    for i, s in ipairs(state and state.steps or {}) do
        out.steps[i] = { id = s.id, content = s.content, activeForm = s.activeForm, status = s.status }
    end
    return out
end

local function stepById(state, id)
    for i, s in ipairs(state.steps) do
        if s.id == id then
            return s, i
        end
    end
    return nil
end

--- How many steps are done, and how many there are.
function plan.counts(state)
    local done, total = 0, 0
    for _, s in ipairs(state and state.steps or {}) do
        total = total + 1
        if s.status == "completed" then
            done = done + 1
        end
    end
    return done, total
end

--- Whether every step of a plan is done (false for none).
function plan.finished(state)
    local done, total = plan.counts(state)
    return total > 0 and done == total
end

--- The step being worked on, or nil.
local function current(state)
    for _, s in ipairs(state and state.steps or {}) do
        if s.status == "in_progress" then
            return s
        end
    end
    return nil
end

--- What a step in progress is called: its activeForm, else its content.
local function doing(s)
    return s.activeForm ~= "" and s.activeForm or s.content
end

--- The next id Claude Code gives a step made with TaskCreate, until its
-- result says.
local function nextId(state)
    local most = 0
    for _, s in ipairs(state.steps) do
        most = math.max(most, tonumber(s.id) or 0)
    end
    return tostring(most + 1)
end

--- Apply a plan tool's call to a plan.
-- @param state   the conversation's plan (tab.plan), or nil for a new one
-- @param name    the tool
-- @param input   its input (a table)
-- @param toolId  its tool call id (TaskCreate's result names the step)
-- @return the plan, and whether it changed
function plan.apply(state, name, input, toolId)
    state = state or newState()
    input = type(input) == "table" and input or {}
    if name == "TodoWrite" then
        local steps = {}
        for i, t in ipairs(type(input.todos) == "table" and input.todos or {}) do
            if type(t) == "table" then
                steps[#steps + 1] = { id = tostring(i), content = str(t.content), activeForm = str(t.activeForm),
                    status = status(t.status) }
            end
        end
        state.steps, state.byTool = steps, {}
        return state, true
    elseif name == "TaskCreate" then
        if plan.finished(state) then
            state.steps, state.byTool = {}, {} -- the last plan was done: a new one
        end
        local s = { id = nextId(state), content = str(input.subject ~= nil and input.subject or input.title),
            activeForm = str(input.activeForm), status = "pending" }
        state.steps[#state.steps + 1] = s
        if toolId then
            state.byTool[toolId] = s
        end
        return state, true
    elseif name == "TaskUpdate" then
        local s, i = stepById(state, str(input.taskId))
        if not s then
            return state, false
        end
        if input.status == "deleted" then
            table.remove(state.steps, i)
            return state, true
        end
        if input.status ~= nil then
            s.status = status(input.status)
        end
        if type(input.subject) == "string" and input.subject ~= "" then
            s.content = input.subject
        end
        if type(input.activeForm) == "string" then
            s.activeForm = input.activeForm
        end
        return state, true
    end
    return state, false
end

--- A TaskCreate's result: the id Claude Code gave the step.
function plan.created(state, toolId, result)
    local s = state and state.byTool[toolId or ""]
    if not s then
        return false
    end
    state.byTool[toolId] = nil
    local id = str(result):match("Task #(%S+) created")
    if id and id ~= s.id then
        s.id = id
        return true
    end
    return false
end

--- Whether two plans share no step (a new plan, not an update).
local function unrelated(a, b)
    local seen = {}
    for _, s in ipairs(a.steps) do
        seen[s.content] = true
    end
    for _, s in ipairs(b.steps) do
        if seen[s.content] then
            return false
        end
    end
    return true
end

--- What a call changes, for the narrator, or nil when it changes nothing:
--   { new = true, steps = { ... }, total }    a plan was just made
--   { added = "..." }                         a step more (TaskCreate)
--   { current = "...", done, total }          the step it's on now
--   { completed = "...", done, total }        a step done
--   { removed = "..." }                       a step taken out
--   { finished = true, total }                every step is done
function plan.news(state, name, input)
    if not CHANGES[name] then
        return nil
    end
    local before = copy(state)
    local after = copy(state)
    after = plan.apply(after, name, input)
    local done, total = plan.counts(after)
    if total == 0 then
        return nil
    end
    local wasNew = #before.steps == 0 or plan.finished(before)
    if name == "TodoWrite" and (wasNew or unrelated(before, after)) then
        local steps = {}
        for i, s in ipairs(after.steps) do
            steps[i] = s.content
        end
        return { new = true, steps = steps, total = total }
    elseif name == "TaskCreate" then
        local s = after.steps[#after.steps]
        return { added = s.content, new = wasNew or nil }
    end
    if done == total then
        return { finished = true, total = total }
    end
    local now, was = current(after), current(before)
    if now and (not was or was.id ~= now.id or doing(was) ~= doing(now)) then
        return { current = doing(now), done = done, total = total }
    end
    if name == "TaskUpdate" then
        local s = stepById(before, str(input and input.taskId))
        if s and input.status == "deleted" then
            return { removed = s.content }
        elseif s and input.status == "completed" then
            return { completed = s.content, done = done, total = total }
        end
    end
    local d = plan.counts(before)
    return d ~= done and { done = done, total = total } or nil
end

--- A plan call's one-line summary for its step row.
function plan.summary(state, name, input)
    input = type(input) == "table" and input or {}
    if READS[name] then
        return input.taskId and ("#" .. str(input.taskId)) or ""
    end
    local n = plan.news(state, name, input)
    if not n then
        return name == "TaskUpdate" and ("#" .. str(input.taskId)) or ""
    end
    local function steps(k)
        return k .. (k == 1 and " step" or " steps")
    end
    if n.new and n.steps then
        return steps(n.total)
    elseif n.added then
        return n.added
    elseif n.finished then
        return "all " .. steps(n.total) .. " done"
    elseif n.current then
        return n.current
    elseif n.completed then
        return n.completed .. ": done"
    elseif n.removed then
        return n.removed .. ": taken out"
    end
    return n.done .. " of " .. n.total .. " done"
end

--- Where a plan stands, for a recap: { done, total, current, next }, or
-- nil without one.
function plan.describe(state)
    local done, total = plan.counts(state)
    if total == 0 then
        return nil
    end
    local d = { done = done, total = total }
    local now = current(state)
    d.current = now and doing(now) or nil
    for _, s in ipairs(state.steps) do
        if s.status == "pending" then
            d.next = s.content
            break
        end
    end
    return d
end

-- ===================================================================
-- The box
-- ===================================================================

-- The turning rings shown: window name -> true. One timer turns them all
-- while there are any.
local spinners = {}
local spinning = false
local frame = 0

local function spin()
    if spinning then
        return
    end
    spinning = true
    local function tick()
        frame = (frame + 1) % SPIN_FRAMES
        local any = false
        for name in pairs(spinners) do
            if gitgud.getRect(name) then
                any = true
                gitgud.setProperty(name, "IconImage", "Bragi-Icons/PlanSpin" .. frame)
            else
                spinners[name] = nil
            end
        end
        if any then
            gitgud.after(SPIN_MS, tick)
        else
            spinning = false
        end
    end
    gitgud.after(SPIN_MS, tick)
end

local function icon(name, parent, x, y, image, colour)
    gitgud.createWindow("Gitgud/Icon", name, parent)
    gitgud.setProperty(name, "Area", geometry.rect(x, y, ICON, ICON))
    gitgud.setProperty(name, "IconImage", "Bragi-Icons/" .. image)
    gitgud.setProperty(name, "IconColour", colour)
    gitgud.setProperty(name, "GlowColour", "00000000")
    gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    return name
end

--- Whether the box shows folded: as you left it, else once every step is done.
function plan.folded(item)
    if item.folded ~= nil then
        return item.folded
    end
    return plan.finished(item.plan)
end

--- The head's words: "Plan done (5 steps)" once done and folded, else
-- "Plan" with how far it got.
function plan.headText(item)
    local done, total = plan.counts(item.plan)
    if done == total and plan.folded(item) then
        return "Plan done (" .. total .. (total == 1 and " step)" or " steps)"), ""
    end
    return "Plan", done .. " of " .. total .. " done"
end

--- Draw the plan box (an item of kind "plan", item.plan its plan) at
-- `width`; returns its height. Redrawn whole on each change.
function plan.draw(item, width)
    local ui = require("bragi.ui")
    if item.inner then
        for _, r in ipairs(item.rows or {}) do
            spinners[r.window .. "Spin"] = nil
        end
        gitgud.destroyWindow(item.inner)
    end
    item.gen = (item.gen or 0) + 1
    item.inner = item.name .. "G" .. item.gen
    local root = item.inner
    ui.box(root, item.name, { 0, 0, width, HEAD }, { fill = C.panel, border = C.border })
    local folded = plan.folded(item)

    -- The head: a button the width of the box.
    local head = root .. "Head"
    ui.button(head, root, { 1, 1, width - 2, HEAD - 2 }, "", { quiet = true, radius = 12,
        tooltip = folded and "Show the plan" or "Fold the plan" })
    gitgud.setProperty(head, "HoverFillColour", C.hover)
    gitgud.setProperty(head, "PushedFillColour", C.sel)
    local words, count = plan.headText(item)
    item.headText = words
    ui.label(root .. "Title", head, { PAD - 1, 0, width - PAD * 2 - 120, HEAD - 2 }, words,
        { font = "Bragi-13-Bold", colour = folded and C.sub or C.text })
    ui.label(root .. "Count", head, { width - PAD - 24 - 120, 0, 120, HEAD - 2 }, count,
        { font = "Bragi-12", colour = C.sub, align = "RightAligned" })
    icon(root .. "Fold", head, width - PAD - 18, math.floor((HEAD - 2 - ICON) / 2), folded and "NavClosed" or "NavOpen",
        C.sub)
    gitgud.on(head .. ".clicked", function()
        item.folded = not folded
        item.dirty = true
        require("bragi.agent").layoutSoon()
    end)
    if folded then
        return HEAD
    end

    local y = HEAD - 4
    local textW = width - TEXT_X - PAD
    item.rows = {}
    for i, s in ipairs(item.plan.steps) do
        local row = root .. "Step" .. i
        local working = s.status == "in_progress"
        local words = working and doing(s) or s.content
        local p = ui.paragraph(row, root, { TEXT_X, y, textW, 40 }, words, {
            font = working and "Bragi-14-Bold" or "Bragi-14",
            colour = s.status == "completed" and C.sub or C.text })
        local h = math.max(ROW_MIN, math.ceil(tonumber(gitgud.getProperty(p, "VertExtent") or "") or 20) + 4)
        gitgud.setProperty(p, "Area", geometry.rect(TEXT_X, y + 2, textW, h))
        local iy = y + 4
        if s.status == "completed" then
            icon(row .. "Mark", root, PAD, iy, "PlanDone", C.planDone)
        elseif working then
            local ring = icon(row .. "Spin", root, PAD, iy, "PlanSpin" .. frame, C.planActive)
            spinners[ring] = true
            spin()
        else
            icon(row .. "Mark", root, PAD, iy, "PlanPending", C.planPending)
        end
        item.rows[i] = { text = words, status = s.status, window = row }
        y = y + h + ROW_GAP
    end
    local h = y + PAD - ROW_GAP
    gitgud.setProperty(root, "Area", geometry.rect(0, 0, width, h))
    return h
end

return plan
