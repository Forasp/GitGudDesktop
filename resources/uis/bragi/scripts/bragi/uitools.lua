--- bragi/uitools.lua: the Bragi UI's own tools for Claude Code, from every
-- module that has some (bragi/settingstool.lua, bragi/master.lua).
--
-- gitgud.declareTools takes the whole list at once, and each call comes
-- back as one event ("tools.call" { id, tool, arguments, session }), so
-- the modules register here: their tools are declared together, and each
-- call goes to the module that owns the tool. A tool's `sessions` (a list
-- of session names) keeps it to those sessions: the engine hides it from
-- the others, and a call from another session is refused here too.
--
-- A handler answers with text, isError; or, for work that takes a while,
-- returns nothing and calls reply(text, isError) later (the call waits up
-- to 15 s, agent/ToolServer.h).
--
-- A tool marked `noCard` (one that only reads, or only changes Bragi's own
-- settings with an Undo) runs without a permission card in every session
-- that has it (Bragi asked them whether it could read its
-- own settings): it's on each session's allow list (agent.extraSettings,
-- --settings permissions.allow), and granted by the app if Claude Code
-- asks anyway (uitools.noCard). The engine never sees the mark.
--
-- Public API: uitools.register(definitions, handle), uitools.handle(call)
-- (for tests), uitools.definitions(), uitools.noCard(tool, session),
-- uitools.allowRules(session)

local uitools = { name = "bragi.uitools" }

local list = {}     -- the definitions, in order of registration
local owners = {}   -- tool name -> { handle, sessions }

--- Every definition registered.
function uitools.definitions()
    return list
end

--- Whether a tool definition is available to session `name`.
local function availableTo(def, name)
    for _, s in ipairs(def.sessions or {}) do
        if s == name then
            return true
        end
    end
    return def.sessions == nil
end

--- Whether a tool, as Claude Code names it (mcp__repo__<name>), is one of
-- ours that needs no card in session `session`.
function uitools.noCard(tool, session)
    local name = tostring(tool or ""):match("^mcp__repo__(.+)$")
    for _, def in ipairs(list) do
        if def.name == name then
            return def.noCard == true and availableTo(def, session)
        end
    end
    return false
end

--- The allow-list rules for session `session`'s tools that need no card,
-- as Claude Code's permissions.allow takes them.
function uitools.allowRules(session)
    local rules = {}
    for _, def in ipairs(list) do
        if def.noCard and availableTo(def, session) then
            rules[#rules + 1] = "mcp__repo__" .. def.name
        end
    end
    return rules
end

local function declare()
    local ok, err = gitgud.declareTools(list)
    if not ok then
        print("[uitools] the tools weren't declared: " .. tostring(err))
    end
end

--- Add a module's tools (replacing any of the same name).
-- @param definitions  MCP tool definitions, each optionally with `sessions`
-- @param handle       fn(call, reply) -> text, isError (or nothing, then reply later)
function uitools.register(definitions, handle)
    for _, def in ipairs(definitions) do
        if owners[def.name] then
            for i, d in ipairs(list) do
                if d.name == def.name then
                    table.remove(list, i)
                    break
                end
            end
        end
        list[#list + 1] = def
        owners[def.name] = { handle = handle, sessions = def.sessions }
    end
    declare()
end

--- Answer one call: through `reply(text, isError)`, once.
function uitools.handle(call, reply)
    local done = false
    local function answer(text, isError)
        if not done then
            done = true
            reply(tostring(text or ""), isError == true)
        end
    end
    local owner = owners[call.tool or ""]
    if not owner then
        return answer("No tool named " .. tostring(call.tool) .. ".", true)
    end
    if owner.sessions then
        local allowed = false
        for _, name in ipairs(owner.sessions) do
            allowed = allowed or name == call.session
        end
        if not allowed then
            return answer("The tool " .. tostring(call.tool) .. " isn't available in this session.", true)
        end
    end
    local ok, text, isError = pcall(owner.handle, call, answer)
    if not ok then
        return answer("The app failed to do it: " .. tostring(text), true)
    end
    if text ~= nil then
        answer(text, isError)
    end
end

function uitools.init()
    gitgud.on("tools.call", function(detail)
        local call = gitgud.jsonDecode(detail)
        if type(call) ~= "table" or not call.id then
            return
        end
        uitools.handle(call, function(text, isError)
            gitgud.toolReply(call.id, text, isError)
        end)
    end)
end

return uitools
