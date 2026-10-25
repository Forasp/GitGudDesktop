--- bragi/voicemodels.lua: the speech engine's listening models, Bragi's
-- built-in voice, and setting the engine up with them.
--
-- The engine (gitgud.voiceEngine, C++) comes with the app, and so does
-- Bragi's built-in voice (voicemodels.SMALL: a small model in the
-- interface's voices/bragi-1, on the processor), which replies use unless
-- a Windows voice is chosen. The listening models don't: they're fetched
-- only from the Bragi interface (the welcome flow's voice step, or
-- Settings), with their size shown first and nothing downloaded until the
-- user says so. They go to the local app data folder
-- (gitgud.localDataPath("bragi/voice"): %LOCALAPPDATA%\Gitgud\bragi\voice on
-- Windows), each file checked against the size and SHA-256 pinned below:
-- speech detection, the wake word spotter, speech recognition, speaker
-- recognition. Without the engine, replies use the voices Windows has.
--
--   bragi/voice/models/<package>/   the listening models, unpacked
--   bragi/voice/downloads/          downloads in progress (resumed next time)
--   bragi/voice/staging/            archives being unpacked
--   bragi/voice/installed.json      { packages = { <id> = { at } } }
--   bragi/voice/voiceprints/        the user's voiceprint (enrollment)
--   bragi/voice/work/               the engine's own files (checks, config)
--
-- Older versions also put a GPU voice model (turbo/), NVIDIA's libraries
-- (gpu/) and voices made from recordings (voices/) there; nothing uses
-- them now, and Settings offers to remove them (voicemodels.leftovers()).
--
-- Install from a folder: the same files (the archives as downloaded, or
-- the models unpacked), for a computer that can't download them.
--
-- The engine checks every model file's SHA-256 again before it loads it
-- (remembered by size and time). The install ends with a self test: every
-- model loaded and run once (gitgud.voiceSelfTest).
--
-- Public API: voicemodels.PACKAGES, voicemodels.ENGINE,
-- voicemodels.engineInstalled(), voicemodels.engine(),
-- voicemodels.installed(group), voicemodels.missing(group), voicemodels.packages(group),
-- voicemodels.configure(), voicemodels.state(),
-- voicemodels.install(groups), voicemodels.installFrom(folder, groups),
-- voicemodels.cancel(), voicemodels.check(), voicemodels.remove(group),
-- voicemodels.leftovers(), voicemodels.removeLeftovers(),
-- voicemodels.SMALL, voicemodels.smallReady(), voicemodels.smallVoiceId(),
-- voicemodels.smallVoicesDir(), voicemodels.phonemesDir(),
-- voicemodels.downloadBytes(list), voicemodels.diskBytes(list),
-- voicemodels.size(bytes), voicemodels.progressText(),
-- voicemodels.credits(), voicemodels.cards(opts), voicemodels.faultText(engine),
-- voicemodels.crashText(crash)
--
-- Publishes "bragi.voiceModels" (the state) when an install moves on.

local app = require("core.app")

local voicemodels = { name = "bragi.voicemodels" }

local ROOT = "bragi/voice"
local MODELS = ROOT .. "/models"
local DOWNLOADS = ROOT .. "/downloads"
local STAGING = ROOT .. "/staging"
local STATE_FILE = ROOT .. "/installed.json"

local RELEASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/"

-- What older versions installed that nothing uses now.
local LEFTOVERS = { ROOT .. "/turbo", ROOT .. "/gpu", ROOT .. "/voices" }

-- The packages, pinned (sherpa-onnx's stack). Kinds:
--   file      downloaded as is into the package's folder
--   archive   unpacked; `dir`, that folder, becomes the package's
-- `files`: what the engine loads, with sizes and SHA-256 (it checks them
-- before every first load).
voicemodels.PACKAGES = {
    { id = "vad", group = "listen", title = "Speech detection", about = "Tells speech from silence.",
      model = "Silero VAD",
      credit = "the Silero team", licence = "MIT",
      url = RELEASE .. "asr-models/silero_vad.onnx", file = "silero_vad.onnx",
      size = 643854, sha256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
      files = {
          { path = "silero_vad.onnx", size = 643854,
            sha256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6" },
      } },
    { id = "kws", group = "listen", title = "Wake word spotter", about = "Listens for Bragi's name.",
      model = "Zipformer keyword spotter (GigaSpeech, 3.3M)",
      credit = "the Next-gen Kaldi project", licence = "Apache-2.0",
      url = RELEASE .. "kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2",
      archive = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2",
      dir = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01",
      size = 17626723, sha256 = "f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a",
      unpacked = 20100000,
      files = {
          { path = "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx", size = 4807159,
            sha256 = "1e721676515bcd42a186979733981213c66c80db680e1cc582dfedf3be76e678" },
          { path = "decoder-epoch-12-avg-2-chunk-16-left-64.onnx", size = 1063189,
            sha256 = "f61ebd3eed3773a44d088d53dfae92dbb6aec4839f4dcaee2d402414741663a3" },
          { path = "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx", size = 163380,
            sha256 = "eae9da0c7e1e6c6a3f4cc42d167899c388f6c6701b94cb96320e4f55df79624c" },
          { path = "tokens.txt", size = 5006,
            sha256 = "fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53" },
          { path = "bpe.model", size = 244837,
            sha256 = "c8a2a0129c4ab8e463164c142f82d25649661b122c8cd0b7aab5c9e80b90ad24" },
      } },
    { id = "asr", group = "listen", title = "Speech recognition", about = "Turns what you say into text.",
      model = "Parakeet TDT 0.6B v2 (int8)",
      credit = "NVIDIA", licence = "CC-BY-4.0",
      url = RELEASE .. "asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
      archive = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
      dir = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
      size = 482468385, sha256 = "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad",
      unpacked = 661400000,
      files = {
          { path = "encoder.int8.onnx", size = 652184296,
            sha256 = "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab" },
          { path = "decoder.int8.onnx", size = 7257753,
            sha256 = "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e" },
          { path = "joiner.int8.onnx", size = 1739080,
            sha256 = "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2" },
          { path = "tokens.txt", size = 9384,
            sha256 = "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d" },
      } },
    { id = "speaker", group = "listen", title = "Speaker recognition", about = "Tells your voice from others'.",
      model = "TitaNet-Large",
      credit = "NVIDIA", licence = "CC-BY-4.0",
      url = RELEASE .. "speaker-recongition-models/nemo_en_titanet_large.onnx", file = "nemo_en_titanet_large.onnx",
      size = 101405493, sha256 = "d51abcf31717ef28162f26acb9d44dd4127c3d44c9b8624f699f3425daca8e77",
      files = {
          { path = "nemo_en_titanet_large.onnx", size = 101405493,
            sha256 = "d51abcf31717ef28162f26acb9d44dd4127c3d44c9b8624f699f3425daca8e77" },
      } },


}

local LICENCE_LINKS = {
    ["MIT"] = "https://opensource.org/licenses/MIT",
    ["Apache-2.0"] = "https://www.apache.org/licenses/LICENSE-2.0",
    ["CC-BY-4.0"] = "https://creativecommons.org/licenses/by/4.0/",
}

-- How the engine runs on this computer's processor (sherpa-onnx's CPU
-- stack, measured 2026-10): Parakeet on 4 threads with beam search biased
-- toward the wake word and the vocabulary; the spotter and detection on 1;
-- partial transcripts at most once a second; ONNX Runtime's threads don't
-- spin between calls. And what the wake word "Bragi" gets heard as.
voicemodels.ENGINE = {
    asrName = "parakeet-tdt-0.6b-v2-int8",
    asrThreads = 4,
    kwsThreads = 1,
    speakerThreads = 2,
    hotwords = true,
    hotwordsScore = 1.5,
    partialSeconds = 1.0,
    spinning = false,
    endBy = "app",
    wakeWord = "Bragi",
    spotterSpellings = { "Braggy", "Broggy" },
    mishearings = { "Braggy", "Braggie", "Broggy", "Braghi", "Brogi", "Bragy", "Bruggie", "Brogy", "Baragi",
        "Raghi", "Raggy", "Roggy", "Rogi", "Rogy", "Ruggy" },
}

-- Bragi's built-in voice: a small model that comes with the interface
-- (voices/bragi-1: model.onnx and phonemes.tsv), on the processor, no
-- download or GPU. Its text is phonemes (bragi.phonemes, over the
-- dictionaries in phonemes/). How it was made to sound: played at `rate`
-- (below the model's 24 kHz, which deepens it), at `speed` with the pitch
-- kept, with `wobble` (random pitch waver, inside the model) and `rough`
-- (loudness flutter from roughLow to roughHigh Hz).
voicemodels.SMALL = {
    name = "bragi-1",
    label = "Bragi (built in)",
    rate = 21600,
    speed = 1.27,
    wobble = 0.045,
    rough = 0.1,
    roughLow = 30,
    roughHigh = 80,
    threads = 2,
}

-- What the engine was doing when a call failed (gitgud.voiceEngine's
-- lastCrash.call and fault messages), in words.
local CALLS = {
    ["load the recognizer"] = "loading the speech recognition model",
    ["load the keyword spotter"] = "loading the wake word spotter",
    ["load the speaker model"] = "loading the speaker recognition model",
    ["load the voice activity model"] = "loading the speech detection model",
    ["transcribe"] = "transcribing",
    ["spot the wake word"] = "listening for the wake word",
    ["start spotting"] = "listening for the wake word",
    ["detect speech"] = "listening",
    ["identify the speaker"] = "telling your voice from others",
    ["load the small voice"] = "loading the voice for replies",
    ["release the small voice"] = "releasing the voice for replies",
    ["say with the small voice"] = "speaking a reply",
}

local state = { phase = "idle" }
-- Where the rate for "time left" is measured from: { key, t, done }.
local rateFrom = nil
local wired = {}
local pending = {}
local cancelled = false

local function publish()
    app.publish("bragi.voiceModels", state)
end

--- Task events, wired once per name (they can't be unwired).
local function await(name, onDone, onProgress)
    pending[name] = { done = onDone, progress = onProgress }
    if wired[name] then
        return
    end
    wired[name] = true
    gitgud.on(name .. ".done", function(detail)
        local p = pending[name]
        pending[name] = nil
        if p then
            p.done(true, detail)
        end
    end)
    gitgud.on(name .. ".error", function(detail)
        local p = pending[name]
        pending[name] = nil
        if p then
            p.done(false, detail or "unknown error")
        end
    end)
    gitgud.on(name .. ".progress", function(detail)
        local p = pending[name]
        if p and p.progress then
            p.progress(gitgud.jsonDecode(detail or "") or {})
        end
    end)
end

-- ---------------------------------------------------------------------
-- What's there

--- gitgud.voiceEngine(): { installed, configured, loaded, faulted, faultCode,
-- fault, runtimeDir, test, lastCrash }. Tests swap it.
function voicemodels.engine()
    return gitgud.voiceEngine and gitgud.voiceEngine() or { installed = false }
end

--- The engine's libraries are in this build.
function voicemodels.engineInstalled()
    return voicemodels.engine().installed == true
end

local function readState()
    local decoded = gitgud.jsonDecode(gitgud.localDataRead(STATE_FILE) or "")
    if type(decoded) ~= "table" or type(decoded.packages) ~= "table" then
        return { packages = {} }
    end
    return decoded
end

-- voicemodels.missing()'s answers, for a few seconds (voice.available()
-- asks often), and until the install state changes.
local cache = {}
local CACHE_MS = 5000

local function writeState(s)
    cache = {}
    return gitgud.localDataWrite(STATE_FILE, gitgud.jsonEncode(s))
end

local function packageDir(p)
    return p.dest and (ROOT .. "/" .. p.dest) or (MODELS .. "/" .. p.id)
end

--- A package whose install finished and whose files are all there, at
-- their sizes (the engine checks their SHA-256 before loading).
local function packageReady(p, s)
    if not (s.packages[p.id]) then
        return false
    end
    for _, f in ipairs(p.files) do
        local info = gitgud.localDataInfo(packageDir(p) .. "/" .. f.path)
        if not info or info.dir or info.size ~= f.size then
            return false
        end
    end
    return true
end

-- A group name or a list of them, as a set.
local function groupSet(groups)
    local set = {}
    if type(groups) == "table" then
        for _, g in ipairs(groups) do
            set[g] = true
        end
    else
        set[groups or "listen"] = true
    end
    return set
end

--- The packages of `groups` (a group or a list; default "listen").
function voicemodels.packages(groups)
    local set = groupSet(groups)
    local list = {}
    for _, p in ipairs(voicemodels.PACKAGES) do
        if set[p.group] then
            list[#list + 1] = p
        end
    end
    return list
end

--- The packages of `groups` not (completely) installed.
function voicemodels.missing(groups)
    if voicemodels.engine().test then
        return {}
    end
    local key = type(groups) == "table" and table.concat(groups, ",") or (groups or "listen")
    local now = gitgud.now()
    local hit = cache[key]
    if hit and now - hit.at < CACHE_MS then
        return hit.list
    end
    local s = readState()
    local list = {}
    for _, p in ipairs(voicemodels.packages(groups)) do
        if not packageReady(p, s) then
            list[#list + 1] = p
        end
    end
    cache[key] = { at = now, list = list }
    return list
end

--- Every package of `groups` is installed (the stand-in engine for tests
-- needs none). Default: the listening models.
function voicemodels.installed(groups)
    return #voicemodels.missing(groups) == 0
end

function voicemodels.downloadBytes(list)
    local n = 0
    for _, p in ipairs(list or voicemodels.packages()) do
        n = n + p.size
    end
    return n
end

function voicemodels.diskBytes(list)
    local n = 0
    for _, p in ipairs(list or voicemodels.packages()) do
        n = n + (p.unpacked or p.size)
    end
    return n
end

--- "2.4 GB", "602 MB", "17.6 MB", "644 KB".
function voicemodels.size(bytes)
    if bytes >= 1e9 then
        return string.format("%.1f GB", bytes / 1e9)
    elseif bytes >= 100e6 then
        return string.format("%d MB", math.floor(bytes / 1e6 + 0.5))
    elseif bytes >= 1e6 then
        return string.format("%.1f MB", bytes / 1e6)
    end
    return string.format("%d KB", math.floor(bytes / 1e3 + 0.5))
end

local function engineFiles(list)
    local files = {}
    for _, p in ipairs(list) do
        for _, f in ipairs(p.files) do
            files[#files + 1] = { path = gitgud.localDataPath(packageDir(p) .. "/" .. f.path), size = f.size,
                sha256 = f.sha256 }
        end
    end
    return files
end

--- Tell the engine where the models are (when they're installed), and
-- where the built-in voice is. True when it took them.
function voicemodels.configure()
    if not voicemodels.engineInstalled() or not voicemodels.installed() then
        return false
    end
    local byId = {}
    for _, p in ipairs(voicemodels.PACKAGES) do
        byId[p.id] = p
    end
    local function path(p, file)
        return gitgud.localDataPath(packageDir(p) .. "/" .. file)
    end
    local settings = {}
    for k, v in pairs(voicemodels.ENGINE) do
        settings[k] = v
    end
    settings.vadModel = path(byId.vad, "silero_vad.onnx")
    settings.asrDir = gitgud.localDataPath(packageDir(byId.asr))
    settings.kwsDir = gitgud.localDataPath(packageDir(byId.kws))
    settings.speakerModel = path(byId.speaker, "nemo_en_titanet_large.onnx")
    settings.voiceprintsDir = gitgud.localDataPath(ROOT .. "/voiceprints")
    settings.workDir = gitgud.localDataPath(ROOT .. "/work")
    settings.files = engineFiles(voicemodels.packages("listen"))
    local smallDir = voicemodels.smallVoicesDir()
    if smallDir then
        settings.small = { voicesDir = smallDir, threads = voicemodels.SMALL.threads }
    end
    local ok = gitgud.voiceEngineSetup(settings)
    return ok == true
end

-- ---------------------------------------------------------------------
-- Installing

--- { phase = idle|download|verify|unpack|copy|check|done|failed,
-- group, package, done, total, left, index, count, error, note }: done and
-- total are bytes (downloaded, hashed, read by the unpacker, copied); left is the milliseconds to go, once there's a rate.
function voicemodels.state()
    return state
end

local function set(fields)
    state = fields
    publish()
end

local function fail(message)
    set({ phase = "failed", group = state.group, error = tostring(message or "unknown error") })
end

-- "Speech detection" -> "speech detection"; "ASR model" stays.
local function lowerFirst(t)
    if t:sub(2, 2):match("%u") then
        return t
    end
    return t:sub(1, 1):lower() .. t:sub(2)
end

-- The phases with numbers, and their verbs.
local MEASURED = { download = "Downloading", verify = "Checking", unpack = "Unpacking", copy = "Copying" }

--- "about 40 seconds", "about 3 minutes".
local function roughly(ms)
    local s = ms / 1000
    if s < 60 then
        return "about " .. math.max(5, math.floor(s / 5 + 0.5) * 5) .. " seconds"
    end
    local m = math.floor(s / 60 + 0.5)
    return m == 1 and "about a minute" or ("about " .. m .. " minutes")
end

--- The share done, 0 to 1, for the card's bar; nil while the step has no
-- numbers (the bar pulses then).
function voicemodels.progressFraction()
    local s = state
    if not MEASURED[s.phase] then
        return nil
    end
    -- A download knows its size before its first numbers come.
    local total = (s.total or 0) > 0 and s.total or (s.phase == "download" and s.package and s.package.size or 0)
    if total > 0 then
        return math.max(0, math.min(1, (s.done or 0) / total))
    end
    return nil
end

--- What the install is doing, in a line: the step, how far, and roughly
-- how long is left once there's a rate.
function voicemodels.progressText()
    local s = state
    local pkg = s.package or {}
    local p = pkg.phrase or lowerFirst(pkg.title or "")
    if MEASURED[s.phase] then
        local total = (s.total or 0) > 0 and s.total or 0
        local pct = total > 0 and math.floor((s.done or 0) * 100 / total) or 0
        local line = MEASURED[s.phase] .. " " .. p .. ": "
        if s.phase == "download" then
            local size = total > 0 and total or (pkg.size or 0)
            line = line .. string.format("%s of %s (%d%%)", voicemodels.size(s.done or 0), voicemodels.size(size),
                size > 0 and math.floor((s.done or 0) * 100 / size) or 0)
        else
            line = line .. pct .. "%"
        end
        if (s.count or 1) > 1 then
            line = line .. string.format(", %d of %d", s.index or 1, s.count)
        end
        if s.left then
            line = line .. ", " .. roughly(s.left) .. " left"
        end
        return line .. "."
    elseif s.phase == "check" then
        return "Loading every model once to check them."
    elseif s.phase == "done" then
        return s.note or "Installed and checked."
    elseif s.phase == "failed" then
        return "Didn't finish: " .. tostring(s.error) .. "."
    end
    return ""
end

local function markInstalled(p)
    local s = readState()
    s.packages[p.id] = { at = os.date("%Y-%m-%d %H:%M") }
    writeState(s)
end

--- After the listening models: tell the engine and have it load everything once.
local function selfTest()
    if not voicemodels.configure() then
        fail("the engine didn't take the models")
        return
    end
    set({ phase = "check", group = "listen" })
    local ok, err = gitgud.voiceSelfTest("BragiVoiceSelfTest")
    if not ok then
        fail(err)
        return
    end
    await("BragiVoiceSelfTest", function(_, detail)
        if state.phase ~= "check" then
            return -- stopped meanwhile
        end
        local result = gitgud.jsonDecode(detail or "") or {}
        if result.ok then
            set({ phase = "done", group = "listen", loadMs = result.loadMs })
            app.publish("bragi.voiceAvailable")
        else
            fail(result.message or result.code or "the self test failed")
        end
    end)
end

-- Put an unpacked package in place: staging/<id>/<dir> -> models/<id>.
local function placeUnpacked(p, from)
    gitgud.localDataRemove(packageDir(p))
    local ok, err = gitgud.localDataMove(from, packageDir(p))
    gitgud.localDataRemove(STAGING .. "/" .. p.id)
    if not ok then
        return nil, err
    end
    markInstalled(p)
    return true
end

-- A task's progress events ({phase, done, total}) into the state, with
-- the time left once two seconds of it give a rate.
local function progressFor(p, index, count)
    return function(progress)
        local phase = MEASURED[progress.phase or ""] and progress.phase or "download"
        local done = tonumber(progress.done) or 0
        local total = tonumber(progress.total) or 0
        local now = gitgud.now()
        local key = phase .. "|" .. tostring(p.id or p.title) .. "|" .. tostring(p.part or "")
        if not rateFrom or rateFrom.key ~= key or done < rateFrom.done then
            rateFrom = { key = key, t = now, done = done }
        end
        local left = nil
        local elapsed = now - rateFrom.t
        if elapsed >= 2000 and done > rateFrom.done and total > done then
            left = (total - done) / ((done - rateFrom.done) / elapsed)
        end
        if cancelled then
            return
        end
        state = { phase = phase, group = state.group, package = p, done = done, total = total, left = left,
            index = index, count = count }
        publish()
    end
end

-- A step starting: its phase with nothing done yet.
local function begin(phase, p)
    set({ phase = phase, group = state.group, package = p, done = 0, total = 0, index = state.index,
        count = state.count })
end

-- Unpack an archive (a local path) into place, then `onDone(ok, err)`.
local function unpack(p, archive, onDone)
    begin("unpack", p)
    local ok, err = gitgud.extractArchive("BragiVoiceUnpack", archive, STAGING .. "/" .. p.id)
    if not ok then
        onDone(false, err)
        return
    end
    await("BragiVoiceUnpack", function(done, detail)
        if not done then
            gitgud.localDataRemove(STAGING .. "/" .. p.id)
            onDone(false, detail)
            return
        end
        onDone(placeUnpacked(p, STAGING .. "/" .. p.id .. "/" .. p.dir))
    end, progressFor(p, state.index, state.count))
end

-- Download one package and put it in place.
local function fetchOne(p, onDone)
    local target = DOWNLOADS .. "/" .. (p.archive or p.file)
    local ok, err = gitgud.downloadFile("BragiVoiceDownload", {
        url = p.url, file = target, sha256 = p.sha256, size = p.size })
    if not ok then
        onDone(false, err)
        return
    end
    await("BragiVoiceDownload", function(done, detail)
        if not done then
            onDone(false, detail)
            return
        end
        if p.archive then
            unpack(p, detail, function(placed, why)
                if placed then
                    gitgud.localDataRemove(target)
                end
                onDone(placed, why)
            end)
        else
            gitgud.localDataRemove(packageDir(p))
            local moved, why = gitgud.localDataMove(target, packageDir(p) .. "/" .. p.file)
            if moved then
                markInstalled(p)
            end
            onDone(moved, why)
        end
    end, progressFor(p, state.index, state.count))
end

-- Run `step(p, onDone)` for each package in `list`, then `finish()`.
local function each(list, group, step, finish)
    cancelled = false
    local i = 0
    local function nextOne()
        if cancelled then
            set({ phase = "idle" })
            return
        end
        i = i + 1
        local p = list[i]
        if not p then
            finish()
            return
        end
        set({ phase = "download", group = group, package = p, done = 0, total = 0, index = i, count = #list })
        step(p, function(ok, err)
            if not ok then
                if cancelled or err == "cancelled" then
                    set({ phase = "idle" })
                else
                    fail(err)
                end
                return
            end
            nextOne()
        end)
    end
    nextOne()
end

local function busy()
    return state.phase ~= "idle" and state.phase ~= "done" and state.phase ~= "failed"
end

--- Download what's missing of `groups` (default "listen", the only group),
-- the user having said yes, then check it.
function voicemodels.install(groups)
    if busy() then
        return
    end
    local list = voicemodels.missing(groups)
    if #list == 0 then
        selfTest()
        return
    end
    each(list, "listen", fetchOne, selfTest)
end

local function joinPath(folder, ...)
    local sep = folder:find("\\", 1, true) and "\\" or "/"
    return table.concat({ folder, ... }, sep)
end

--- Find a package's files in `folder`: its download (archive or file), or
-- its unpacked folder.
local function findIn(folder, p)
    local name = p.archive or p.file
    if gitgud.pathExists(joinPath(folder, name)) then
        return { archive = joinPath(folder, name) }
    end
    if p.dir and gitgud.pathExists(joinPath(folder, p.dir, p.files[1].path)) then
        return { dir = joinPath(folder, p.dir) }
    end
    if not p.dir and p.file and gitgud.pathExists(joinPath(folder, p.id, p.file)) then
        return { archive = joinPath(folder, p.id, p.file) }
    end
    return nil
end

-- Copy each of a package's files from an unpacked folder.
local function copyFiles(p, dir, onDone)
    local i = 0
    local stage = STAGING .. "/" .. p.id .. "/" .. p.dir
    gitgud.localDataRemove(STAGING .. "/" .. p.id)
    local function nextFile()
        i = i + 1
        local f = p.files[i]
        if not f then
            onDone(placeUnpacked(p, stage))
            return
        end
        begin("copy", p)
        local ok, err = gitgud.copyToLocalData("BragiVoiceCopy", joinPath(dir, f.path), stage .. "/" .. f.path)
        if not ok then
            onDone(false, err)
            return
        end
        await("BragiVoiceCopy", function(done, detail)
            if not done then
                onDone(false, detail)
            else
                nextFile()
            end
        end, progressFor({ id = p.id, title = p.title, phrase = p.phrase, part = i }, state.index, state.count))
    end
    nextFile()
end

-- Check a file's SHA-256 and copy it in, then `onDone(ok, err)`.
local function checkAndCopy(p, source, sha256, target, onDone)
    local index, count = state.index, state.count
    begin("verify", p)
    local ok, err = gitgud.fileSha256("BragiVoiceHash", source)
    if not ok then
        onDone(false, err)
        return
    end
    await("BragiVoiceHash", function(done, sha)
        if not done then
            onDone(false, sha)
            return
        end
        if tostring(sha):lower() ~= sha256 then
            onDone(false, source .. " isn't the expected file")
            return
        end
        begin("copy", p)
        local copied, why = gitgud.copyToLocalData("BragiVoiceCopy", source, target)
        if not copied then
            onDone(false, why)
            return
        end
        await("BragiVoiceCopy", function(c, detail)
            onDone(c, not c and detail or nil)
        end, progressFor(p, index, count))
    end, progressFor(p, index, count))
end

--- Install from files already on this computer (the same downloads, or
-- the models unpacked). Packages not found there stay missing.
function voicemodels.installFrom(folder, groups)
    if busy() or type(folder) ~= "string" or folder == "" then
        return
    end
    local found, list = {}, {}
    for _, p in ipairs(voicemodels.missing(groups)) do
        local where = findIn(folder, p)
        if where then
            found[p.id] = where
            list[#list + 1] = p
        end
    end
    local group = "listen"
    state.group = group
    if #list == 0 then
        fail("none of the files are in " .. folder)
        return
    end
    each(list, group, function(p, onDone)
        local where = found[p.id]
        if where.dir then
            copyFiles(p, where.dir, onDone)
            return
        end
        if p.archive then
            -- Checked, then unpacked straight from the folder.
            begin("verify", p)
            local ok, err = gitgud.fileSha256("BragiVoiceHash", where.archive)
            if not ok then
                onDone(false, err)
                return
            end
            await("BragiVoiceHash", function(done, sha)
                if not done then
                    onDone(false, sha)
                elseif tostring(sha):lower() ~= p.sha256 then
                    onDone(false, (p.archive or p.file) .. " in that folder isn't the expected file")
                else
                    unpack(p, where.archive, onDone)
                end
            end, progressFor(p, state.index, state.count))
            return
        end
        gitgud.localDataRemove(packageDir(p))
        checkAndCopy(p, where.archive, p.sha256, packageDir(p) .. "/" .. p.file, function(ok, err)
            if ok then
                markInstalled(p)
            end
            onDone(ok, err)
        end)
    end, selfTest)
end

-- The install's tasks that Stop can end.
local TASKS = { "BragiVoiceDownload", "BragiVoiceHash", "BragiVoiceCopy", "BragiVoiceUnpack" }

--- Stop the install: the running step ends (a download is kept for next
-- time; a half-done copy or unpack is removed) and nothing more starts.
-- The card goes back to its offer at once.
function voicemodels.cancel()
    cancelled = true
    for _, task in ipairs(TASKS) do
        gitgud.downloadCancel(task)
    end
    set({ phase = "idle" })
end

--- Check the installed models again: the engine loads and runs them.
function voicemodels.check()
    if busy() then
        return
    end
    selfTest()
end

--- Remove the listening models (the engine's files and downloads in
-- progress too). `group`: "listen", the only one.
function voicemodels.remove(group)
    if busy() or (group or "listen") ~= "listen" then
        return
    end
    require("bragi.voice").stop()
    gitgud.voiceEngineRelease()
    local s = readState()
    gitgud.localDataRemove(MODELS)
    gitgud.localDataRemove(STAGING)
    gitgud.localDataRemove(DOWNLOADS)
    gitgud.localDataRemove(ROOT .. "/work")
    for _, p in ipairs(voicemodels.packages("listen")) do
        s.packages[p.id] = nil
    end
    writeState(s)
    voicemodels.configure()
    set({ phase = "idle" })
    app.publish("bragi.voiceAvailable")
end

--- The folders older versions installed that are still there (the GPU voice
-- model, NVIDIA's libraries, voices made from recordings): nothing uses them.
function voicemodels.leftovers()
    local list = {}
    for _, dir in ipairs(LEFTOVERS) do
        if gitgud.localDataInfo(dir) then
            list[#list + 1] = dir
        end
    end
    return list
end

--- Remove what older versions installed (voicemodels.leftovers()), and
-- their entries in installed.json.
function voicemodels.removeLeftovers()
    for _, dir in ipairs(voicemodels.leftovers()) do
        gitgud.localDataRemove(dir)
    end
    local s = readState()
    local known = {}
    for _, p in ipairs(voicemodels.PACKAGES) do
        known[p.id] = true
    end
    for id in pairs(s.packages) do
        if not known[id] then
            s.packages[id] = nil
        end
    end
    writeState(s)
    publish()
end

-- ---------------------------------------------------------------------
-- The built-in voice

-- The interface's own copy of a file (the interface folder, or the app's).
local function interfaceFile(relative)
    for _, root in ipairs(require("bragi.customize").roots()) do
        if root and gitgud.pathExists(root .. "/" .. relative) then
            return root .. "/" .. relative
        end
    end
    return nil
end

--- The folder the built-in voice is in (its voices folder), or nil when the
-- interface hasn't got it.
function voicemodels.smallVoicesDir()
    local model = interfaceFile("voices/" .. voicemodels.SMALL.name .. "/model.onnx")
    return model and (model:gsub("[/\\][^/\\]+[/\\][^/\\]+$", "")) or nil
end

--- The folder with the pronunciation dictionaries the built-in voice reads, or nil.
function voicemodels.phonemesDir()
    local gold = interfaceFile("phonemes/en-us-gold.tsv")
    return gold and (gold:gsub("[/\\][^/\\]+$", "")) or nil
end

--- The built-in voice's id ("small:bragi-1").
function voicemodels.smallVoiceId()
    return "small:" .. voicemodels.SMALL.name
end

--- Replies can be spoken with the built-in voice: it came with the
-- interface, and the engine runs (no download, no GPU).
function voicemodels.smallReady()
    if voicemodels.engine().test then
        return true
    end
    return voicemodels.engineInstalled() and not voicemodels.engine().faulted
        and voicemodels.smallVoicesDir() ~= nil and voicemodels.phonemesDir() ~= nil
end

-- ---------------------------------------------------------------------
-- Cards (bragiSettings.cards rows), for the welcome flow and Settings

local function pickFolder(groups)
    return function()
        local folder = gitgud.pickFolder("The folder with the downloaded files")
        if folder and folder ~= "" then
            voicemodels.installFrom(folder, groups)
        end
    end
end

-- An install's rows: the step with its bar (bragi/settings.lua's
-- "progress" row: a bar from progressFraction, pulsing while a step has no
-- numbers), and Stop while a step can stop.
local function progressRows(rows, s)
    rows[#rows + 1] = { kind = "progress", title = "Installing", sub = voicemodels.progressText,
        fraction = voicemodels.progressFraction }
    if MEASURED[s.phase] then
        rows[#rows + 1] = { kind = "action", title = "Stop", sub = "What's downloaded is kept for next time.",
            button = "Stop", run = voicemodels.cancel }
    end
end

local function listenCard(opts)
    local s = state
    local rows = {}
    local working = busy() and s.group == "listen"
    local missing = voicemodels.missing()
    local card = { heading = "Voice models", rows = rows }
    if working then
        progressRows(rows, s)
        rows[1].title = "Installing the voice models"
        card.progress = true
    elseif #missing > 0 then
        local where = gitgud.localDataPath(ROOT)
        local partly = #missing < #voicemodels.packages("listen")
        rows[#rows + 1] = { kind = "info", title = partly and "Some voice models are missing" or "Voice models",
            sub = "Bragi hears you with speech models that run on this computer: nothing you say leaves it. "
                .. "They're about " .. voicemodels.size(voicemodels.downloadBytes(missing)) .. " to download and "
                .. voicemodels.size(voicemodels.diskBytes(missing)) .. " on disk, in " .. where
                .. ". Nothing is downloaded until you choose to." }
        for _, p in ipairs(missing) do
            rows[#rows + 1] = { kind = "info", title = p.title .. ", " .. voicemodels.size(p.size), sub = p.about }
        end
        if s.phase == "failed" and s.group == "listen" then
            rows[#rows + 1] = { kind = "info", title = "The last try didn't finish", sub = tostring(s.error) .. "." }
        end
        rows[#rows + 1] = { kind = "action", title = "Download them",
            sub = voicemodels.size(voicemodels.downloadBytes(missing)) .. ", from the models' publishers.",
            button = s.phase == "failed" and s.group == "listen" and "Try again" or "Download", primary = true,
            run = function()
                voicemodels.install("listen")
            end }
        rows[#rows + 1] = { kind = "action", title = "Install from a folder",
            sub = "The same files, downloaded already.", button = "Choose folder", run = pickFolder("listen") }
    else
        local sub = (s.phase == "done" and s.group == "listen") and "Installed and checked: every model loaded and ran."
            or "Installed in " .. gitgud.localDataPath(MODELS) .. "."
        if s.phase == "failed" and s.group == "listen" then
            sub = "The check didn't pass: " .. tostring(s.error) .. "."
        end
        rows[#rows + 1] = { kind = "info", title = "Voice models", sub = sub }
        if opts.settings then
            rows[#rows + 1] = { kind = "action", title = "Check them",
                sub = "Load and run every model once.", button = "Check", run = voicemodels.check }
            rows[#rows + 1] = { kind = "action", title = "Repair",
                sub = "Remove them and download them again.", button = "Repair", run = function()
                    voicemodels.remove("listen")
                    voicemodels.install("listen")
                end }
            rows[#rows + 1] = { kind = "action", title = "Remove them",
                sub = "Frees " .. voicemodels.size(voicemodels.diskBytes()) .. ". Voice is off without them.",
                button = "Remove", run = function()
                    voicemodels.remove("listen")
                end }
        end
    end
    if opts.settings and #voicemodels.leftovers() > 0 then
        rows[#rows + 1] = { kind = "action", title = "Old voice files",
            sub = "Left by an older version (the GPU voice model, NVIDIA's libraries, voices made from recordings) "
                .. "in " .. gitgud.localDataPath(ROOT) .. ". Nothing uses them now.",
            button = "Remove", run = voicemodels.removeLeftovers }
    end
    local settings = require("core.settings")
    local off = settings.get("bragi.voiceOff", "")
    if opts.settings and off ~= "" then
        rows[#rows + 1] = { kind = "action", title = "Voice is off", sub = off, button = "Turn on",
            run = function()
                require("bragi.voice").clearCrash()
                publish()
            end }
    end
    return card
end

-- The system's first voice, for "use a Windows voice".
local function windowsVoice()
    local list = gitgud.voiceVoices and gitgud.voiceVoices() or nil
    return type(list) == "table" and list[1] and list[1].id or nil
end

-- Settings: the voice replies use: the built-in one by default, or a
-- Windows voice.
local function voicesCard()
    if not voicemodels.smallReady() then
        return nil
    end
    local settings = require("core.settings")
    local chosen = settings.get("bragi.voice", "")
    local onWindows = chosen ~= "" and not chosen:find("^small:")
    local rows = {}
    local card = { heading = "Voice for replies", rows = rows }
    local function choose(id)
        return function()
            settings.set("bragi.voice", id)
            app.publish("bragi.voicesChanged")
        end
    end
    rows[#rows + 1] = { kind = onWindows and "action" or "info", title = voicemodels.SMALL.label,
        sub = "Bragi's built-in voice, on the processor: it answers at once." .. (onWindows and "" or " Replies use it."),
        button = onWindows and "Use it" or nil, run = onWindows and choose("") or nil }
    if onWindows then
        rows[#rows + 1] = { kind = "info", title = "Replies use a Windows voice", sub = "Not Bragi's own." }
    else
        rows[#rows + 1] = { kind = "action", title = "Use a Windows voice",
            sub = "The voices Windows has.", button = "Use Windows voice", run = function()
                local id = windowsVoice()
                if id then
                    choose(id)()
                end
            end }
    end
    return card
end

--- The engine's cards: Voice models, then in Settings the voice for
-- replies (the built-in one, or a Windows voice) and the credits. A card
-- installing something has `progress = true`: its first row's sub is
-- voicemodels.progressText.
-- @param opts  { settings = true: Check, Repair, Remove, old files, credits, and the off switch after a crash }
function voicemodels.cards(opts)
    opts = opts or {}
    local cards = { listenCard(opts) }
    local voices = opts.settings and voicesCard() or nil
    if voices then
        cards[#cards + 1] = voices
    end
    if opts.settings then
        local credits = {}
        for _, c in ipairs(voicemodels.credits()) do
            credits[#credits + 1] = { kind = "info", title = c.title, sub = c.line }
        end
        credits[#credits + 1] = { kind = "info", title = "Speech engine",
            sub = "sherpa-onnx (Apache-2.0) and ONNX Runtime (MIT), in the voice folder beside GitGud, on the "
                .. "processor. Without them, replies use the voices Windows has." }
        cards[#cards + 1] = { heading = "Voice credits", rows = credits }
    end
    return cards
end

-- ---------------------------------------------------------------------
-- Words

--- The credits: the listening models and the built-in voice.
-- { { title, line, link }, ... }.
function voicemodels.credits()
    local out = {}
    for _, p in ipairs(voicemodels.PACKAGES) do
        if p.group == "listen" then
            out[#out + 1] = {
                title = p.title,
                line = p.model .. ", by " .. p.credit .. ", under the " .. p.licence .. " license ("
                    .. LICENCE_LINKS[p.licence] .. ").",
                link = p.url,
            }
        end
    end
    if voicemodels.smallReady() then
        out[#out + 1] = { title = voicemodels.SMALL.label,
            line = "Bragi's built-in voice, the project's own: a small model trained from Kokoro-82M (by hexgrad, "
                .. "under the Apache-2.0 license, " .. LICENCE_LINKS["Apache-2.0"] .. ") with the training code of "
                .. "Paradee (by Sahil Mahendrakar, Apache-2.0). Its pronunciations are misaki's dictionaries (by "
                .. "hexgrad, Apache-2.0).",
            link = "https://huggingface.co/hexgrad/Kokoro-82M" }
    end
    return out
end

local function callWords(call)
    return CALLS[call] or tostring(call or "a call")
end

--- Why voice stopped, from an engine error or gitgud.voiceEngine().
-- `e`: { code, message } (an error) or the engine table (faultCode, fault).
function voicemodels.faultText(e)
    local code = e.code or e.faultCode
    local detail = e.message or e.fault or ""
    if code == "engine-fault" or code == "engine-hung" then
        return "Voice stopped after an internal error in the speech engine"
            .. (code == "engine-hung" and " (it stopped answering)" or "")
            .. ". Restart GitGud to use voice again."
    elseif code == "engine-files" then
        return "The voice models need repairing: " .. detail .. ". Settings, Appearance and voice, Voice models."
    elseif code == "engine-missing" then
        return "The speech engine's files are missing or damaged: " .. detail .. ". Reinstall GitGud to fix them."
    elseif code == "engine-error" then
        return "Voice stopped: the speech engine failed several times in a row (" .. detail .. ")."
    end
    return "Voice stopped: " .. tostring(detail ~= "" and detail or code)
end

--- What to say about the app ending in the engine last time.
function voicemodels.crashText(crash)
    return "Last time, GitGud closed while voice was " .. callWords(crash.call) .. ", so voice is off for "
        .. "now. Press the mic button to turn it back on."
end

return voicemodels
