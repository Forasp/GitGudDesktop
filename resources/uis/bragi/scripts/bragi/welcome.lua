--- bragi/welcome.lua: the Bragi interface's first-time setup, in
-- WelcomeView (layouts/bragi/welcome.xml).
--
-- It starts the first time the Bragi interface runs (picked on the app's
-- first launch, or switched to later), one step per screen, each one
-- skippable. Everything the Bragi interface needs is set up here and only
-- here: the other interfaces never download or set up
-- anything of Bragi's. It asks for no server and no repository: projects
-- are Bragi's (the master conversation) to find when you ask.
--
--   claude    Claude Code found, its version, the claude.ai sign-in; your
--             name (bragi/user.lua: from Claude Code's account when it has
--             one)
--   look      light or dark
--   import    projects and MCP servers from Claude Code and Claude Desktop
--   voice     the voice models (sizes first; downloaded only on the
--             user's OK), then microphone and speakers, a level meter, wake
--             word, closing phrase, the wait (only in a build with the
--             speech engine: see below)
--   training  wake word training and voice enrollment (once voice is
--             available: the models installed)
--   done      what's set up and what was skipped; Talk to Bragi opens
--             the master conversation (bragi/master.lua)
--
-- The voice step shows when the build has the speech engine
-- (bragi/voicemodels.lua, engineInstalled), and is where its models are
-- fetched: sizes shown first, nothing downloaded without the user's OK
-- (Download, or Install from a folder). Replies use Bragi's built-in
-- voice, which comes with the interface. The devices and words follow
-- once the models are installed. Training shows when bragi/voice.lua says voice is
-- available.
--
-- Settings (core/settings.lua):
--   bragi.welcomeDone      finished or skipped; it doesn't start again
--   bragi.welcomeStep      the step showing ("" when it isn't), so a theme
--                          switch (which rebuilds the UI) comes back to it
--   bragi.welcomeSkipped   the steps skipped, "import,voice"
--   bragi.micDevice, bragi.speakerDevice
--                          the devices voice uses ("" = the system default)
--
-- Someone who used Bragi before this existed (it remembered a view) isn't
-- shown it; Settings, Git, "Run again" starts it any time. It doesn't
-- start on its own under the test harness (GITGUD_SCRIPT): scripts call
-- welcome.start(), and welcome.due() says whether it would have.
--
-- The steps are cards built by bragi/settings.lua (bragiSettings.cards),
-- so they look and behave like Settings and share its rows.
--
-- UI tests replace welcome.audio (the device and microphone calls).
--
-- Public API: welcome.start(), welcome.finish(), welcome.showing(),
-- welcome.due(), welcome.step(), welcome.go(id), welcome.next(),
-- welcome.back(), welcome.skip(), welcome.checkClaude(), welcome.claude(),
-- welcome.widget(card, row, part), welcome.meter()

local C = require("core.palette")
local agent = require("bragi.agent")
local app = require("core.app")
local devices = require("bragi.devices")
local settings = require("core.settings")
local shell = require("bragi.shell")
local text = require("core.text")
local ui = require("bragi.ui")

local welcome = { name = "bragi.welcome" }

local MAX_WIDTH = 640   -- the cards' column
local PAD_X = 40        -- bragiSettings.cards' left margin

--- The microphone and speakers, through the bindings. Tests swap these.
welcome.audio = devices.audio

local STEPS = {
    { id = "claude", title = "Claude Code",
      intro = "Bragi talks to you through Claude Code, so it needs Claude Code installed and signed in "
          .. "with your claude.ai subscription." },
    { id = "look", title = "Light or dark",
      intro = "Pick a look. The rail's theme button switches it any time." },
    { id = "import", title = "Bring in your projects",
      intro = "The projects, instructions, memory, and MCP servers you already use with Claude Code and "
          .. "Claude Desktop. Nothing is copied: projects stay where they are." },
    { id = "voice", title = "Talk to Bragi", needsEngine = true,
      intro = "Bragi hears you with speech models that run on this computer. Once they're in, pick the "
          .. "microphone and speakers and check the level, then the words that start a message and end it: "
          .. "pauses never send." },
    { id = "training", title = "Teach Bragi your voice", needsVoice = true,
      intro = "Say the wake word a few times so Bragi learns how it gets misheard, and enroll your "
          .. "voice so Bragi knows it's you. Both are optional." },
    { id = "done", title = "All set",
      intro = "Here's what's set up. Everything here is also in Settings." },
}

local stepIndex = 0     -- 0 while not showing
local built = 0         -- step builds so far (names stay unique)
local claudeState = { state = "idle" }
local picker = nil      -- the microphone and speaker rows (bragi.devices)

--- A step's table by id.
local function stepById(id)
    for i, s in ipairs(STEPS) do
        if s.id == id then
            return i, s
        end
    end
end

local function voiceAvailable()
    return require("bragi.voice").available()
end

--- Steps that apply now (voice needs the engine in this build, training
-- needs voice).
local function applies(s)
    if s.needsEngine then
        return require("bragi.voicemodels").engineInstalled()
    end
    return not s.needsVoice or voiceAvailable()
end

local function skippedList()
    local list = {}
    for id in tostring(settings.get("bragi.welcomeSkipped", "")):gmatch("[^,]+") do
        list[id] = true
    end
    return list
end

local function markSkipped(id, skipped)
    local list = skippedList()
    list[id] = skipped or nil
    local ids = {}
    for _, s in ipairs(STEPS) do
        if list[s.id] then
            ids[#ids + 1] = s.id
        end
    end
    settings.set("bragi.welcomeSkipped", table.concat(ids, ","))
end

-- ---------------------------------------------------------------------
-- Claude Code

--- The claude program: a path as set, else found on PATH; nil if missing.
local function claudeProgram()
    local program = require("bragi.claude").program()
    if program:find("[/\\]") then
        return gitgud.pathExists(program) and program or nil
    end
    return gitgud.findProgram(program)
end

-- startProgram names can't unsubscribe, so each run has a fixed name.
local runs = {}

local function runProgram(name, args, onDone)
    local run = runs[name]
    if not run then
        run = {}
        runs[name] = run
        gitgud.on(name .. ".output", function(detail)
            run.output = run.output .. tostring(detail or "") .. "\n"
        end)
        gitgud.on(name .. ".done", function(code)
            local done = run.onDone
            run.onDone = nil
            if done then
                done(tonumber(code) or -1, run.output)
            end
        end)
    end
    run.output = ""
    run.onDone = onDone
    local ok = gitgud.startProgram(name, args)
    if not ok then
        run.onDone = nil
        onDone(-1, "")
    end
end

local build

local function rebuild()
    if stepIndex > 0 then
        build()
    end
end

--- Check Claude Code again: found, version, sign-in.
function welcome.checkClaude()
    local path = claudeProgram()
    if not path then
        claudeState = { state = "missing" }
        rebuild()
        return
    end
    claudeState = { state = "checking", path = path }
    rebuild()
    runProgram("BragiWelcomeClaudeVersion", { path, "--version" }, function(_, out)
        claudeState.version = out:match("(%d[%w%.%-]*)")
        runProgram("BragiWelcomeClaudeAuth", { path, "auth", "status" }, function(_, auth)
            local status = gitgud.jsonDecode(auth:match("{.*}") or "")
            claudeState.auth = type(status) == "table" and status or nil
            claudeState.state = claudeState.version and "ok" or "broken"
            rebuild()
        end)
    end)
end

--- What the last check found (for tests and the summary).
function welcome.claude()
    return claudeState
end

local function signInClaude()
    local path = claudeProgram() or require("bragi.claude").program()
    gitgud.spawn('"' .. path .. '" auth login --claudeai')
end

local function claudeCards()
    local rows = {}
    local s = claudeState
    if s.state == "missing" then
        rows[#rows + 1] = { kind = "info", title = "Claude Code isn't installed",
            sub = "Install Claude Code, make sure `claude` runs in a terminal, then check again." }
    elseif s.state == "checking" or s.state == "idle" then
        rows[#rows + 1] = { kind = "info", title = "Checking Claude Code", sub = "Looking for `claude`..." }
    elseif s.state == "broken" then
        rows[#rows + 1] = { kind = "info", title = "Claude Code didn't answer",
            sub = "Found " .. tostring(s.path) .. ", but `claude --version` gave nothing. Reinstall it, then check again." }
    else
        rows[#rows + 1] = { kind = "info", title = "Claude Code " .. s.version, sub = tostring(s.path) }
        local auth = s.auth or {}
        if auth.loggedIn and auth.authMethod == "claude.ai" then
            local plan = auth.subscriptionType and (" (" .. tostring(auth.subscriptionType) .. ")") or ""
            rows[#rows + 1] = { kind = "info", title = "Signed in with claude.ai" .. plan,
                sub = "Connectors, synced skills, and plugins load in your sessions." }
        elseif auth.loggedIn then
            rows[#rows + 1] = { kind = "action", title = "Signed in with an API key",
                sub = "Connectors, synced skills, and plugins need the claude.ai subscription sign-in.",
                button = "Sign in", primary = true, run = signInClaude }
        else
            rows[#rows + 1] = { kind = "action", title = "Not signed in",
                sub = "Sign in with your claude.ai subscription. A window opens and finishes in your browser.",
                button = "Sign in", primary = true, run = signInClaude }
        end
    end
    rows[#rows + 1] = { kind = "action", title = "Check again", sub = "After installing or signing in.",
        button = "Check again", run = welcome.checkClaude }
    return { { heading = "Claude Code", rows = rows }, require("bragi.settings").youCard() }
end

-- ---------------------------------------------------------------------
-- Voice

--- The level meter's state (for tests): { on, level, error }.
function welcome.meter()
    return picker.meter()
end

-- The card showing an install's progress in the voice step (its first
-- row's sub), or nil.
local progressCard = nil

local function voiceCards()
    local models = require("bragi.voicemodels")
    -- The engine's cards: the models.
    local cards = models.cards()
    progressCard = nil
    for i, card in ipairs(cards) do
        if card.progress then
            progressCard = i
        end
    end
    if not models.installed() then
        return cards
    end
    local rest = {
        { heading = "Devices", rows = picker.rows() },
        { heading = "Words", rows = {
            { kind = "input", title = "Wake word", sub = "Say it to start a message.",
              key = "bragi.wakeWord", default = "Bragi" },
            { kind = "input", title = "Closing phrase", sub = "Say it to send. Pauses never send.",
              key = "bragi.closingPhrase", default = "over and out" },
            { kind = "input", title = "Wait when you seem done",
              sub = "When you seem finished, Bragi waits this many seconds (2 to 10), then goes ahead.",
              key = "bragi.endWaitSeconds", default = "3", number = true },
            { kind = "toggle", title = "Listen for the wake word",
              sub = "The mic button in the Agent view turns it on and off too.", key = "bragi.listen", default = false },
        } },
    }
    for _, card in ipairs(rest) do
        cards[#cards + 1] = card
    end
    return cards
end

-- ---------------------------------------------------------------------
-- Done

local function summaryCards()
    local skipped = skippedList()
    local rows = {}
    local s = claudeState
    local claudeSub
    if s.state == "ok" then
        local auth = s.auth or {}
        claudeSub = "Version " .. s.version .. ", "
            .. ((auth.loggedIn and auth.authMethod == "claude.ai") and "signed in with claude.ai."
                or (auth.loggedIn and "signed in with an API key." or "not signed in yet: Settings, Claude."))
    elseif s.state == "missing" then
        claudeSub = "Not installed yet. Install it, then Settings, Claude."
    else
        claudeSub = "Not checked."
    end
    rows[#rows + 1] = { kind = "info", title = "Claude Code", sub = claudeSub }
    rows[#rows + 1] = { kind = "info", title = "Look", sub = gitgud.theme() == "light" and "Light." or "Dark." }

    local known = #require("views.repositories").known()
    rows[#rows + 1] = { kind = "info", title = "Projects",
        sub = known == 0 and "None yet. Ask Bragi to work on one: it finds it on this computer."
            or (known == 1 and "1 in your list." or (known .. " in your list.")) }

    local voiceSub
    local models = require("bragi.voicemodels")
    if not models.engineInstalled() then
        voiceSub = "Not part of this build. Type to Bragi."
    elseif not voiceAvailable() then
        voiceSub = "The voice models aren't installed yet: Settings, Appearance and voice."
    elseif skipped.voice then
        voiceSub = "Skipped. Settings, Appearance and voice."
    else
        local closing = settings.get("bragi.closingPhrase", "over and out")
        voiceSub = "Wake word \"" .. settings.get("bragi.wakeWord", "Bragi") .. "\", "
            .. (closing ~= "" and ("closing phrase \"" .. closing .. "\".") or "Send button only.")
        if settings.get("bragi.wakeThreshold", "") ~= "" then
            voiceSub = voiceSub .. " Wake word trained."
        end
    end
    rows[#rows + 1] = { kind = "info", title = "Voice", sub = voiceSub }
    local name = require("bragi.user").current()
    rows[#rows + 1] = { kind = "info", title = "You",
        sub = name ~= "" and ("Bragi calls you " .. name .. ".") or "No name: Bragi says \"the user\"." }

    return {
        { heading = "Set up", rows = rows },
        { heading = "Next", rows = {
            { kind = "action", title = "Talk to Bragi",
              sub = "Say what you'd like to work on. Bragi finds the project, or clones it, and starts there.",
              button = "Talk to Bragi", primary = true, run = welcome.talk },
        } },
    }
end

-- ---------------------------------------------------------------------
-- Building and moving

local function cardsFor(s)
    if s.id == "claude" then
        return claudeCards()
    elseif s.id == "look" then
        return { { heading = "Theme", rows = { { kind = "themes" } } } }
    elseif s.id == "import" then
        return require("bragi.import").cards()
    elseif s.id == "voice" then
        return voiceCards()
    elseif s.id == "training" then
        return require("bragi.training").cards()
    end
    return summaryCards()
end

--- Visible steps and where the current one sits among them.
local function position()
    local n, at = 0, 0
    for i, s in ipairs(STEPS) do
        if applies(s) then
            n = n + 1
            if i == stepIndex then
                at = n
            end
        end
    end
    return at, n
end

build = function()
    local s = STEPS[stepIndex]
    if built > 0 then
        gitgud.destroyWindow("WelcomeStep" .. built)
    end
    built = built + 1
    local root = "WelcomeStep" .. built
    local _, _, bodyW = gitgud.getRect("WelcomeBody")
    bodyW = bodyW or 900
    local width = math.max(360, math.min(MAX_WIDTH, bodyW - 2 * PAD_X - 32))
    gitgud.createWindow("DefaultWindow", root, "WelcomeBody")

    ui.label(root .. "Title", root, { PAD_X, 36, width, 32 }, s.title, { font = "Bragi-20-Bold" })
    -- About 7px a character at 14px.
    local lines = math.max(1, math.ceil(#s.intro * 7 / width))
    local introH = lines * 22
    ui.paragraph(root .. "Intro", root, { PAD_X, 76, width, introH + 4 }, s.intro, { colour = C.sub })
    local y = require("bragi.settings").cards(root, cardsFor(s), width, 76 + introH + 24)

    local total = width + 2 * PAD_X
    local x = math.max(0, math.floor((bodyW - total) / 2))
    gitgud.setProperty(root, "Area", string.format("{{0,%d},{0,0},{0,%d},{0,%d}}", x, x + total, y + 16))

    local at, n = position()
    gitgud.setText("WelcomeStepLabel", text.escape("Step " .. at .. " of " .. n))
    gitgud.setVisible("WelcomeBack", at > 1)
    gitgud.setVisible("WelcomeSkip", s.id ~= "done")
    gitgud.setVisible("WelcomeSkipAll", s.id ~= "done")
    gitgud.setText("WelcomeNext", s.id == "done" and "Start" or "Next")
end

--- Show a step by id (one that doesn't apply moves on to the next that does).
function welcome.go(id)
    local i = stepById(id) or 1
    while STEPS[i] and not applies(STEPS[i]) do
        i = i + 1
    end
    i = math.min(i, #STEPS)
    if STEPS[stepIndex] and STEPS[stepIndex].id == "voice" and STEPS[i].id ~= "voice" then
        picker.setMeter(false)
    end
    stepIndex = i
    local s = STEPS[i]
    settings.set("bragi.welcomeStep", s.id)
    gitgud.setVisible("WelcomeView", true)
    if s.id == "claude" then
        require("bragi.user").offer()
    end
    if (s.id == "claude" or s.id == "done") and claudeState.state == "idle" then
        welcome.checkClaude() -- builds
        return
    end
    if s.id == "import" then
        settings.set("bragi.importOffered", true)
    end
    build()
end

--- The step showing, or nil.
function welcome.step()
    return STEPS[stepIndex] and STEPS[stepIndex].id or nil
end

function welcome.showing()
    return stepIndex > 0
end

function welcome.next()
    local s = STEPS[stepIndex]
    if not s then
        return
    end
    if s.id == "done" then
        welcome.finish()
        return
    end
    markSkipped(s.id, false)
    welcome.go(STEPS[stepIndex + 1].id)
end

function welcome.back()
    local i = stepIndex - 1
    while i > 1 and not applies(STEPS[i]) do
        i = i - 1
    end
    if i >= 1 then
        welcome.go(STEPS[i].id)
    end
end

function welcome.skip()
    local s = STEPS[stepIndex]
    if not s or s.id == "done" then
        return
    end
    markSkipped(s.id, true)
    welcome.go(STEPS[stepIndex + 1].id)
end

--- Start from the first step (Settings, "Run again").
function welcome.start()
    settings.set("bragi.welcomeSkipped", "")
    claudeState = { state = "idle" }
    welcome.go("claude")
end

--- Close it and open the master conversation (the done step's action).
function welcome.talk()
    welcome.finish()
    require("bragi.master").open()
end

--- Close it, remembered as done.
function welcome.finish()
    if picker then
        picker.setMeter(false)
    end
    settings.set("bragi.welcomeDone", true)
    settings.set("bragi.welcomeStep", "")
    stepIndex = 0
    gitgud.setVisible("WelcomeView", false)
    shell.show("agent")
end

--- Whether it should start on its own now: never finished, and Bragi
-- hasn't run here before.
function welcome.due()
    return not settings.get("bragi.welcomeDone", false) and not shell.returning()
end

--- A row's widget in the step showing (for tests), as bragiSettings.widget.
function welcome.widget(card, row, part)
    return "WelcomeStep" .. built .. "C" .. card .. "R" .. row .. part
end

function welcome.init()
    picker = devices.new({ audio = function()
        return welcome.audio
    end, rebuild = rebuild })
    gitgud.on("WelcomeNext.clicked", welcome.next)
    gitgud.on("WelcomeBack.clicked", welcome.back)
    gitgud.on("WelcomeSkip.clicked", welcome.skip)
    gitgud.on("WelcomeSkipAll.clicked", function()
        local s = STEPS[stepIndex]
        for i = stepIndex, #STEPS - 1 do
            markSkipped(STEPS[i].id, true)
        end
        if s then
            welcome.go("done")
        end
    end)
    gitgud.on("window.resized", rebuild)

    app.subscribe("bragi.section", function(section)
        local s = STEPS[stepIndex]
        if s and s.id == section then
            build()
        end
    end)
    -- The voice models' install: a new step rebuilds the voice step,
    -- progress just updates its first line.
    local phase = nil
    app.subscribe("bragi.voiceModels", function(m)
        local s = STEPS[stepIndex]
        if not s or s.id ~= "voice" then
            phase = m.phase
            return
        end
        if m.phase == phase and m.phase ~= "idle" and m.phase ~= "done" and m.phase ~= "failed" then
            require("bragi.settings").paintProgress()
            return
        end
        phase = m.phase
        gitgud.after(0, rebuild)
    end)
    app.subscribe("bragi.voiceAvailable", function()
        gitgud.after(0, rebuild)
    end)

    -- Coming back after a theme switch, or the first time Bragi runs.
    local resume = settings.get("bragi.welcomeStep", "")
    if resume ~= "" and not settings.get("bragi.welcomeDone", false) then
        welcome.go(resume)
    elseif welcome.due() then
        if os.getenv("GITGUD_SCRIPT") then
            return
        end
        welcome.go("claude")
    elseif not settings.get("bragi.welcomeDone", false) then
        settings.set("bragi.welcomeDone", true) -- Bragi ran here before setup existed
    end
end

function welcome.refresh()
end

return welcome
