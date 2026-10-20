--- bragi/recap.lua: how the conversations Bragi follows are doing, told in a
-- few short sentences (a live spoken recap of the
-- conversations the master follows, asked for in any words).
--
-- A message the first-layer screening calls `recap` (the heard-text
-- filter's route for a spoken one, the router's for a typed one:
-- "what's going on?", "catch me up", "how are my sessions doing?") comes
-- here, never by keywords in code. It's answered from the app's live state
-- of every conversation the master started or sent work to (bragi/master.lua,
-- master.describe: its state, latest steps, what it waits on, its last
-- reply), told by a Haiku helper of its own (prompts/recap.md). The answer
-- shows as a quiet row under the message and rides along with the next
-- message to the agent, like a quick answer; a spoken one is spoken too
-- (bragi/voice.lua). When the helper fails, the message goes to the agent
-- as usual: the master can look for itself.
--
-- The same helper picks a conversation back up when it finishes or waits
-- for you (bragi/voice.lua, News): `news` instead of `question`.
--
-- Logged as "recap" lines in voice-log.txt (ms, how many conversations,
-- the answer, or why it failed).
--
-- Public API: recap.helper, recap.conversations(), recap.ask(payload, done),
-- recap.answer(question, opts)

local agent = require("bragi.agent")
local helpers = require("bragi.helpers")
local text = require("core.text")

local recap = { name = "bragi.recap" }

local RECAP_FORMAT = [[

## How the app talks to you

Each message you get is one JSON object: `{"question": "...",
"conversations": [...]}`, or `{"news": [{"what": "...", "conversation":
{...}, "told": "..."}], "said": [...]}`. Answer with the words to say
only, as plain text: no JSON, no quotes, no Markdown, no tools.]]

recap.helper = helpers.new({ prefix = "bragi-recap", file = "recap.md", format = RECAP_FORMAT })

--- Every followed conversation as the helper reads it (master.describe).
function recap.conversations()
    local master = require("bragi.master")
    local list = {}
    for _, tab in ipairs(master.followedTabs()) do
        list[#list + 1] = master.describe(tab)
    end
    -- Followed ones that aren't open (before a restart): from their transcripts.
    for _, d in ipairs(master.followedSaved()) do
        list[#list + 1] = d
    end
    return list
end

--- Ask the helper: done(words, err), the words trimmed ("" when it
-- answered nothing, or JSON).
function recap.ask(payload, done)
    helpers.ask(recap.helper, payload, function(reply, err)
        local said = text.trim(tostring(reply or ""))
        if said:sub(1, 1) == "{" then
            said, err = "", "it answered JSON"
        end
        done(said, err or (said == "" and "no answer" or nil))
    end)
end

--- Answer a message asking how the followed conversations are doing.
-- @param question  the message (typed, or spoken and checked)
-- @param opts      pending (its item, from agent.voicePending), onAnswer(words)
--                  (a spoken one: say it), onFail(why) (without one, it
--                  goes to the agent)
function recap.answer(question, opts)
    opts = opts or {}
    agent.waitingTitle("Catching up")
    local started = gitgud.now()
    local list = recap.conversations()
    recap.ask({ question = question, conversations = list }, function(said, err)
        local fields = { question = question, conversations = #list, ms = gitgud.now() - started }
        if said == "" then
            fields.failed = tostring(err)
            helpers.log("recap", fields)
            if opts.onFail then
                return opts.onFail(err)
            end
            if agent.session().turn then
                return require("bragi.voice").whileWorking(question, { pending = opts.pending })
            end
            return agent.send(question, { pending = opts.pending })
        end
        fields.text = said
        helpers.log("recap", fields)
        agent.quickAnswered(opts.pending, question, said, { quiet = true })
        if opts.onAnswer then
            opts.onAnswer(said)
        end
    end)
end

return recap
