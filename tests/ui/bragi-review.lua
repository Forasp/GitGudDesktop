--- tests/ui/bragi-review.lua: reviewing the changes (G4): the changed
-- files with the session's edits first, a file's diff, comments on its
-- lines (by clicking one), and sending them to the session as one message.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE set to
-- build\release\bin\gitgud_test_claude.exe, and CLAUDE_CONFIG_DIR set to a
-- scratch folder). Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake or not os.getenv("CLAUDE_CONFIG_DIR") then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local dialog = require("ui.dialog")
local repo = require("core.repo")
local review = require("bragi.review")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)

local function shot(name)
    gitgud.screenshot(OUT .. "/review-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function visible(name)
    return gitgud.getProperty(name, "Visible") == "true"
end
local function lastUser()
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == "user" then
            return items[i].text
        end
    end
    return nil
end
local function lineRow(origin, content)
    for i, row in ipairs(review.rows()) do
        if row.kind == "line" and row.line.origin == origin and row.line.content:find(content, 1, true) then
            return i
        end
    end
    return nil
end

step(1500, "start a session", function()
    shell.show("agent")
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText("hello")
    gitgud.simulateKey("enter")
end)

step(1500, "the session edits notes.txt", function()
    check("a session is running", agent.session().running == true)
    local root = repo.state().path
    gitgud.emit("agent.tool", gitgud.jsonEncode({ session = agent.session().name, id = "toolu_e1", name = "Edit",
        input = { file_path = root .. "/notes.txt", old_string = "", new_string = "brand new notes" }, parent = "" }))
    gitgud.emit("agent.toolResult", gitgud.jsonEncode({ session = agent.session().name, id = "toolu_e1",
        text = "ok", isError = false, parent = "" }))
end)

step(300, "open the review", function()
    clickWidget("AgentReviewButton")
end)

step(400, "the changed files", function()
    check("the review is open", review.isOpen() and visible("AgentReview"))
    local files = review.files()
    check("every changed file is listed", #files == 4)
    check("the session's edit comes first, marked", files[1] and files[1].path == "notes.txt" and files[1].edited)
    check("other files aren't marked", files[2] and not files[2].edited)
    check("the first file's diff shows", lineRow("+", "brand new notes") ~= nil)
    shot("01-files")
end)

step(200, "pick src/main.cpp", function()
    review.selectFile("src/main.cpp")
    check("its diff shows", lineRow("+", "int line2 = 200;") ~= nil and lineRow("-", "int line2 = 2;") ~= nil)
    check("two hunks", (function()
        local n = 0
        for _, row in ipairs(review.rows()) do
            n = n + (row.kind == "header" and 1 or 0)
        end
        return n == 2
    end)())
    check("Send waits for a comment", gitgud.getProperty("AgentReviewSend", "Disabled") == "true")
end)

step(200, "comment on a removed line from code", function()
    check("a comment is added", review.comment(lineRow("-", "int line2 = 2;"), "Why drop this?"))
    check("it shows under its line", (function()
        local i = lineRow("-", "int line2 = 2;")
        local below = review.rows()[i + 1]
        return below and below.kind == "comment" and below.comment.text == "Why drop this?"
    end)())
end)

step(200, "click a line to comment", function()
    -- The list's second row: a line under the first hunk's header.
    local x, y, w = gitgud.getRect("AgentReviewDiff")
    gitgud.simulateClick(x + w / 2, y + 30, "left")
end)

step(400, "the comment dialog", function()
    check("clicking a line asks for a comment", dialog.isOpen())
    gitgud.setText("DialogField1", "Name this constant.")
    shot("02-dialog")
    clickWidget("DialogOkButton")
end)

step(400, "two comments", function()
    local list = review.comments()
    check("two comments are kept", #list == 2)
    check("the clicked line's comment", list[1] and list[1].text == "Name this constant." or
        list[2] and list[2].text == "Name this constant.")
    check("Send is on", gitgud.getProperty("AgentReviewSend", "Disabled") ~= "true")
    check("the header counts them", (gitgud.getText("AgentReviewButton") or ""):find("2", 1, true) ~= nil)
    shot("03-comments")
end)

step(200, "comment on the new file, then remove it", function()
    review.selectFile("notes.txt")
    local i = lineRow("+", "second line")
    review.comment(i, "Temporary")
    check("a third comment", #review.comments() == 3)
    review.comment(i, "")
    check("an empty comment removes it", #review.comments() == 2)
end)

step(200, "back keeps them", function()
    clickWidget("AgentReviewClose")
    check("the review closed", not review.isOpen() and not visible("AgentReview"))
    check("the comments are kept", #review.comments() == 2)
    review.open()
    check("they're there on reopening", review.isOpen() and #review.comments() == 2)
end)

step(200, "the message", function()
    local m = review.message() or ""
    check("names the removed line", m:find("src/main.cpp (removed line 2): `int line2 = 2;`", 1, true) ~= nil)
    check("carries the comment", m:find("   Why drop this?", 1, true) ~= nil)
end)

step(200, "send them", function()
    clickWidget("AgentReviewSend")
end)

step(1200, "sent to the session", function()
    check("the review closed on sending", not review.isOpen())
    local sent = lastUser() or ""
    check("one message with every comment", sent:find("Review comments", 1, true) ~= nil
        and sent:find("Why drop this?", 1, true) ~= nil and sent:find("Name this constant.", 1, true) ~= nil)
    check("the comments are cleared", #review.comments() == 0)
    check("the header button is back to Review", gitgud.getText("AgentReviewButton") == "Review")
    shot("04-sent")
end)

step(200, "palette command and Escape", function()
    review.open()
    check("opens again", review.isOpen())
    gitgud.emit("key", "escape")
end)

step(300, "Escape closed it", function()
    check("Escape goes back to the conversation", not review.isOpen())
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
