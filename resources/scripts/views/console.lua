--- views/console.lua — a console docked at the bottom of the window.
--
-- Type a command, press Enter: it runs through the system shell (cmd.exe,
-- or /bin/sh outside Windows)
-- in the repository's folder, and everything it prints streams into the
-- list above. Handy for the odd git command the app has no button for, and
-- for tools like git-lfs. One command runs at a time; Stop cancels it (and
-- anything it started). Up/Down in the input recall earlier commands.
-- Commands can't read input (there's no terminal behind them), so
-- interactive prompts end right away; git asks for credentials through its
-- credential manager window instead.
--
-- Other modules run things here too: console.run("git lfs pull").
--
-- Public API: console.toggle(), console.show(), console.run(command, onDone)

local C = require("core.palette")
local app = require("core.app")
local frame = require("views.frame")
local placeholder = require("ui.placeholder")
local repo = require("core.repo")
local settings = require("core.settings")
local text = require("core.text")

local console = { name = "console" }

local MAX_LINES = 3000
local MAX_HISTORY = 50

local lines = {}          -- rendered rows
local partial = ""        -- output after the last line break
local history = {}        -- earlier commands, oldest first
local historyIndex = nil  -- position while recalling with Up/Down
local running = nil       -- the command in flight, or nil
local startedAt = 0
local onDone = nil        -- callback for the command in flight

--- Load the command history.
local function loadHistory()
    history = {}
    for command in (settings.get("consoleHistory", "")):gmatch("[^\30]+") do
        history[#history + 1] = command
    end
end

--- Save the command history.
local function saveHistory()
    while #history > MAX_HISTORY do
        table.remove(history, 1)
    end
    settings.set("consoleHistory", table.concat(history, "\30"))
end

--- Push rows into the list and keep it scrolled to the bottom.
local function flush()
    while #lines > MAX_LINES do
        table.remove(lines, 1)
    end

    local rows = {}
    for i, line in ipairs(lines) do
        rows[i] = line
    end
    if partial ~= "" then
        rows[#rows + 1] = text.colour(C.text2, partial)
    end
    gitgud.setList("ConsoleList", rows)
    gitgud.setScroll("ConsoleList", 1e9)
end

--- Append one line of a given colour.
-- @param colour  AARRGGBB
-- @param line    plain text
local function append(colour, line)
    lines[#lines + 1] = text.colour(colour, (line:gsub("\t", "    ")))
end

--- Paint the header (folder, busy state).
local function paintHeader()
    local where = repo.state().open and repo.state().path or "(no repository)"
    local note = running and text.colour(C.warn, "   running: " .. running) or ""
    gitgud.setText("ConsoleCwdLabel", text.colour(C.dim, where) .. note)
    gitgud.setEnabled("ConsoleStopButton", running ~= nil)
    gitgud.setEnabled("ConsoleRunButton", running == nil)
end

--- Open the console.
function console.show()
    if not frame.consoleVisible() then
        frame.setConsole(true)
    end
    paintHeader()
    gitgud.focus("ConsoleInputEdit")
end

--- Open or close the console.
function console.toggle()
    if frame.consoleVisible() then
        frame.setConsole(false)
    else
        console.show()
    end
end

--- Run a command in the repository folder, showing the console.
-- @param command   command line
-- @param callback  optional function(exitCode) when it finishes
-- @return true when it started
function console.run(command, callback)
    command = text.trim(command or "")
    if command == "" then
        return false
    end
    console.show()

    if running then
        append(C.warn, "Wait for \"" .. running .. "\" to finish (or press Stop).")
        flush()
        return false
    end

    if command == "cls" or command == "clear" then
        lines = {}
        partial = ""
        flush()
        return true
    end

    append(C.cyan, "> " .. command)
    local ok, err = gitgud.runCommand(command)
    if not ok then
        append(C.err, err or "Could not start the command.")
        flush()
        return false
    end

    running = command
    onDone = callback
    startedAt = gitgud.now()
    if history[#history] ~= command then
        history[#history + 1] = command
        saveHistory()
    end
    historyIndex = nil
    paintHeader()
    flush()
    return true
end

--- A command finished.
-- @param code  exit code (string)
local function finished(code)
    if partial ~= "" then
        append(C.text2, partial)
        partial = ""
    end
    local seconds = (gitgud.now() - startedAt) / 1000
    local ok = tonumber(code) == 0
    local note = string.format("%s after %.1fs", ok and "done" or ("exit code " .. tostring(code)), seconds)
    if tonumber(code) == -1 then
        note = "stopped"
    end
    append(ok and C.dim or C.warn, "  (" .. note .. ")")
    running = nil
    paintHeader()
    flush()
    -- The command may well have changed the repository.
    app.requestRefresh()

    local callback = onDone
    onDone = nil
    if callback then
        callback(tonumber(code) or -1)
    end
end

--- Output arrived: split into lines (a bare \r rewrites the current line,
-- like progress counters do).
-- @param chunk  text
local function onOutput(chunk)
    local buffer = partial .. chunk
    partial = ""
    for piece, sep in buffer:gmatch("([^\r\n]*)([\r\n]?)") do
        if sep == "\n" then
            append(C.text2, piece)
        elseif sep == "\r" then
            partial = ""
            if piece ~= "" then
                partial = piece
            end
        elseif piece ~= "" then
            partial = piece
        end
    end
    -- "\r\n" pairs come through as "\r" then an empty line; drop those.
    flush()
end

--- Recall an earlier command.
-- @param delta  -1 older, +1 newer
local function recall(delta)
    if #history == 0 then
        return
    end

    historyIndex = (historyIndex or (#history + 1)) + delta
    historyIndex = math.max(1, math.min(#history + 1, historyIndex))
    placeholder.setText("ConsoleInputEdit", history[historyIndex] or "")
end

--- Refresh the header when the repository changes.
function console.refresh()
    if frame.consoleVisible() then
        paintHeader()
    end
end

--- Wire the pane.
function console.init()
    loadHistory()
    placeholder.bind("ConsoleInputEdit", "ConsoleInputPlaceholder")

    gitgud.on("ConsoleInputEdit.accepted", function()
        local command = gitgud.getText("ConsoleInputEdit")
        if console.run(command) then
            placeholder.setText("ConsoleInputEdit", "")
        end
    end)
    gitgud.on("ConsoleRunButton.clicked", function()
        local command = gitgud.getText("ConsoleInputEdit")
        if console.run(command) then
            placeholder.setText("ConsoleInputEdit", "")
        end
    end)
    gitgud.on("ConsoleStopButton.clicked", function()
        gitgud.cancelCommand()
    end)
    gitgud.on("ConsoleClearButton.clicked", function()
        lines = {}
        partial = ""
        flush()
    end)
    gitgud.on("ConsoleCloseButton.clicked", function()
        frame.setConsole(false)
    end)

    gitgud.on("console.output", onOutput)
    gitgud.on("console.done", finished)
    gitgud.on("console.error", function(detail)
        append(C.err, tostring(detail))
        finished("-1")
    end)

    gitgud.on("key", function(combo)
        if not frame.consoleVisible() or not gitgud.textInputFocused() then
            return
        end
        -- Only while typing in the console's own box.
        if gitgud.getProperty("ConsoleInputEdit", "Active") ~= "true" then
            return
        end
        if combo == "up" then
            recall(-1)
        elseif combo == "down" then
            recall(1)
        end
    end)

    -- A hot reload loses the VM's memory of a running command; ask C++.
    if gitgud.commandRunning() then
        running = "(earlier command)"
    end
    paintHeader()
end

return console
