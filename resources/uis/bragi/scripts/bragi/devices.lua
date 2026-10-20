-- Bragi: the microphone and speaker pickers and a level meter, shared by
-- Settings (Appearance and voice) and the welcome flow's voice step.
--
-- devices.new{ audio = fn, rebuild = fn } -> a picker:
--   picker.rows()       the Microphone, Speakers, and level meter rows
--   picker.setMeter(on) start or stop the meter's microphone
--   picker.meter()      { on, level, error } (tests)
-- `audio` returns the audio layer to use ({ devices, use, test }, as
-- devices.audio); `rebuild` redraws the cards around the rows.
--
-- devices.audio        the bindings (gitgud.audioDevices, setAudioDevices,
--                      micTest); UI tests swap its fields.
-- devices.apply(audio) send the saved choices to the audio layer.
-- devices.inputName()  the microphone voice opens now, for the log.
--
-- Settings keys: bragi.micDevice, bragi.speakerDevice ("" = the system's
-- default device, where other apps play and record; not the communications
-- one).

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
}

local function choices(list)
    local out = { { id = "", label = "System default" } }
    for _, d in ipairs(type(list) == "table" and list or {}) do
        out[#out + 1] = { id = d.id, label = d.name .. (d.default and " (default)" or "") }
    end
    return out
end

function devices.apply(audio)
    (audio or devices.audio).use(settings.get("bragi.micDevice", ""), settings.get("bragi.speakerDevice", ""))
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
        return {
            choiceRow("Microphone", opts.micSub, inputs, "bragi.micDevice"),
            choiceRow("Speakers", opts.speakerSub, outputs, "bragi.speakerDevice"),
            meterRow(),
        }
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
