--- bragi/user.lua: who Bragi works for, by name, for the prompts and the
-- master conversation's tools.
--
-- The name is the setting bragi.userName: asked in the welcome flow's
-- Claude Code step (prefilled from the name Claude Code's account has, when
-- it has one) and editable in Settings, Claude. With none, the prompts say
-- "the user".
--
-- Prompt files say {user} where the name goes ({User} at the start of a
-- sentence); user.fill fills them in each time a prompt is used, so a new
-- name reaches the next session.
--
-- Public API: user.current(), user.label(), user.fill(text),
-- user.suggested(), user.offer(), user.account()

local settings = require("core.settings")
local text = require("core.text")

local user = {}

local KEY = "bragi.userName"
local NOBODY = "the user"

--- The name set ("" when none).
function user.current()
    return text.trim(tostring(settings.get(KEY, "") or ""))
end

--- The name, or "the user".
function user.label()
    local name = user.current()
    return name ~= "" and name or NOBODY
end

--- {user} and {User} in `body` filled in.
function user.fill(body)
    if type(body) ~= "string" then
        return body
    end
    local label = user.label()
    local capital = label:gsub("^%l", string.upper)
    return (body:gsub("{user}", function()
        return label
    end):gsub("{User}", function()
        return capital
    end))
end

--- Claude Code's account (its .claude.json's oauthAccount), or nil.
local function oauthAccount()
    local dir = os.getenv("CLAUDE_CONFIG_DIR")
    local file = (dir and dir ~= "") and (dir .. "/.claude.json")
        or ((os.getenv("USERPROFILE") or os.getenv("HOME") or "") .. "/.claude.json")
    local f = io.open(file, "rb")
    if not f then
        return nil
    end
    local parsed = gitgud.jsonDecode(f:read("a"))
    f:close()
    local account = type(parsed) == "table" and parsed.oauthAccount or nil
    return type(account) == "table" and account or nil
end

--- The name Claude Code's account has (its .claude.json, oauthAccount's
-- displayName), or "".
function user.suggested()
    local account = oauthAccount()
    local name = account and account.displayName or nil
    return type(name) == "string" and text.trim(name) or ""
end

--- Which Claude account Claude Code is signed in with: its id (or email),
-- or "" when it isn't known (an API key, or not signed in).
function user.account()
    local account = oauthAccount()
    for _, key in ipairs({ "accountUuid", "emailAddress" }) do
        local v = account and account[key]
        if type(v) == "string" and text.trim(v) ~= "" then
            return text.trim(v)
        end
    end
    return ""
end

--- Fill the name in from Claude Code's account, unless one was ever set
-- (an empty one too: the user cleared it).
function user.offer()
    if settings.get(KEY, nil) == nil then
        settings.set(KEY, user.suggested())
    end
end

return user
