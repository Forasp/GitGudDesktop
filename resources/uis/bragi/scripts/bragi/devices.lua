-- Bragi: the microphone and speaker pickers and a level meter, shared by
-- Settings (Appearance and voice) and the welcome flow's voice step.
--
-- devices.new{ audio = fn, rebuild = fn, echo = bool } -> a picker:
--   picker.rows()       the Microphone, Speakers, and level meter rows, and
--                       with `echo`, the speaker delay and the echo test
--   picker.setMeter(on) start or stop the meter's microphone
--   picker.meter()      { on, level, error } (tests)
--   picker.echoTest()   run the echo test (the Test button)
--   picker.echo()       { running, result } (tests)
--
-- The speaker delay: how late the speaker's sound reaches the microphone,
-- past what the system knows (a receiver, a soundbar, a long digital
-- output). The system's echo cancelling can't follow a long one, and Bragi
-- hears itself; with a delay set, voice lines the speaker up itself
-- (gitgud.setEchoDelay). The echo test plays a few seconds of Baldr's
-- voice and measures it (gitgud.echoTest); listening pauses while it runs.
-- A delay under ECHO_SYSTEM_MS is left to the system.
-- `audio` returns the audio layer to use ({ devices, use, test }, as
-- devices.audio); `rebuild` redraws the cards around the rows.
--
-- devices.audio        the bindings (gitgud.audioDevices, setAudioDevices,
--                      micTest, setEchoDelay, echoTest); UI tests swap its
--                      fields.
-- devices.apply(audio) send the saved choices to the audio layer.
-- devices.inputName()  the microphone voice opens now, for the log.
-- devices.echoDelay()  the speaker delay setting, in ms (0: none).
--
-- Settings keys: bragi.micDevice, bragi.speakerDevice ("" = the system's
-- default device, where other apps play and record; not the communications
-- one), bragi.echoDelayMs ("0": none).

local C = require("core.palette")
local agent = require("bragi.agent")
local app = require("core.app")
local settings = require("core.settings")
local ui = require("bragi.ui")

local devices = { name = "bragi.devices" }

devices.audio = {
    devices = function()
        return gitgud.audioDevices()
    end,
    use = function(input, output)
        gitgud.setAudioDevices(input, output)
    end,
    test = function(on)
        return gitgud.micTest(on)
    end,
    echo = function(ms)
        gitgud.setEchoDelay(ms)
    end,
    -- Baldr's own recording: some microphones filter out beeps, and
    -- speech gets through.
    echoTest = function(task)
        local wav = nil
        for _, root in ipairs(require("bragi.customize").roots()) do
            if root and not wav and gitgud.pathExists(root .. "/voices/baldr/ref.wav") then
                wav = root .. "/voices/baldr/ref.wav"
            end
        end
        return gitgud.echoTest(task, wav, 5)
    end,
}

devices.ECHO_MAX_MS = 600   -- the slider's end
devices.ECHO_SYSTEM_MS = 60 -- a measured delay under this is the system's to cancel
local ECHO_TASK = "BragiEchoTest"

local function choices(list)
    local out = { { id = "", label = "System default" } }
    for _, d in ipairs(type(list) == "table" and list or {}) do
        out[#out + 1] = { id = d.id, label = d.name .. (d.default and " (default)" or "") }
    end
    return out
end

--- The speaker delay setting, in whole ms, 0 to ECHO_MAX_MS.
function devices.echoDelay()
    local ms = tonumber(settings.get("bragi.echoDelayMs", "0")) or 0
    return math.max(0, math.min(devices.ECHO_MAX_MS, math.floor(ms + 0.5)))
end

function devices.apply(audio)
    audio = audio or devices.audio
    audio.use(settings.get("bragi.micDevice", ""), settings.get("bragi.speakerDevice", ""))
    if audio.echo then
        audio.echo(devices.echoDelay())
    end
end

--- The name of the microphone voice opens: the chosen one while it's
-- plugged in, else the default.
function devices.inputName()
    local list = (devices.audio.devices() or {}).inputs or {}
    local chosen = settings.get("bragi.micDevice", "")
    local default
    for _, d in ipairs(list) do
        if chosen ~= "" and d.id == chosen then
            return d.name
        end
        if d.default then
            default = d.name
        end
    end
    if chosen ~= "" then
        return (default or "the default") .. " (the chosen one isn't plugged in)"
    end
    return default and (default .. " (default)") or "the default"
end

function devices.new(opts)
    local picker = {}
    local meter = { on = false, level = 0, fill = nil, width = 0, error = nil }
    local function audio()
        return opts.audio and opts.audio() or devices.audio
    end

    local function paint()
        if meter.fill and gitgud.getRect(meter.fill) then
            local w = math.floor(meter.width * math.max(0, math.min(1, meter.level)) + 0.5)
            gitgud.setProperty(meter.fill, "Area", string.format("{{0,0},{0,0},{0,%d},{1,0}}", math.max(w, 0)))
            gitgud.setVisible(meter.fill, w > 0)
        end
    end

    function picker.setMeter(on)
        if on == meter.on then
            return
        end
        meter.error = nil
        if on then
            devices.apply(audio())
            local ok, err = audio().test(true)
            if not ok then
                meter.error = err or "The microphone could not start"
                on = false
            end
        else
            audio().test(false)
        end
        meter.on = on
        meter.level = 0
        meter.fill = nil
        opts.rebuild()
    end

    function picker.meter()
        return meter
    end

    -- The echo test: { running, result = { text, error } }.
    local echo = { running = false, result = nil, resume = false }

    function picker.echo()
        return echo
    end

    -- Its answer: the delay saved when the chirps were heard; listening
    -- picks up again if the test paused it.
    local function echoDone(detail)
        if not echo.running then
            return
        end
        echo.running = false
        local r = gitgud.jsonDecode(detail or "") or {}
        if r.ok ~= true then
            echo.result = { error = true, text = "The test didn't run: " .. tostring(r.error or "unknown error") .. "." }
        elseif r.heard ~= true then
            echo.result = { error = true, text = "The microphone didn't hear the test clearly. Check that the "
                .. "speakers are on and loud enough, then test again." }
        else
            local ms = math.floor((tonumber(r.delayMs) or 0) + 0.5)
            if ms < devices.ECHO_SYSTEM_MS then
                settings.set("bragi.echoDelayMs", "0")
                echo.result = { text = "Your speakers reach the microphone " .. ms
                    .. " ms late: the system's echo cancelling handles that." }
            else
                ms = math.min(devices.ECHO_MAX_MS, ms)
                settings.set("bragi.echoDelayMs", tostring(ms))
                echo.result = { text = "Your speakers reach the microphone " .. ms
                    .. " ms late. Voice now lines them up, so Bragi doesn't hear itself." }
            end
            app.publish("bragi.choices")
        end
        if echo.resume then
            echo.resume = false
            local voice = require("bragi.voice")
            if voice.state() == "off" then
                voice.toggle()
            end
        end
        opts.rebuild()
    end
    gitgud.on(ECHO_TASK .. ".done", echoDone)

    function picker.echoTest()
        if echo.running then
            return
        end
        if meter.on then
            picker.setMeter(false)
        end
        -- Listening would hear the chirps: it pauses.
        local voice = require("bragi.voice")
        echo.resume = voice.state() ~= "off"
        if echo.resume then
            voice.stop()
        end
        devices.apply(audio())
        echo.running = true
        echo.result = nil
        local ok, err = audio().echoTest(ECHO_TASK)
        if not ok then
            echo.running = false
            echo.result = { error = true, text = "The test didn't run: " .. tostring(err or "unknown error") .. "." }
            if echo.resume then
                echo.resume = false
                voice.toggle()
            end
        end
        opts.rebuild()
    end

    local function echoRows()
        return {
            { kind = "slider", title = "Speaker delay",
              sub = "How late your speakers' sound reaches the microphone. Voice lines them up so "
                  .. "Bragi doesn't hear itself; Off leaves it to the system.",
              key = "bragi.echoDelayMs", min = 0, steps = { { upTo = devices.ECHO_MAX_MS, step = 10 } },
              read = devices.echoDelay,
              show = function(n)
                  return n <= 0 and "Off" or (math.floor(n + 0.5) .. " ms")
              end,
              -- Told once it rests (listening restarts with it), not at
              -- every stop of a drag.
              onChange = function()
                  if echo.settle then
                      gitgud.cancelTimer(echo.settle)
                  end
                  echo.settle = gitgud.after(600, function()
                      echo.settle = nil
                      app.publish("bragi.choices")
                  end)
              end },
            { kind = "custom", height = 64, build = function(card, prefix, y, width)
                ui.label(prefix .. "Title", card, { 20, y + 12, 260, 20 }, "Echo test", { font = "Bragi-14-Bold" })
                local sub = echo.running and "Bragi is talking for a few seconds. Keep the room quiet."
                    or echo.result and echo.result.text
                    or "Plays a few seconds of Bragi's voice and measures the speaker delay. Keep the room quiet."
                ui.label(prefix .. "Sub", card, { 20, y + 34, width - 200, 18 }, sub,
                    { font = "Bragi-13", colour = echo.result and echo.result.error and C.err or C.sub })
                local button = ui.button(prefix .. "Action", card, { width - 160, y + 12, 140, 36 },
                    echo.running and "Testing" or "Test", { primary = not echo.running })
                gitgud.on(button .. ".clicked", function()
                    picker.echoTest()
                end)
            end },
        }
    end

    local function meterRow()
        return { kind = "custom", height = 76, build = function(card, prefix, y, width)
            ui.label(prefix .. "Title", card, { 20, y + 14, 260, 20 }, "Microphone level", { font = "Bragi-14-Bold" })
            local sub = meter.error or (meter.on and "Say something: the bar should move." or "Check that Bragi hears you.")
            ui.label(prefix .. "Sub", card, { 20, y + 36, width - 200, 18 }, sub,
                { font = "Bragi-13", colour = meter.error and C.err or C.sub })
            local button = ui.button(prefix .. "Action", card, { width - 160, y + 14, 140, 36 },
                meter.on and "Stop" or "Test", { primary = not meter.on })
            gitgud.on(button .. ".clicked", function()
                picker.setMeter(not meter.on)
            end)
            local trackW = width - 40
            local track = ui.box(prefix .. "Track", card, { 20, y + 60, trackW, 8 },
                { radius = 4, fill = C.well, border = C.border })
            meter.fill = ui.box(prefix .. "Fill", track, { 0, 0, 0, 8 }, { radius = 4, fill = C.add, border = C.transparent })
            meter.width = trackW
            paint()
        end }
    end

    function picker.rows()
        local list = audio().devices() or {}
        local inputs, outputs = choices(list.inputs), choices(list.outputs)
        local function choiceRow(title, sub, options, key)
            return { kind = "choice", title = title, sub = sub,
                label = function()
                    return agent.choiceLabel(options, key, "")
                end,
                pick = function(button)
                    agent.pickChoice(button, options, key, "")
                end }
        end
        local rows = {
            choiceRow("Microphone", opts.micSub, inputs, "bragi.micDevice"),
            choiceRow("Speakers", opts.speakerSub, outputs, "bragi.speakerDevice"),
            meterRow(),
        }
        if opts.echo then
            for _, row in ipairs(echoRows()) do
                rows[#rows + 1] = row
            end
        end
        return rows
    end

    gitgud.on("audio.level", function(detail)
        if meter.on then
            meter.level = tonumber(detail) or 0
            paint()
        end
    end)
    -- A new pick applies at once; a running meter follows it.
    app.subscribe("bragi.choices", function()
        devices.apply(audio())
        if meter.on then
            audio().test(false)
            audio().test(true)
        end
    end)
    return picker
end

return devices
