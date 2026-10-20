--- bragi/customize.lua: your own changes to the Bragi interface.
--
-- The shipped interface (resources/uis/bragi/) stays as installed. Files in
-- the customizations folder, <config>/bragi/ui/ (gitgud.uiOverlay().root),
-- with the same paths are used instead: scripts/bragi/*.lua, layouts/,
-- looknfeel/, imagesets/, themes/<name>.ini (a new theme is offered beside
-- Light and Dark), prompts/*.md. An update never overwrites them, and they
-- reload as they're saved, like the shipped files. A customized script or
-- layout that fails to load is set aside for that run and the shipped one
-- is used, with a note naming the file and the error.
--
-- Bragi can make these changes itself (the main session's and Bragi's
-- prompts say how): bragi_ui_paths (no permission card) gives it both
-- folders and the files customized, and it edits the folder with its
-- normal file tools, through Claude Code's usual permission prompts.
--
-- Settings (Git, Interface customizations) lists the customized files and any that didn't
-- load, opens the folder, and resets them all (the folder moved aside to a
-- dated backup, then the interface reloads).
--
-- Public API: customize.overlay(), customize.rows(), customize.definitions(),
-- customize.handle(call, reply), customize.themeColours(name), customize.roots()

local status = require("core.status")
local text = require("core.text")

local customize = { name = "bragi.customize" }

--- Where the interface's own files are read from, in order: your
-- customizations, the running interface, the shipped Bragi folder.
function customize.roots()
    local roots = {}
    local ui = gitgud.currentUi and gitgud.currentUi() or nil
    if ui and (ui.overlay or "") ~= "" then
        roots[#roots + 1] = ui.overlay
    end
    if ui and ui.root then
        roots[#roots + 1] = ui.root
    end
    roots[#roots + 1] = gitgud.appDir() .. "/resources/uis/bragi"
    return roots
end

--- gitgud.uiOverlay(): { root, shipped, files, errors }.
function customize.overlay()
    local o = gitgud.uiOverlay and gitgud.uiOverlay() or {}
    o.root, o.shipped = o.root or "", o.shipped or ""
    o.files, o.errors = o.files or {}, o.errors or {}
    return o
end

-- A file's path inside the customizations folder.
local function relative(o, file)
    local root = o.root:gsub("\\", "/")
    local f = tostring(file):gsub("\\", "/")
    if f:sub(1, #root + 1) == root .. "/" then
        return f:sub(#root + 2)
    end
    return f
end

--- A theme's main colours from its file (the shipped one or yours):
-- { bg, text, sub, accent, panel } as AARRGGBB, or nil.
function customize.themeColours(name)
    local path = gitgud.uiFile and gitgud.uiFile("themes/" .. name .. ".ini")
    local f = path and io.open(path, "rb")
    if not f then
        return nil
    end
    local out = {}
    for line in f:lines() do
        local key, value = line:match("^%s*([%w%-]+)%s*=%s*(%x%x%x%x%x%x%x%x)")
        if key then
            out[key] = value
        end
    end
    f:close()
    return out.bg and out or nil
end

local function resetAll()
    require("ui.dialog").confirm("Reset all customizations?",
        "Your customized files are moved aside to a backup folder beside them, and the shipped interface "
            .. "reloads.", "Reset all", function()
            local backup, err = gitgud.uiOverlayReset()
            if backup then
                status.ok("Customizations moved to " .. backup .. ".")
            else
                status.error("Couldn't reset: " .. tostring(err))
            end
        end, true)
end

--- Settings' rows (the Git section's Interface customizations card).
function customize.rows()
    local o = customize.overlay()
    if o.root == "" then
        return { { kind = "info", title = "Interface customizations", sub = "Not for this interface." } }
    end
    local rows = {}
    local files = o.files
    rows[#rows + 1] = { kind = "info", title = "Interface customizations",
        sub = #files == 0 and ("None. Files in the customizations folder replace the shipped ones of the "
            .. "same path, survive updates, and reload as you save them. Ask Bragi to change the interface, or "
            .. "copy a shipped file there and edit it.")
            or (text.plural(#files, "file") .. ": " .. table.concat(files, ", ") .. ".") }
    for _, e in ipairs(o.errors) do
        rows[#rows + 1] = { kind = "info", title = "Not used: " .. relative(o, e.file),
            sub = tostring(e.error) .. ". The shipped file is used instead." }
    end
    rows[#rows + 1] = { kind = "action", title = "Open the customizations folder", sub = o.root, button = "Open",
        run = function()
            gitgud.uiOverlay(true) -- made if it isn't there
            gitgud.openExternal(o.root)
        end }
    if #files > 0 then
        rows[#rows + 1] = { kind = "action", title = "Reset all",
            sub = "Back to the shipped interface; your files are kept in a backup folder.", button = "Reset all",
            run = resetAll }
    end
    return rows
end

-- ---------------------------------------------------------------------
-- The tool

function customize.definitions()
    return {
        {
            name = "bragi_ui_paths",
            description = "Where Bragi's own interface files are: the shipped folder (read-only, for reference) "
                .. "and the customizations folder (a file there with the same path replaces the shipped one and "
                .. "reloads as it's saved), and which files are customized now.",
            inputSchema = { type = "object", properties = {}, additionalProperties = false },
            annotations = { readOnlyHint = true },
            noCard = true, -- it only reads (bragi/uitools.lua)
        },
    }
end

function customize.handle(call)
    if call.tool ~= "bragi_ui_paths" then
        return "No tool named " .. tostring(call.tool) .. ".", true
    end
    local o = customize.overlay()
    if o.root == "" then
        return "This interface can't be customized.", true
    end
    local lines = {
        "Shipped interface (read-only, copy from here): " .. o.shipped,
        "Customizations folder (create or edit files here, same paths): " .. o.root,
        #o.files == 0 and "Customized now: none." or ("Customized now: " .. table.concat(o.files, ", ") .. "."),
    }
    for _, e in ipairs(o.errors) do
        lines[#lines + 1] = "Not loading (the shipped file is used): " .. relative(o, e.file) .. ": " .. tostring(e.error)
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------

-- A note for each customized file that didn't load.
local function noteErrors()
    local o = customize.overlay()
    for _, e in ipairs(o.errors) do
        status.warn("Your customized " .. relative(o, e.file) .. " didn't load (" .. tostring(e.error)
            .. "); the shipped one is used.")
    end
end

function customize.init()
    require("bragi.uitools").register(customize.definitions(), customize.handle)
    gitgud.on("app.started", function()
        gitgud.after(0, noteErrors)
    end)
    gitgud.on("ui.overlayError", function()
        gitgud.after(0, function()
            require("bragi.settings").rebuild("git")
        end)
    end)
end

return customize
