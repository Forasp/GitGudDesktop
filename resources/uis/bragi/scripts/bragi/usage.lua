--- bragi/usage.lua: the usage circle beside the prompt box ("context plus the five-hour and weekly limits, using real
-- data only"). Rings stacked in one place (imageset Bragi-Usage):
--
--   outer   how full the shown conversation's context is: the latest model
--           call's tokens over the window the turn's result named
--           (sidepanel.context; the same numbers as the panel's Context card)
--   middle  the subscription's five-hour limit
--   inner   its weekly limit
--
-- The limits are Claude Code's own: the rate_limit_event it prints when a
-- window's percent or reset time moves (agent.rateLimit, unifiedWindows),
-- and, now and then, its get_usage answer (asking too
-- often gets it blocked). get_usage is asked through a running session
-- once its turn is over, at most every ASK_EVERY_S per account, and not for
-- FAILED_WAIT_S after it was refused; when it was asked is kept too, so a
-- restart doesn't ask again. The limits are the account's (user.account()),
-- so any session's report counts, and each account's last ones are kept in
-- the config folder (LIMITS_FILE) through theme switches and restarts:
-- between asks the circle shows those, and the numbers say how old they
-- are once that matters (STALE_S).
--
-- A ring shows only when its number is known (real data only): no window
-- named yet, no limits reported (an API-key sign-in, or no reply yet), or
-- a window past its reset leaves that ring out, and with nothing known the
-- circle hides. A click opens the numbers: percent used, tokens, when each
-- limit resets.
--
-- Public API: usage.paint(), usage.open(), usage.close(), usage.snapshot()
-- (what it shows, for tests), usage.ask(sessionName) (get_usage now, when
-- it's due), usage.clock (os.time; tests move it)

local C = require("core.palette")
local app = require("core.app")
local geometry = require("ui.geometry")
local popup = require("ui.popup")
local text = require("core.text")

local usage = { name = "bragi.usage" }

local BUTTON = "AgentUsage"
local POPUP = "BragiUsagePopup"
local LIMITS_FILE = "bragi-limits.json" -- { accounts = { [account] = { five_hour, seven_day, asked, failed } } }
local STALE_S = 600           -- a report older than this says when it came
local ASK_EVERY_S = 15 * 60   -- get_usage at most this often per account
local FAILED_WAIT_S = 60 * 60 -- and not for this long after it was refused
local NO_ACCOUNT = "-"        -- the account key when Claude Code's isn't known
local STEPS = 50              -- arcs per ring (make-usage-rings.ps1)
local AREA = "{{1,-346},{1,-54},{1,-310},{1,-18}}" -- left of the mode button
local POPUP_W = 300
local ROW_H = 58
local TICK_MS = 60000         -- "resets in" and expired windows

-- Fill colours by share used (policy, as the panel's Context bar).
local HIGH, FULL = 0.7, 0.9

-- The rings, outer to inner, and the popup's rows in the same order.
local RINGS = {
    { key = "context", title = "Context" },
    { key = "five_hour", title = "Five-hour limit" },
    { key = "seven_day", title = "Weekly limit" },
}

local saved = { accounts = {} } -- LIMITS_FILE
local limits = {}             -- the account's: five_hour, seven_day: { utilization, resetsAt, at }; asked, failed
local asking = {}             -- get_usage request id -> the account it's for
local useAccount              -- the account signed in now: its limits (below)
local save                    -- LIMITS_FILE written (below)
local shown = {}              -- what's drawn: ring key -> share
local colours = {}            -- ring key -> its fill colour
local visible = false         -- the circle (some ring is known)
local lines = {}              -- the popup's rows as drawn: { title, value, detail }
local tickTimer = nil

local function thousands(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function colourOf(share)
    return share >= FULL and C.err or (share >= HIGH and C.accentText or C.accent)
end

--- "in 2 h 15 min", "in 40 min", or a day and time further off.
local function resetsIn(at)
    local s = at - os.time()
    if s < 3600 then
        return "in " .. math.max(1, math.ceil(s / 60)) .. " min"
    elseif s < 86400 then
        local h, m = math.floor(s / 3600), math.floor((s % 3600) / 60)
        return "in " .. h .. " h" .. (m > 0 and (" " .. m .. " min") or "")
    end
    return os.date("%A %H:%M", at)
end

--- A limit window still current: { share, resetsAt }, or nil.
local function windowOf(key)
    local w = limits[key]
    if type(w) ~= "table" or not tonumber(w.utilization) then
        return nil
    end
    local at = tonumber(w.resetsAt)
    if at and at <= os.time() then
        return nil -- reset since: its new figure isn't known yet
    end
    return { share = math.max(0, tonumber(w.utilization)), resetsAt = at, reported = tonumber(w.at) }
end

--- "Resets in 2 h 15 min", and when it was reported if that was a while ago.
local function detailOf(w)
    local parts = {}
    if w.resetsAt then
        parts[#parts + 1] = "Resets " .. resetsIn(w.resetsAt)
    end
    if w.reported and os.time() - w.reported > STALE_S then
        parts[#parts + 1] = "as of " .. os.date(os.time() - w.reported < 86400 and "%H:%M" or "%A %H:%M", w.reported)
    end
    return #parts > 0 and table.concat(parts, "; ") or nil
end

--- The shown conversation's context: { tokens, window, share }, or nil.
local function contextOf()
    local tab = require("bragi.agent").current()
    local name = tab and tab.session and tab.session.name
    local c = name and require("bragi.sidepanel").context(name)
    if not c then
        return nil
    end
    local window = tonumber(c.window)
    return { tokens = c.tokens, window = window, share = window and window > 0 and c.tokens / window or nil }
end

-- ===================================================================
-- The circle
-- ===================================================================

local function create()
    if gitgud.getRect(BUTTON) then
        return
    end
    gitgud.createWindow("Bragi/Button8", BUTTON, "AgentComposer")
    gitgud.setProperty(BUTTON, "Area", AREA)
    gitgud.setProperty(BUTTON, "Text", "")
    gitgud.setProperty(BUTTON, "NormalFillColour", C.transparent)
    gitgud.setProperty(BUTTON, "HoverFillColour", C.hover)
    gitgud.setProperty(BUTTON, "PushedFillColour", C.sel)
    gitgud.setProperty(BUTTON, "BorderColour", C.transparent)
    for i = 1, #RINGS do
        for _, part in ipairs({ "Track", "Arc" }) do
            local name = BUTTON .. part .. i
            gitgud.createWindow("Gitgud/Icon", name, BUTTON)
            gitgud.setProperty(name, "Area", geometry.rect(2, 2, 32, 32))
            gitgud.setProperty(name, "IconImage", part == "Track" and ("Bragi-Usage/Track" .. i) or "")
            gitgud.setProperty(name, "IconColour", C.border)
            gitgud.setProperty(name, "GlowColour", C.transparent)
            gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
        end
    end
    gitgud.on(BUTTON .. ".clicked", function()
        if popup.isOpen(POPUP) then
            usage.close()
        else
            usage.open()
        end
    end)
end

--- One ring; returns its fill colour (nil when it's left out or empty).
local function paintRing(i, share)
    local track, arc = BUTTON .. "Track" .. i, BUTTON .. "Arc" .. i
    gitgud.setVisible(track, share ~= nil)
    local n = share and math.min(STEPS, math.floor(share * STEPS + 0.5)) or 0
    gitgud.setVisible(arc, n > 0)
    if n > 0 then
        gitgud.setProperty(arc, "IconImage", "Bragi-Usage/Arc" .. i .. "-" .. n)
        gitgud.setProperty(arc, "IconColour", colourOf(share))
        return colourOf(share)
    end
    return nil
end

-- ===================================================================
-- The numbers (a popup over the prompt box)
-- ===================================================================

local function createPopup()
    if gitgud.getRect(POPUP) then
        return
    end
    local ui = require("bragi.ui")
    gitgud.createWindow("Bragi/Box12", POPUP, "Root")
    gitgud.setProperty(POPUP, "FillColour", C.panel)
    gitgud.setProperty(POPUP, "BorderColour", C.border)
    gitgud.setProperty(POPUP, "AlwaysOnTop", "true")
    gitgud.setVisible(POPUP, false)
    ui.label(POPUP .. "Title", POPUP, { 16, 12, POPUP_W - 32, 22 }, "Usage", { font = "Bragi-14-Bold" })
    for i = 1, #RINGS do
        local row = POPUP .. "Row" .. i
        ui.label(row .. "Title", POPUP, { 16, 0, 180, 20 }, "", { font = "Bragi-13" })
        ui.label(row .. "Value", POPUP, { POPUP_W - 96, 0, 80, 20 }, "", { font = "Bragi-13-Bold", align = "RightAligned" })
        ui.box(row .. "Track", POPUP, { 16, 0, POPUP_W - 32, 6 }, { radius = 4, fill = C.sel, border = C.transparent })
        ui.box(row .. "Fill", POPUP, { 16, 0, 8, 6 }, { radius = 4, fill = C.accent, border = C.transparent })
        ui.label(row .. "Detail", POPUP, { 16, 0, POPUP_W - 32, 18 }, "", { font = "Bragi-12", colour = C.sub })
    end
    ui.paragraph(POPUP .. "Note", POPUP, { 16, 0, POPUP_W - 32, 40 }, "", { font = "Bragi-12", colour = C.sub })
end

--- The popup's rows: { title, share, value, detail } for each known number,
-- and a note on what isn't known.
local function rowsOf()
    local rows, note = {}, nil
    local ctx = contextOf()
    if ctx and ctx.share then
        rows[#rows + 1] = { title = "Context", share = ctx.share,
            detail = thousands(ctx.tokens) .. " of " .. thousands(ctx.window) .. " tokens" }
    elseif ctx then
        rows[#rows + 1] = { title = "Context",
            detail = thousands(ctx.tokens) .. " tokens; the window's size comes when the turn ends" }
    end
    local any = false
    for i = 2, #RINGS do
        local w = windowOf(RINGS[i].key)
        if w then
            any = true
            rows[#rows + 1] = { title = RINGS[i].title, share = w.share, detail = detailOf(w) }
        end
    end
    if not ctx then
        note = "Context shows once Claude Code reports this conversation's tokens."
    end
    if not any then
        note = (note and (note .. " ") or "")
            .. "Usage limits show when Claude Code reports them: with a Claude subscription, after a reply."
    end
    for _, r in ipairs(rows) do
        r.value = r.share and (math.floor(math.min(r.share, 9.99) * 100 + 0.5) .. "%") or ""
    end
    return rows, note
end

local function paintPopup()
    createPopup()
    local rows, note = rowsOf()
    lines = {}
    local y = 44
    for i = 1, #RINGS do
        local row = POPUP .. "Row" .. i
        local r = rows[i]
        for _, part in ipairs({ "Title", "Value", "Track", "Fill", "Detail" }) do
            gitgud.setVisible(row .. part, r ~= nil)
        end
        if r then
            lines[#lines + 1] = { title = r.title, value = r.value, detail = r.detail }
            gitgud.setProperty(row .. "Title", "Area", geometry.rect(16, y, 180, 20))
            gitgud.setText(row .. "Title", text.escape(r.title))
            gitgud.setProperty(row .. "Value", "Area", geometry.rect(POPUP_W - 96, y, 80, 20))
            gitgud.setText(row .. "Value", text.escape(r.value))
            local barW = POPUP_W - 32
            gitgud.setVisible(row .. "Track", r.share ~= nil)
            gitgud.setProperty(row .. "Track", "Area", geometry.rect(16, y + 24, barW, 6))
            gitgud.setVisible(row .. "Fill", r.share ~= nil and r.share > 0)
            if r.share then
                local share = math.min(1, r.share)
                gitgud.setProperty(row .. "Fill", "FillColour", colourOf(r.share))
                gitgud.setProperty(row .. "Fill", "Area",
                    geometry.rect(16, y + 24, math.max(8, math.floor(barW * share)), 6))
            end
            gitgud.setVisible(row .. "Detail", r.detail ~= nil)
            gitgud.setProperty(row .. "Detail", "Area", geometry.rect(16, y + 34, POPUP_W - 32, 18))
            gitgud.setText(row .. "Detail", text.escape(r.detail or ""))
            y = y + ROW_H
        end
    end
    gitgud.setVisible(POPUP .. "Note", note ~= nil)
    if note then
        gitgud.setText(POPUP .. "Note", text.escape(note))
        gitgud.setProperty(POPUP .. "Note", "Area", geometry.rect(16, y, POPUP_W - 32, 40))
        y = y + 40
    end
    lines.note = note
    -- Above the circle, its right edge in line with the circle's.
    local bx, by, bw = gitgud.getRect(BUTTON)
    local h = y + 6
    gitgud.setProperty(POPUP, "Area", geometry.rect(0, 0, POPUP_W, h))
    if bx then
        popup.placeAt(POPUP, bx + bw - POPUP_W, by - h - 8)
    end
end

--- The hover text: each known number in a line.
local function tooltip()
    local parts = {}
    for _, r in ipairs((rowsOf())) do
        parts[#parts + 1] = r.title .. (r.value ~= "" and (": " .. r.value) or "")
    end
    parts[#parts + 1] = "Click for details"
    return table.concat(parts, "\n")
end

--- Draw the circle (and the popup, when it's open).
function usage.paint()
    create()
    useAccount()
    local ctx = contextOf()
    shown = {
        context = ctx and ctx.share,
        five_hour = windowOf("five_hour") and windowOf("five_hour").share,
        seven_day = windowOf("seven_day") and windowOf("seven_day").share,
    }
    local any = false
    colours = {}
    for i, ring in ipairs(RINGS) do
        local share = shown[ring.key]
        colours[ring.key] = paintRing(i, share and math.min(1, share))
        any = any or share ~= nil
    end
    visible = any
    gitgud.setVisible(BUTTON, any)
    gitgud.setProperty(BUTTON, "TooltipText", tooltip())
    if popup.isOpen(POPUP) then
        paintPopup()
    end
end

function usage.open()
    usage.paint()
    paintPopup()
    popup.open(POPUP)
end

function usage.close()
    if popup.isOpen(POPUP) then
        popup.close()
    end
end

--- What it shows (for tests): { visible, rings = { context, five_hour,
-- seven_day } (shares, nil when left out), colours (the same keys), open,
-- rows = { { title, value, detail } }, note, tooltip }.
function usage.snapshot()
    return {
        visible = visible,
        rings = { context = shown.context, five_hour = shown.five_hour, seven_day = shown.seven_day },
        colours = { context = colours.context, five_hour = colours.five_hour, seven_day = colours.seven_day },
        open = popup.isOpen(POPUP),
        rows = lines,
        note = lines.note,
        tooltip = gitgud.getProperty(BUTTON, "TooltipText"),
    }
end

-- ===================================================================
-- Events
-- ===================================================================

local function paintSoon()
    gitgud.after(60, usage.paint)
end

local function onRateLimit(detail)
    local e = gitgud.jsonDecode(detail)
    local info = type(e) == "table" and e.info
    if type(info) ~= "table" then
        return
    end
    useAccount()
    local now = usage.clock()
    local windows = type(info.unifiedWindows) == "table" and info.unifiedWindows or nil
    if windows then
        for _, key in ipairs({ "five_hour", "seven_day" }) do
            if type(windows[key]) == "table" then
                limits[key] = { utilization = windows[key].utilization, resetsAt = windows[key].resetsAt, at = now }
            end
        end
    elseif (info.rateLimitType == "five_hour" or info.rateLimitType == "seven_day") and info.utilization then
        -- Without the windows (older versions): the limiting one alone.
        limits[info.rateLimitType] = { utilization = info.utilization, resetsAt = info.resetsAt, at = now }
    end
    save()
    paintSoon()
end

local function tick()
    tickTimer = gitgud.after(TICK_MS, tick)
    usage.paint()
end

-- ===================================================================
-- get_usage, now and then
-- ===================================================================

--- A "2026-10-18T19:00:00Z" time (any offset) in epoch seconds, or nil.
local function isoTime(s)
    local y, mo, d, h, mi, sec, rest = tostring(s or ""):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)(.*)$")
    if not y then
        return nil
    end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    -- Days since 1970-01-01 (the civil calendar, March-based years).
    if mo <= 2 then
        y = y - 1
    end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * ((mo + 9) % 12) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local t = (era * 146097 + doe - 719468) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
    local sign, oh, om = rest:match("([%+%-])(%d%d):?(%d%d)$")
    if sign then
        local offset = tonumber(oh) * 3600 + tonumber(om) * 60
        t = sign == "+" and t - offset or t + offset
    end
    return t
end

usage.clock = os.time

-- The account signed in, read again at most every ACCOUNT_RECHECK_MS
-- (the circle is drawn often; .claude.json can be big).
local ACCOUNT_RECHECK_MS = 30000
local account = { key = nil, at = 0 }
local function accountKey()
    local now = gitgud.now()
    if not account.key or now - account.at > ACCOUNT_RECHECK_MS then
        local id = require("bragi.user").account()
        account.key, account.at = id ~= "" and id or NO_ACCOUNT, now
    end
    return account.key
end

save = function()
    local json = gitgud.jsonEncode(saved)
    if json then
        gitgud.configWrite(LIMITS_FILE, json)
    end
end

--- The account signed in now: its kept limits become the ones shown.
useAccount = function()
    local key = accountKey()
    saved.accounts[key] = type(saved.accounts[key]) == "table" and saved.accounts[key] or {}
    limits = saved.accounts[key]
    return key
end

--- Ask for the usage through a running session, when it's due.
-- @return the request id, or nil when it wasn't asked
function usage.ask(name)
    local key = useAccount()
    local now = usage.clock()
    if not name or (tonumber(limits.asked) and now - limits.asked < ASK_EVERY_S)
        or (tonumber(limits.failed) and now - limits.failed < FAILED_WAIT_S) then
        return nil
    end
    local id = gitgud.agentControl and gitgud.agentControl(name, "get_usage", { skip_behaviors = true })
    if not id then
        return nil
    end
    limits.asked = now
    asking[id] = key
    save()
    return id
end

local function onControl(detail)
    local e = gitgud.jsonDecode(detail)
    local key = type(e) == "table" and asking[e.requestId]
    if not key then
        return
    end
    asking[e.requestId] = nil
    local entry = saved.accounts[key] or {}
    saved.accounts[key] = entry
    local now = usage.clock()
    local rates = e.ok and type(e.response) == "table" and e.response.rate_limits or nil
    if not e.ok then
        entry.failed = now
    elseif type(rates) == "table" then
        entry.failed = nil
        for _, window in ipairs({ "five_hour", "seven_day" }) do
            local w = rates[window]
            if type(w) == "table" and tonumber(w.utilization) then
                -- get_usage says percent; the rate-limit events, a fraction.
                entry[window] = { utilization = tonumber(w.utilization) / 100, resetsAt = isoTime(w.resets_at),
                    at = now }
            end
        end
    end
    save()
    useAccount()
    paintSoon()
end

--- A turn is over (or a session started): ask, when it's due.
local function askAfter(detail)
    local e = gitgud.jsonDecode(detail)
    local name = type(e) == "table" and e.session or nil
    local info = name and gitgud.agentInfo(name)
    if info and info.running and not info.turnActive then
        usage.ask(name)
    end
end

function usage.init()
    local kept = gitgud.jsonDecode(gitgud.configRead(LIMITS_FILE) or "")
    if type(kept) == "table" and type(kept.accounts) == "table" then
        saved = kept
    elseif type(kept) == "table" and (kept.five_hour or kept.seven_day) then
        -- Kept before accounts were: the account signed in now's.
        saved = { accounts = { [accountKey()] = { five_hour = kept.five_hour, seven_day = kept.seven_day } } }
    end
    useAccount()
    gitgud.on("agent.rateLimit", onRateLimit)
    gitgud.on("agent.control", onControl)
    gitgud.on("agent.usage", paintSoon)
    gitgud.on("agent.result", function(detail)
        paintSoon()
        askAfter(detail)
    end)
    gitgud.on("agent.init", askAfter)
    app.subscribe("bragi.tabShown", paintSoon)
    if not tickTimer then
        tickTimer = gitgud.after(TICK_MS, tick)
    end
    usage.paint()
end

return usage
