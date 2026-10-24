--- tests/ui/bragi-welcome.lua: the Bragi interface's first-time setup:
-- every step (Claude Code missing, signed in, signed out, on an API key;
-- light or dark, which rebuilds the UI and comes back to the step; import;
-- with a speech engine, the voice models (sizes shown, nothing downloaded
-- until Download, progress, Stop), Baldr offered on every computer (said
-- plainly to be slow without an NVIDIA GPU; its size; skippable), the GPU
-- libraries only with a GPU (the same flow), then installed: Baldr made and
-- used without asking, on the processor without the GPU libraries and on
-- the GPU with them, no voice step; then microphone, speakers, and the level
-- meter, and training; the summary), Back, Skip, Skip setup, and "Run
-- again" from Settings. It asks for no server and no repository; without a
-- speech engine the voice steps aren't offered.
--
-- Run it like bragi-agent.lua: GITGUD_UI=bragi, a scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT
-- pointing here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE set to
-- build\release\bin\gitgud_test_claude.exe, and CLAUDE_CONFIG_DIR set to a
-- scratch folder. The speech engine and the audio devices are
-- stand-ins. The theme switch runs this script again, so it keeps its
-- phase in a config file. Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."
local PHASE_FILE = "bragi-welcome-test-phase"

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
local config = os.getenv("CLAUDE_CONFIG_DIR")
local appData = os.getenv("APPDATA")
if gitgud.currentUi().id ~= "bragi" or not fake or not config or not appData
    or not appData:lower():find("sandbox", 1, true) then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR, and a scratch APPDATA", false)
    gitgud.emit("window.close", "")
    return
end

local app = require("core.app")
local bragiSettings = require("bragi.settings")
local settings = require("core.settings")
local shell = require("bragi.shell")
local voice = require("bragi.voice")
local voicemodels = require("bragi.voicemodels")
local welcome = require("bragi.welcome")

-- ===================================================================
-- Stand-ins
-- ===================================================================

-- Whether a speech engine is there (kept across the theme switch).
local engine = settings.get("test.voiceEngine", false)
local function setEngine(on)
    engine = on
    settings.set("test.voiceEngine", on)
end
voicemodels.engine = function()
    return { installed = engine }
end
-- The GPU: none (the usual flow), or one the voice pack runs on.
local gpu = { present = false, devices = {} }
voicemodels.gpu = function()
    return gpu
end
local realMissing = voicemodels.missing
local made = {} -- voices the engine was asked to make
local setups = {} -- what the engine was set up with

-- Downloads asked for (none really start).
local downloads = {}
local cancels = 0
gitgud.downloadFile = function(task, spec)
    downloads[#downloads + 1] = { task = task, url = spec.url, sha256 = spec.sha256, size = spec.size }
    return true
end
gitgud.downloadCancel = function(task)
    if task == "BragiVoiceDownload" then
        cancels = cancels + 1
    end
end

local used = {}
local tests = {}
welcome.audio = {
    devices = function()
        return {
            inputs = { { id = "mic1", name = "Desk mic", default = true }, { id = "mic2", name = "Headset" } },
            outputs = { { id = "spk1", name = "Speakers", default = true } },
        }
    end,
    use = function(input, output)
        used[#used + 1] = { input = input, output = output }
    end,
    test = function(on)
        tests[#tests + 1] = on
        return true
    end,
}

local function recorder()
    return function()
        return true
    end
end
voice.backend = {
    available = function()
        return engine
    end,
    listen = recorder(), stop = recorder(), send = recorder(), lookback = recorder(), speak = recorder(),
    speakStop = recorder(), playing = function()
        return nil
    end, config = recorder(), train = recorder(), enroll = recorder(),
}

local function setAuth(state)
    local path = config .. "/fake-auth"
    if state then
        local f = io.open(path, "wb")
        f:write(state .. "\n")
        f:close()
    else
        os.remove(path)
    end
end

-- ===================================================================
-- Helpers
-- ===================================================================

local function shot(name)
    gitgud.screenshot(OUT .. "/welcome-" .. name .. ".png")
end
local function clickWidget(name)
    -- A step's widget below the fold: the step scrolls to it first.
    if name:find("^WelcomeStep") then
        local bx, by, bw, bh = gitgud.getRect("WelcomeBody")
        for _ = 1, 40 do
            local _, wy, _, wh = gitgud.getRect(name)
            if not wy or (wy >= by and wy + wh <= by + bh) then
                break
            end
            gitgud.simulateScroll(bx + bw / 2, by + bh / 2, wy < by and 1 or -1)
        end
    end
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function visible(name)
    return gitgud.getProperty(name, "Visible") == "true"
end
local function textOf(card, row, part)
    return gitgud.getText(welcome.widget(card, row, part)) or ""
end
local function title()
    for n = 400, 1, -1 do
        if gitgud.getRect("WelcomeStep" .. n .. "Title") then
            return gitgud.getText("WelcomeStep" .. n .. "Title")
        end
    end
    return ""
end
local function phase()
    return (gitgud.configRead(PHASE_FILE) or ""):match("%S+") or "first"
end

-- ===================================================================
-- Phase 1: Claude Code, then the theme switch
-- ===================================================================

if phase() == "first" then
    step(800, "not started under the harness, but due", function()
        -- A hot reload (resources synced by a build just before) runs this
        -- script again with setup already resumed: start over.
        -- (The first run already checked `due`: Bragi has run before now.)
        local reloaded = welcome.showing()
        if reloaded then
            welcome.finish()
            settings.set("bragi.welcomeDone", nil)
        end
        check("due on a fresh profile", reloaded or welcome.due())
        check("not started on its own under the harness", not welcome.showing())
        check("the welcome view is hidden", not visible("WelcomeView"))
        local devices = gitgud.audioDevices()
        check("audioDevices lists inputs and outputs",
            type(devices) == "table" and type(devices.inputs) == "table" and type(devices.outputs) == "table")
    end)

    step(100, "Claude Code missing", function()
        -- Claude Code's account has a name: setup offers it.
        settings.set("bragi.userName", nil)
        local f = io.open(config .. "/.claude.json", "wb")
        f:write(gitgud.jsonEncode({ oauthAccount = { displayName = "Sam" } }))
        f:close()
        settings.set("bragi.claudeProgram", appData .. "\\no-claude-here.exe")
        welcome.start()
    end)
    step(500, "missing shows how to fix it", function()
        check("starts at Claude Code", welcome.step() == "claude" and visible("WelcomeView"))
        check("step 1 of 4 without a speech engine (no voice steps)",
            gitgud.getText("WelcomeStepLabel") == "Step 1 of 4")
        check("missing: says it isn't installed", textOf(1, 1, "Title") == "Claude Code isn't installed")
        check("Back hidden on the first step", not visible("WelcomeBack"))
        check("it asks your name", textOf(2, 1, "Title") == "Your name")
        check("filled in from Claude Code's account", settings.get("bragi.userName", "") == "Sam"
            and gitgud.getText(welcome.widget(2, 1, "InputEdit")) == "Sam")
        local user = require("bragi.user")
        check("the prompts say it", user.fill("{User} asked; tell {user}.") == "Sam asked; tell Sam.")
        settings.set("bragi.userName", "")
        check("no name: the user", user.label() == "the user"
            and user.fill("{User} asked; tell {user}.") == "The user asked; tell the user.")
        user.offer()
        check("a cleared name stays cleared", user.current() == "")
        settings.set("bragi.userName", "Sam")
        shot("claude-missing")
    end)

    step(100, "Check again finds the fake", function()
        settings.set("bragi.claudeProgram", fake)
        setAuth(nil)
        clickWidget(welcome.widget(1, 2, "Action"))
    end)
    step(2500, "signed in with claude.ai", function()
        check("version shown", textOf(1, 1, "Title") == "Claude Code 0.0.0-fake")
        check("claude.ai sign-in shown", textOf(1, 2, "Title") == "Signed in with claude.ai (max)")
        shot("claude-ok")
    end)
    step(300, "after the claude-ok shot", function()
        setAuth("out")
        welcome.checkClaude()
    end)
    step(2500, "signed out", function()
        check("signed out: asks to sign in", textOf(1, 2, "Title") == "Not signed in"
            and gitgud.getText(welcome.widget(1, 2, "Action")) == "Sign in")
        shot("claude-signed-out")
    end)
    step(300, "after the claude-signed-out shot", function()
        setAuth("api")
        welcome.checkClaude()
    end)
    step(2500, "API key", function()
        check("API key: asks for the subscription sign-in", textOf(1, 2, "Title") == "Signed in with an API key")
        setAuth(nil)
        welcome.checkClaude()
    end)
    step(2500, "Next to the look", function()
        clickWidget("WelcomeNext")
    end)
    step(400, "the look step", function()
        check("look step", welcome.step() == "look" and title() == "Light or dark")
        check("Back shows from step 2", visible("WelcomeBack"))
        check("the step is remembered", settings.get("bragi.welcomeStep", "") == "look")
        shot("look-" .. gitgud.theme())
    end)
    step(300, "after the " .. "look-" .. gitgud.theme() .. " shot", function()
        gitgud.configWrite(PHASE_FILE, "second " .. gitgud.theme())
        local other = gitgud.theme() == "light" and "dark" or "light"
        clickWidget(welcome.widget(1, 1, "Theme" .. other))
    end)

    harness.run()
    return
end

-- ===================================================================
-- Phase 2: back after the theme switch; the rest of the steps
-- ===================================================================

local before = (gitgud.configRead(PHASE_FILE) or ""):match("second (%a+)")

step(800, "back at the look step in the other theme", function()
    check("the theme switched", before ~= nil and gitgud.theme() ~= before)
    check("setup came back at the look step", welcome.showing() and welcome.step() == "look")
    shot("look-" .. gitgud.theme())
end)
step(300, "after the " .. "look-" .. gitgud.theme() .. " shot", function()
    clickWidget("WelcomeNext")
end)

step(600, "import step", function()
    check("no server step: import comes next", welcome.step() == "import" and title() == "Bring in your projects")
    check("four steps without a speech engine", gitgud.getText("WelcomeStepLabel") == "Step 3 of 4")
    check("the passing import note won't show", settings.get("bragi.importOffered", false))
    shot("import")
end)
step(300, "after the import shot", function()
    setEngine(true)
    welcome.go("import")
end)
step(300, "with a speech engine", function()
    check("six steps with a speech engine", gitgud.getText("WelcomeStepLabel") == "Step 3 of 6")
    clickWidget("WelcomeNext")
end)

step(400, "voice step: the models first", function()
    check("voice step", welcome.step() == "voice")
    check("the models card comes first", textOf(1, 1, "Title") == "Voice models")
    check("their download size shows", textOf(1, 1, "Sub"):find("about 602 MB to download", 1, true) ~= nil)
    check("and their size on disk", textOf(1, 1, "Sub"):find("784 MB on disk", 1, true) ~= nil)
    check("each model with its size", textOf(1, 2, "Title") == "Speech detection, 644 KB"
        and textOf(1, 4, "Title") == "Speech recognition, 482 MB")
    check("what it does, naming no product", textOf(1, 4, "Sub") == "Turns what you say into text.")
    check("Baldr is offered too", textOf(2, 1, "Title") == "Replies in Baldr, Bragi's own voice")
    check("saying plainly it's slow without an NVIDIA GPU", textOf(2, 1, "Sub"):find(
        "runs on the processor and Baldr is slow here", 1, true) ~= nil)
    check("with its size, and that it can be skipped", textOf(2, 1, "Sub"):find("The model is about 725 MB to download", 1, true)
        ~= nil and textOf(2, 1, "Sub"):find("you can skip this", 1, true) ~= nil)
    check("no GPU libraries without a GPU", textOf(3, 1, "Title") == "")
    check("no devices before the models", textOf(3, 1, "Choice") == "")
    check("nothing downloaded yet", #downloads == 0)
    check("Download and Install from a folder", textOf(1, 6, "Action") == "Download"
        and textOf(1, 7, "Action") == "Choose folder")
    check("the download names no host", textOf(1, 6, "Sub") == "602 MB, from the models' publishers.")
    check("Bragi's voice: the model is the download, Baldr is made here", textOf(2, 2, "Title")
        == "Download Bragi's voice" and textOf(2, 2, "Sub") == "725 MB. Bragi then makes its Baldr voice on this computer.")
    local all = ""
    for c = 1, 2 do
        for r = 1, 8 do
            all = all .. " " .. textOf(c, r, "Title") .. " " .. textOf(c, r, "Sub")
        end
    end
    check("no hosting service or product named", not all:find("Hugging", 1, true) and not all:find("GitHub", 1, true)
        and not all:find("PyPI", 1, true) and not all:find("Chatterbox", 1, true) and not all:find("Parakeet", 1, true)
        and not all:find("sherpa", 1, true))
    shot("voice-models")
end)
step(300, "after the voice-models shot", function()
    clickWidget(welcome.widget(1, 6, "Action"))
end)
step(300, "Download", function()
    check("one download started", #downloads == 1)
    check("the first model, pinned", downloads[1] and downloads[1].url:find("/asr%-models/silero_vad%.onnx$") ~= nil
        and downloads[1].sha256 == voicemodels.PACKAGES[1].sha256 and downloads[1].size == 643854)
    check("the card shows the install", textOf(1, 1, "Title") == "Installing the voice models")
    gitgud.emit(downloads[1].task .. ".progress", gitgud.jsonEncode({ phase = "download", done = 300000, total = 643854 }))
end)
step(200, "progress", function()
    check("progress shows", textOf(1, 1, "Sub") == "Downloading speech detection: 300 KB of 644 KB (46%), 1 of 4.")
    local bars = bragiSettings.progressBars()
    check("with its bar", #bars == 1 and math.abs((bars[1].fraction or 0) - 300000 / 643854) < 1e-6)
    check("Stop shows", textOf(1, 2, "Action") == "Stop")
    clickWidget(welcome.widget(1, 2, "Action"))
end)
step(200, "Stop", function()
    check("Stop cancels the download", cancels == 1)
    gitgud.emit(downloads[1].task .. ".error", "cancelled")
end)
step(300, "stopped", function()
    check("back to the models card", textOf(1, 1, "Title") == "Voice models" and textOf(1, 6, "Action") == "Download")
    check("no second download", #downloads == 1)
    -- An NVIDIA GPU the GPU libraries run on.
    gpu = { present = true, driver = "610.88", cuda = 13030,
        devices = { { name = "Test GPU 12 GB", memory = 12e9 } } }
    app.publish("bragi.voiceAvailable")
end)
step(400, "with an NVIDIA GPU", function()
    check("Baldr on the GPU", textOf(2, 1, "Sub"):find("on your NVIDIA GPU", 1, true) ~= nil)
    check("the GPU libraries follow", textOf(3, 1, "Title") == "Baldr on Test GPU 12 GB")
    check("with the sizes", textOf(3, 1, "Sub"):find("About 2.4 GB to download with Bragi's voice model", 1, true)
        ~= nil)
    check("naming no host or product", not textOf(3, 1, "Sub"):find("PyPI", 1, true)
        and not textOf(3, 1, "Sub"):find("GitHub", 1, true) and not textOf(3, 1, "Sub"):find("sherpa", 1, true))
    check("and NVIDIA's terms", textOf(3, 1, "Sub"):find("under NVIDIA's license terms", 1, true) ~= nil)
    check("still nothing downloaded", #downloads == 1)
    shot("voice-gpu")
end)
step(300, "after the voice-gpu shot", function()
    clickWidget(welcome.widget(3, 2, "Action"))
end)
step(300, "the GPU libraries download", function()
    check("their first download started", #downloads == 2
        and downloads[2].url:find("/v1.13.8/sherpa%-onnx%-v1.13.8%-cuda%-13.x") ~= nil
        and downloads[2].size == 478110488)
    check("their card shows the install", textOf(3, 1, "Title") == "Installing the GPU libraries")
    gitgud.emit(downloads[2].task .. ".progress", gitgud.jsonEncode({ phase = "download", done = 239055244,
        total = 478110488 }))
end)
step(200, "GPU libraries progress", function()
    check("progress in their card", textOf(3, 1, "Sub")
        == "Downloading the GPU speech engine: 239 MB of 478 MB (50%), 1 of 9.")
    clickWidget(welcome.widget(3, 2, "Action"))
end)
step(200, "GPU libraries stopped", function()
    check("Stop cancels it", cancels == 2)
    gitgud.emit(downloads[2].task .. ".error", "cancelled")
end)
step(300, "back to the offer", function()
    check("offered again", textOf(3, 1, "Title") == "Baldr on Test GPU 12 GB")
    -- No GPU, and the models and Baldr's model as if installed: Baldr is
    -- made from the interface's recording without asking (the engine's
    -- part stood in for here), on the processor.
    gpu = { present = false, devices = {} }
    voicemodels.missing = function(groups)
        if groups == nil or groups == "listen" or groups == "turbo" then
            return {}
        end
        return realMissing(groups)
    end
    gitgud.voiceMakeVoice = function(task, wav, name)
        made[#made + 1] = { wav = wav, name = name }
        gitgud.localDataWrite("bragi/voice/voices/" .. name .. ".voice", "stand-in conditioning")
        gitgud.emit(task .. ".done", gitgud.jsonEncode({ ok = true, seconds = 17.6 }))
        return true
    end
    gitgud.voiceEngineSetup = function(settings)
        setups[#setups + 1] = settings
        return true
    end
    app.publish("bragi.voiceAvailable")
end)
step(600, "Baldr, on the processor", function()
    check("Baldr was made once, from the interface's recording", #made == 1 and made[1].name == "baldr"
        and made[1].wav:find("voices[/\\]baldr[/\\]ref%.wav$") ~= nil)
    check("Baldr is the first made voice", voicemodels.voices()[1] ~= nil
        and voicemodels.voices()[1].id == "turbo:baldr")
    check("without being chosen", settings.get("bragi.voice", "") == "")
    check("Turbo set up on the processor", #setups > 0 and setups[#setups].tts ~= nil
        and setups[#setups].tts.provider == "cpu" and setups[#setups].tts.threads == 8
        and setups[#setups].gpuDir == nil)
    check("its card says so", textOf(2, 1, "Title") == "Baldr" and textOf(2, 1, "Sub")
        == "Installed. Bragi can answer in Baldr on the processor: slower than the built-in voice.")
    check("no voice to make in setup", textOf(3, 1, "Title") ~= "Voice for replies")
    shot("voice-baldr-cpu")
end)
step(300, "after the voice-baldr-cpu shot", function()
    -- With the GPU libraries in too.
    gpu = { present = true, driver = "610.88", cuda = 13030,
        devices = { { name = "Test GPU 12 GB", memory = 12e9 } } }
    voicemodels.missing = function()
        return {}
    end
    voicemodels.configure()
    app.publish("bragi.voiceAvailable")
end)
step(400, "Baldr, on the GPU", function()
    check("Turbo set up on the GPU", setups[#setups].tts ~= nil and setups[#setups].tts.provider == "cuda"
        and setups[#setups].tts.threads == 4 and setups[#setups].tts.cpuThreads == 8
        and setups[#setups].gpuDir ~= nil and setups[#setups].speakerProvider == nil)
    check("Baldr's card says so", textOf(2, 1, "Sub") == "Installed. Bragi answers in Baldr, its own voice, on the GPU.")
    check("the GPU libraries' card", textOf(3, 1, "Title") == "GPU libraries"
        and textOf(3, 1, "Sub") == "Installed. Baldr runs on Test GPU 12 GB.")
    check("Baldr made only once", #made == 1)
    shot("voice-baldr-gpu")
end)
step(300, "after the voice-baldr-gpu shot", function()
    -- No GPU again, the models as if installed and Baldr's model not: the
    -- devices and words follow Baldr's offer.
    gpu = { present = false, devices = {} }
    voicemodels.missing = function(groups)
        if groups == nil or groups == "listen" then
            return {}
        end
        return realMissing(groups)
    end
    app.publish("bragi.voiceAvailable")
end)
step(400, "voice step with the models", function()
    check("the models card says installed", textOf(1, 1, "Title") == "Voice models")
    check("microphone choice shows the default", textOf(3, 1, "Choice") == "System default")
    clickWidget(welcome.widget(3, 3, "Action"))
end)
step(300, "level meter", function()
    check("the meter started the microphone", tests[#tests] == true and welcome.meter().on)
    gitgud.emit("audio.level", "0.5")
end)
step(200, "the bar follows the level", function()
    local _, _, trackW = gitgud.getRect(welcome.widget(3, 3, "Track"))
    local _, _, fillW = gitgud.getRect(welcome.widget(3, 3, "Fill"))
    check("the bar is about half", trackW and fillW and math.abs(fillW - trackW / 2) <= 2)
    shot("voice")
end)
step(300, "after the voice shot", function()
    settings.set("bragi.micDevice", "mic2")
    app.publish("bragi.choices")
end)
step(200, "picking a microphone", function()
    check("the picked microphone goes to the audio layer", used[#used].input == "mic2")
    check("its name shows", textOf(3, 1, "Choice") == "Headset")
    clickWidget("WelcomeNext")
end)

step(400, "training step, skipped", function()
    check("leaving voice stopped the microphone", tests[#tests] == false and not welcome.meter().on)
    check("training step", welcome.step() == "training")
    shot("training")
end)
step(300, "after the training shot", function()
    clickWidget("WelcomeSkip")
end)

step(2500, "the summary", function()
    check("done step", welcome.step() == "done" and title() == "All set")
    check("summary: Claude Code", textOf(1, 1, "Sub") == "Version 0.0.0-fake, signed in with claude.ai.")
    check("summary: projects", textOf(1, 3, "Title") == "Projects")
    check("summary: voice", textOf(1, 4, "Sub"):find("Wake word \"Bragi\"", 1, true) ~= nil)
    check("summary: the name", textOf(1, 5, "Sub") == "Bragi calls you Sam.")
    check("training recorded as skipped", settings.get("bragi.welcomeSkipped", "") == "training")
    check("Next reads Start, Skip hidden", gitgud.getText("WelcomeNext") == "Start" and not visible("WelcomeSkip"))
    check("next: Talk to Bragi", textOf(2, 1, "Title") == "Talk to Bragi" and textOf(2, 1, "Action") == "Talk to Bragi")
    shot("done")
end)
step(300, "after the done shot", function()
    clickWidget("WelcomeBack")
end)
step(300, "Back from the summary", function()
    check("Back goes to training", welcome.step() == "training")
    clickWidget("WelcomeNext")
end)
-- Apart from the last click on the same spot, or it reads as a double-click.
step(800, "Start", function()
    check("Next from training comes back to the summary", welcome.step() == "done")
    clickWidget("WelcomeNext")
end)
step(300, "finished", function()
    check("setup closed", not welcome.showing() and not visible("WelcomeView"))
    check("remembered as done", settings.get("bragi.welcomeDone", false) and not welcome.due())
    check("lands in the Agent view", shell.view() == "agent")
    check("the step is cleared", settings.get("bragi.welcomeStep", "x") == "")
end)

-- Run again from Settings, without a speech engine, skipping everything.
step(200, "Settings, Git", function()
    setEngine(false)
    bragiSettings.open("git")
end)
step(400, "Run again", function()
    check("Settings has Run again", gitgud.getText(bragiSettings.widget(2, 2, "Action")) == "Run again")
    clickWidget(bragiSettings.widget(2, 2, "Action"))
end)
step(1500, "started again", function()
    check("Run again starts at Claude Code", welcome.showing() and welcome.step() == "claude")
    clickWidget("WelcomeSkip")
end)
step(800, "Skip one step", function()
    check("Skip moves on", welcome.step() == "look")
    check("Skip is recorded", settings.get("bragi.welcomeSkipped", "") == "claude")
    clickWidget("WelcomeSkipAll")
end)
step(400, "Skip setup", function()
    check("Skip setup goes to the summary", welcome.step() == "done")
    check("without a speech engine: four steps", gitgud.getText("WelcomeStepLabel") == "Step 4 of 4")
    check("summary: no voice in this build", textOf(1, 4, "Sub") == "Not part of this build. Type to Bragi.")
    shot("skipped")
end)
step(300, "after the skipped shot", function()
    clickWidget("WelcomeNext")
end)
step(300, "closed again", function()
    check("closed after skipping", not welcome.showing())
    gitgud.configWrite(PHASE_FILE, "")
    settings.set("test.voiceEngine", nil)
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
