--- tests/ui/signin.lua: sign-in dialogs through the real UI.
--
-- Same harness as remotes.lua (GITGUD_SCRIPT, GITGUD_SHOTS, a repository
-- made by make-testrepo.ps1, and a scratch APPDATA). Covers the masked
-- password field (typed text hidden, the last character shown briefly, the
-- real text still read back), the "credential.rejected" prompt, and the
-- GitHub browser sign-in up to the one-time code: with no gh on PATH it
-- downloads the GitHub CLI into the scratch APPDATA, starts
-- `gh auth login --web`, shows the code, then cancels. Opening the browser,
-- the clipboard, and `gh auth token` (gh's token lives in the real Windows
-- Credential Manager) are stubbed so nothing reaches the desktop or account. Prints
-- "[check] ..." lines that the log can be grepped for.

local OUT = os.getenv("GITGUD_SHOTS") or "."
local steps = {}
local opened = {}
local marks = {}

-- Keep the test off the real desktop.
gitgud.openExternal = function(target)
    opened[#opened + 1] = target
    return true
end
-- gh keeps its token in the Windows Credential Manager, which a scratch
-- APPDATA doesn't isolate: pretend gh isn't signed in, so the test never
-- picks up (and saves) the real account's token.
local runProgram = gitgud.runProgram
gitgud.runProgram = function(args, ...)
    if args[2] == "auth" and args[3] == "token" then
        return { code = 1, output = "", error = "not signed in (test)" }
    end
    return runProgram(args, ...)
end

-- Nor save anything there.
gitgud.setCredential = function()
    print("[ui-test] setCredential called (stubbed)")
    return true
end

local copied = {}
gitgud.setClipboard = function(value)
    copied[#copied + 1] = value
    return true
end

local function step(delay, label, fn)
    steps[#steps + 1] = { delay = delay, label = label, fn = fn }
end

local function shot(name)
    gitgud.screenshot(OUT .. "/" .. name .. ".png")
end

local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end

local function dialogOpen()
    return gitgud.getProperty("Dialog", "Visible") == "true"
end

local function run(i)
    local s = steps[i]
    if not s then
        print("[ui-test] finished")
        gitgud.emit("window.close", "")
        return
    end

    gitgud.after(s.delay, function()
        if not s.logged then
            s.logged = true
            print("[ui-test] " .. i .. ": " .. s.label)
        end
        local ok, result = pcall(s.fn)
        if not ok then
            print("[ui-test] step " .. i .. " failed: " .. tostring(result))
            check("step " .. i .. " (" .. s.label .. ") ran without errors", false)
        end
        if ok and type(result) == "number" and result > 0 then
            -- The step asked to be run again after `result` ms (polling).
            steps[i].delay = result
            run(i)
            return
        end
        run(i + 1)
    end)
end

-- Polling helper for steps: returns ms to wait again, or nil when done.
local polls = {}
local function poll(key, limit, ready, label)
    polls[key] = (polls[key] or 0) + 500
    if ready() then
        check(label, true)
        return nil
    end
    if polls[key] >= limit then
        check(label, false)
        return nil
    end
    return 500
end

-- ---- masked password field ---------------------------------------------------

step(1500, "ask for a password", function()
    gitgud.emit("credential.missing", "git.example.com")
end)

step(500, "type into the masked field", function()
    check("sign-in dialog is open", dialogOpen())
    check("password field is masked",
        gitgud.getProperty("DialogField2", "TextMaskingEnabled") == "true")
    check("username field is not masked",
        gitgud.getProperty("DialogField1", "TextMaskingEnabled") == "false")
    clickWidget("DialogField2")
    gitgud.simulateText("hunter2")
    shot("s01-last-char-visible")
end)

step(1500, "the last character is masked again", function()
    shot("s02-all-masked")
    check("the real text is still read back", gitgud.getText("DialogField2") == "hunter2")
end)

step(300, "cancel", function()
    clickWidget("DialogCancelButton")
end)

step(500, "a refused credential asks again", function()
    check("dialog closed", not dialogOpen())
    gitgud.emit("credential.rejected", "git.example.com")
end)

step(500, "rejected message", function()
    check("dialog is open again", dialogOpen())
    check("it says the saved sign-in was refused",
        (gitgud.getText("DialogMessage") or ""):find("didn't accept", 1, true) ~= nil)
    check("the field starts empty", gitgud.getText("DialogField2") == "")
    shot("s03-rejected")
end)

step(300, "cancel", function()
    clickWidget("DialogCancelButton")
end)

step(500, "other dialogs are not masked", function()
    require("ui.dialog").prompt("Plain", "Name", "visible", "OK", function()
        return true
    end)
end)

step(300, "plain field", function()
    check("a plain field is not masked",
        gitgud.getProperty("DialogField1", "TextMaskingEnabled") == "false")
    clickWidget("DialogCancelButton")
end)

-- ---- GitHub through the browser --------------------------------------------------

step(500, "GitHub needs a sign-in", function()
    gitgud.emit("credential.missing", "github.com")
end)

step(500, "GitHub dialog", function()
    check("GitHub dialog is open", dialogOpen())
    check("it's the GitHub sign-in", gitgud.getText("DialogTitle") == "Sign in to GitHub")
    check("a token is still possible", gitgud.getProperty("DialogAltButton", "Visible") == "true")
    print("[ui-test] ok button: " .. tostring(gitgud.getText("DialogOkButton")))
    shot("s04-github")
end)

step(300, "sign in with the browser", function()
    clickWidget("DialogOkButton")
end)

step(500, "wait for the download and the code", function()
    return poll("code", 120000, function()
        return dialogOpen() and (gitgud.getText("DialogMessage") or ""):find("code", 1, true) ~= nil
    end, "the one-time code is shown")
end)

step(200, "code dialog", function()
    local message = gitgud.getText("DialogMessage") or ""
    local code = message:match("([%w]+%-[%w]+)")
    check("a code like XXXX-XXXX is shown", code ~= nil and #code == 9)
    marks.code = code
    check("the code was copied automatically", copied[1] == code)
    check("the dialog says it's on the clipboard", message:find("copied to your clipboard", 1, true) ~= nil)
    check("there's a Copy code button", gitgud.getText("DialogAltButton") == "Copy code"
        and gitgud.getProperty("DialogAltButton", "Visible") == "true")
    check("the device page was opened",
        opened[#opened] ~= nil and opened[#opened]:find("/login/device", 1, true) ~= nil)
    check("GitGud's own gh copy is installed", #gitgud.installedTools("gh") == 1)
    shot("s05-code")
end)

step(300, "open the page again", function()
    clickWidget("DialogOkButton")
end)

step(500, "open again keeps it open", function()
    check("the dialog stays open", dialogOpen())
    check("the page was opened again", #opened >= 2)
    marks.copies = #copied
    clickWidget("DialogAltButton")
end)

step(500, "copy code keeps it open", function()
    check("Copy code keeps the dialog open", dialogOpen())
    check("Copy code copied the code", #copied == marks.copies + 1 and copied[#copied] == marks.code)
    clickWidget("DialogCancelButton")
end)

step(500, "cancel stops gh", function()
    return poll("stopped", 10000, function()
        return (gitgud.getText("StatusLabel") or ""):find("cancelled", 1, true) ~= nil
            or not gitgud.stopProgram("github.login")
    end, "gh stopped after cancel")
end)

step(300, "done", function()
    check("dialog closed", not dialogOpen())
    shot("s06-cancelled")
end)

run(1)
