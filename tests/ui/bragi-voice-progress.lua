--- tests/ui/bragi-voice-progress.lua: the voice installs' progress in
-- Settings, with a stand-in installer (no download, hash, or unpack really
-- runs; the test plays the tasks' events). Each step shows its line and a
-- bar driven by its numbers: downloading, checking, unpacking (with the time
-- left once there's a rate), and preparing Bragi's voice model; Stop during
-- unpacking stops the unpacker and leaves nothing half unpacked; a step with
-- no numbers (the models' check) pulses instead of standing still.
--
-- Run it like bragi-voice.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here). Prints "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local localData = os.getenv("LOCALAPPDATA") or ""
if gitgud.currentUi().id ~= "bragi" or not localData:lower():find("sandbox", 1, true) then
    check("needs GITGUD_UI=bragi and a scratch LOCALAPPDATA", false)
    gitgud.emit("window.close", "")
    return
end

local bragiSettings = require("bragi.settings")
local voicemodels = require("bragi.voicemodels")

-- ===================================================================
-- Stand-ins: an engine with no models, no GPU, and tasks that only record
-- ===================================================================

voicemodels.engine = function()
    return { installed = true }
end
voicemodels.gpu = function()
    return { present = false, devices = {} }
end
local calls = {}   -- { kind, task, ... } in order
local cancelled = {}
local function lastCall(kind)
    for i = #calls, 1, -1 do
        if calls[i].kind == kind then
            return calls[i]
        end
    end
    return nil
end
gitgud.downloadFile = function(task, spec)
    -- The file arrives at once (tiny); the test plays its progress.
    gitgud.localDataWrite(spec.file, "stand-in")
    calls[#calls + 1] = { kind = "download", task = task, file = spec.file, size = spec.size }
    return true
end
gitgud.fileSha256 = function(task, path)
    calls[#calls + 1] = { kind = "hash", task = task, path = path }
    return true
end
gitgud.extractArchive = function(task, archive, name)
    calls[#calls + 1] = { kind = "unpack", task = task, archive = archive, name = name }
    -- What an unpacker had written when it was stopped.
    gitgud.localDataWrite(name .. "/partial.onnx", "half")
    return true
end
gitgud.onnxSetAccuracy = function(from, to, level, task)
    calls[#calls + 1] = { kind = "patch", task = task, from = from, to = to }
    return true
end
gitgud.downloadCancel = function(task)
    cancelled[#cancelled + 1] = task
end
gitgud.voiceEngineSetup = function()
    return true
end
gitgud.voiceSelfTest = function(task)
    calls[#calls + 1] = { kind = "selftest", task = task }
    return true
end

local function emit(task, event, value)
    gitgud.emit(task .. "." .. event, type(value) == "table" and gitgud.jsonEncode(value) or (value or ""))
end
local function line()
    return voicemodels.progressText()
end
local function bar()
    local bars = bragiSettings.progressBars()
    return bars[1] or {}
end
local function count(kind)
    local n = 0
    for _, c in ipairs(calls) do
        if c.kind == kind then
            n = n + 1
        end
    end
    return n
end
local function near(a, b)
    return a ~= nil and b ~= nil and math.abs(a - b) < 1e-6
end

-- ===================================================================
-- The listening models
-- ===================================================================

step(1500, "Settings with the models card", function()
    bragiSettings.open("appearance")
end)
step(600, "start the install", function()
    check("nothing installing", voicemodels.state().phase == "idle")
    voicemodels.install("listen")
end)
step(300, "downloading speech detection", function()
    local d = lastCall("download")
    check("its download started", d ~= nil and d.file:find("silero_vad%.onnx") ~= nil)
    check("the card has a bar, empty", #bragiSettings.progressBars() == 1 and near(bar().fraction, 0))
    emit(d.task, "progress", { phase = "download", done = 321927, total = 643854 })
end)
step(300, "half downloaded", function()
    check("its line", line() == "Downloading speech detection: 322 KB of 644 KB (50%), 1 of 4.")
    check("the bar at half", near(bar().fraction, 0.5) and (bar().fillWidth or 0) > 0)
    emit(lastCall("download").task, "progress", { phase = "verify", done = 160964, total = 643854 })
end)
step(300, "checking it", function()
    check("checking, with its share", line() == "Checking speech detection: 25%, 1 of 4.")
    check("the bar follows", near(bar().fraction, 0.25))
    local d = lastCall("download")
    emit(d.task, "done", gitgud.localDataPath(d.file))
end)
step(400, "the wake word spotter: an archive", function()
    local d = lastCall("download")
    check("the next download", d ~= nil and d.file:find("kws%-zipformer") ~= nil)
    check("the bar starts again", near(bar().fraction, 0))
    emit(d.task, "done", gitgud.localDataPath(d.file))
end)
step(400, "unpacking", function()
    local u = lastCall("unpack")
    check("the unpacker started", u ~= nil and u.task == "BragiVoiceUnpack")
    check("unpacking shows at once", voicemodels.state().phase == "unpack")
    emit(u.task, "progress", { phase = "unpack", done = 4406681, total = 17626723 })
end)
step(2500, "a quarter unpacked", function()
    check("its line, no time yet", line() == "Unpacking wake word spotter: 25%, 2 of 4.")
    check("the bar at a quarter", near(bar().fraction, 0.25))
    emit(lastCall("unpack").task, "progress", { phase = "unpack", done = 8813362, total = 17626723 })
end, { clock = true })
step(300, "half unpacked, with a rate", function()
    check("the time left shows", line():find("^Unpacking wake word spotter: 50%%, 2 of 4, about %d+ seconds left%.$")
        ~= nil)
    check("the bar at half", near(bar().fraction, 0.5))
    check("Stop is there while unpacking", bar().name ~= nil
        and gitgud.getText((bar().name:gsub("R1$", "R2")) .. "Action") == "Stop")
    voicemodels.cancel()
end)
step(300, "stopped while unpacking", function()
    local stoppedUnpack = false
    for _, t in ipairs(cancelled) do
        stoppedUnpack = stoppedUnpack or t == "BragiVoiceUnpack"
    end
    check("the unpacker was told to stop", stoppedUnpack)
    check("the card is back to its offer at once", voicemodels.state().phase == "idle"
        and #bragiSettings.progressBars() == 0)
    -- The unpacker's answer once it stopped.
    emit(lastCall("unpack").task, "error", "cancelled")
end)
step(300, "nothing half unpacked", function()
    check("the partial unpack is gone", gitgud.localDataInfo("bragi/voice/staging/kws") == nil)
    check("the download is kept for next time",
        gitgud.localDataInfo("bragi/voice/downloads/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2")
        ~= nil)
    check("still idle", voicemodels.state().phase == "idle")
end)

-- ===================================================================
-- A step with no numbers pulses
-- ===================================================================

local pulseX = nil
step(300, "the models' check", function()
    -- Everything in: the install goes straight to loading every model once.
    voicemodels.missing = function()
        return {}
    end
    voicemodels.installed = function()
        return true
    end
    voicemodels.install("listen")
end)
step(300, "checking the models", function()
    check("the check started", lastCall("selftest") ~= nil and voicemodels.state().phase == "check")
    check("its bar pulses", #bragiSettings.progressBars() == 1 and bar().pulsing == true)
    pulseX = select(1, gitgud.getRect(bar().name .. "BarFill"))
end)
step(500, "it moves", function()
    local x = select(1, gitgud.getRect(bar().name .. "BarFill"))
    check("the pulse moved", pulseX ~= nil and x ~= nil and x ~= pulseX)
    emit(lastCall("selftest").task, "done", { ok = true, loadMs = 5 })
end, { full = true })
step(300, "checked", function()
    check("done", voicemodels.state().phase == "done")
    check("no bar left", #bragiSettings.progressBars() == 0)
end)

-- ===================================================================
-- Bragi's voice model: preparing its graphs
-- ===================================================================

local turbo = voicemodels.packages("turbo")
step(300, "Bragi's voice model", function()
    voicemodels.missing = function(groups)
        return groups == "turbo" and turbo or {}
    end
    voicemodels.installed = function(group)
        return group ~= "turbo"
    end
    voicemodels.install("turbo")
end)
local function finishDownloads(label)
    step(200, label, function()
        local d = lastCall("download")
        if d and voicemodels.state().phase == "download" then
            emit(d.task, "done", gitgud.localDataPath(d.file))
        end
    end)
end
for i = 1, #(turbo[1] and turbo[1].downloads or {}) do
    finishDownloads("its download " .. i)
end
step(400, "preparing its graphs", function()
    local p = lastCall("patch")
    check("the graphs are patched on a worker", p ~= nil and p.task == "BragiVoicePatch")
    check("preparing shows", voicemodels.state().phase == "patch")
    emit(p.task, "progress", { phase = "patch", done = 50, total = 100 })
end)
step(300, "half prepared", function()
    check("its line", line() == "Preparing Bragi's voice model: 50%.")
    check("its bar", near(bar().fraction, 0.5))
    voicemodels.cancel()
    emit(lastCall("patch").task, "done", "12")
end)
step(300, "stopped while preparing", function()
    check("idle, and no next graph started", voicemodels.state().phase == "idle" and count("patch") == 1)
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
