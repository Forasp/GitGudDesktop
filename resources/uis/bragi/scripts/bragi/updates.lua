--- bragi/updates.lua: what the conversations Bragi manages did lately, kept
-- for its spoken updates.
--
-- Every step of every conversation Bragi manages goes in here the moment
-- it happens ("bragi.step" from bragi/agent.lua, passed on by
-- bragi/voice.lua, which drops incidental ones): the voice turn's and the
-- the conversation whose work Bragi tells as its own, in the first person
-- (updates.thread, set by bragi/voice.lua: the one you last sent to and
-- have on screen) and those of the conversations the master started or
-- sent work to (tab.bragiFollows, named when told). Every few seconds bragi/voice.lua
-- takes what's new (updates.take) and the narrator makes one line of it.
--
-- A step is { kind = "thinking", text }, { kind = "tool", name, summary,
-- description, starting, plan }, { kind = "reply", text }: a small piece of
-- news that waits for the next update instead of cutting in
-- (a background task's report, "bragi-wiki passed", from
-- bragi/master.lua), or { kind = "permission", tool, summary, answer }: how a
-- permission asked aloud was answered (allowed, refused, waiting), or a
-- question (answered, with `choice`). Streamed pieces of one thinking block are one
-- step (its latest MAX_CHARS kept); a tool that just started is replaced
-- by the same tool with its input. A plan tool's `plan` is what it changed
-- in the conversation's plan (bragi/plan.lua's plan.news). Each
-- conversation keeps its latest
-- MAX_STEPS. The answer's text is never kept: the voice turn's is spoken
-- as its summary, and another conversation's ends in its news.
--
-- Public API: updates.managed(tab), updates.own(tab), updates.add(tab, step),
-- updates.dropStarting(tab, name), updates.clear(tab), updates.worth(),
-- updates.take(), updates.active(), updates.waiting()

local updates = { name = "bragi.updates" }

updates.MAX_CHARS = 1200 -- of thinking per step sent to the narrator
updates.MAX_STEPS = 8    -- per conversation, the latest
updates.THINKING_CHARS = 120 -- thinking is news once there are a few words of it

updates.thread = nil -- the conversation told in the first person (bragi/voice.lua)

local order = {}   -- tabs with steps, in the order their first step came
local pending = {} -- tab -> { own, steps }

--- Whether Bragi manages a conversation: the one it tells as its own, or
-- one it follows.
function updates.managed(tab)
    return type(tab) == "table" and (updates.own(tab) or require("bragi.master").followed(tab))
end

--- Whether a conversation's work is told as Bragi's own: the thread.
function updates.own(tab)
    return tab ~= nil and tab == updates.thread
end

--- A step of a managed conversation.
function updates.add(tab, step)
    if step.kind ~= "tool" and step.kind ~= "thinking" and step.kind ~= "reply" and step.kind ~= "permission" then
        return
    end
    local p = pending[tab]
    if not p then
        p = { steps = {} }
        pending[tab] = p
        order[#order + 1] = tab
    end
    p.own = updates.own(tab)
    local steps = p.steps
    local prev = steps[#steps]
    if step.kind == "reply" then
        steps[#steps + 1] = { kind = "reply", text = tostring(step.text or "") }
    elseif step.kind == "permission" then
        -- How a permission asked aloud was answered: allowed, refused, or
        -- waiting (left on screen).
        steps[#steps + 1] = { kind = "permission", tool = step.tool, summary = step.summary, answer = step.answer,
            choice = step.choice }
    elseif step.kind == "thinking" then
        if prev and prev.kind == "thinking" then
            prev.text = (prev.text .. tostring(step.text or "")):sub(-updates.MAX_CHARS)
        else
            steps[#steps + 1] = { kind = "thinking", text = tostring(step.text or ""):sub(-updates.MAX_CHARS) }
        end
    else
        local entry = { kind = "tool", name = step.name, summary = step.summary, description = step.description,
            plan = step.plan }
        if prev and prev.kind == "tool" and prev.starting and prev.name == step.name and not step.starting then
            steps[#steps] = entry -- the tool that just started, now with its input
        else
            entry.starting = step.starting
            steps[#steps + 1] = entry
        end
    end
    while #steps > updates.MAX_STEPS do
        table.remove(steps, 1)
    end
end

--- An incidental step came: its "starting" entry (name only) goes too.
function updates.dropStarting(tab, name)
    local p = pending[tab]
    local prev = p and p.steps[#p.steps]
    if prev and prev.kind == "tool" and prev.starting and prev.name == name then
        table.remove(p.steps)
    end
end

--- Forget a conversation's new steps (all of them without one).
function updates.clear(tab)
    if tab == nil then
        order, pending = {}, {}
        return
    end
    pending[tab] = nil
    for i, t in ipairs(order) do
        if t == tab then
            table.remove(order, i)
            break
        end
    end
end

--- Whether there's anything worth telling: a tool, a small piece of news,
-- or a few words of thinking.
function updates.worth()
    local chars = 0
    for _, tab in ipairs(order) do
        for _, step in ipairs(pending[tab].steps) do
            if step.kind == "tool" or step.kind == "reply" or step.kind == "permission" then
                return true
            end
            chars = chars + #(step.text or "")
        end
    end
    return chars >= updates.THINKING_CHARS
end

--- A conversation's title, its first few words.
local function shortTitle(title)
    local list = {}
    for w in tostring(title or ""):gmatch("%S+") do
        list[#list + 1] = w
        if #list == 8 then
            list[#list] = w .. "..."
            break
        end
    end
    return table.concat(list, " ")
end

--- Take what's new, emptying the buffer: Bragi's own steps, oldest first,
-- and the other conversations' ({ title, project, steps }), in the order
-- they started. With the number of steps in all.
function updates.take()
    local own, others, count = {}, {}, 0
    for _, tab in ipairs(order) do
        local p = pending[tab]
        count = count + #p.steps
        if p.own then
            for _, step in ipairs(p.steps) do
                own[#own + 1] = step
            end
        elseif #p.steps > 0 then
            local cwd = tostring(tab.cwd or "")
            others[#others + 1] = { title = shortTitle(tab.title), project = cwd ~= ""
                and require("bragi.projects").name(cwd) or nil, steps = p.steps }
        end
    end
    order, pending = {}, {}
    return own, others, count
end

--- Whether any conversation Bragi manages is mid-turn.
function updates.active()
    for _, tab in ipairs(require("bragi.agent").tabs()) do
        if updates.managed(tab) and tab.session and tab.session.turn then
            return true
        end
    end
    return false
end

--- Whether a small piece of news waits for the next update (the cycle
-- goes on for it when nothing works any more).
function updates.waiting()
    for _, tab in ipairs(order) do
        for _, step in ipairs(pending[tab].steps) do
            if step.kind == "reply" then
                return true
            end
        end
    end
    return false
end

return updates
