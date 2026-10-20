--- tests/ui/bragi-renew.lua: the Bragi interface after the main window is
-- renewed (main.cpp's renewWindow): it looks as before and the prompt box
-- still takes typing.
--
-- Run it like the other Bragi tests (GITGUD_UI=bragi, scratch APPDATA,
-- LOCALAPPDATA and CLAUDE_CONFIG_DIR, GITGUD_SCRIPT, GITGUD_SHOTS). Prints
-- "[check] ..." lines.

local OUT = os.getenv("GITGUD_SHOTS") or "."

local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then
        return 0
    end
    local n = f:seek("end")
    f:close()
    return n
end

local renewals = {}
gitgud.on("window.renewed", function(why)
    renewals[#renewals + 1] = why
end)

local FIRST = OUT .. "/bragi-renew-0-before.png"
local AFTER = OUT .. "/bragi-renew-1-after.png"
local steps = {
    function()
        require("bragi.shell").show("agent")
    end,
    function()
        gitgud.screenshot(FIRST)
    end,
    function()
        gitgud.emit("window.renew", "asked by the test")
    end,
    function()
        check("the window was renewed", #renewals == 1)
        gitgud.screenshot(AFTER)
    end,
    function()
        local w, h = gitgud.imageSize(AFTER)
        local wa, ha = gitgud.imageSize(FIRST)
        local n, na = fileSize(AFTER), fileSize(FIRST)
        check(string.format("it shows the Agent view as before (%sx%s, %d bytes; before %sx%s, %d bytes)",
            tostring(w), tostring(h), n, tostring(wa), tostring(ha), na),
            w ~= nil and w == wa and h == ha and na > 0 and math.abs(n - na) <= na / 4)
        gitgud.focus("AgentPromptEdit")
        gitgud.simulateText("still here")
    end,
    function()
        check("the prompt box still takes typing", gitgud.getText("AgentPromptEdit") == "still here")
        gitgud.emit("window.close", "")
    end,
}

local DELAYS = { 2500, 800, 700, 900, 900, 600 }

local function run(i)
    if steps[i] then
        gitgud.after(DELAYS[i] or 700, function()
            local ok, err = pcall(steps[i])
            if not ok then
                check("step " .. i .. " ran without errors: " .. tostring(err), false)
            end
            run(i + 1)
        end)
    end
end

run(1)
