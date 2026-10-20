--- bragi/images.lua: pictures in a conversation. Thumbnails of image files
-- (your pasted or dropped ones, the agent's tool results, the files its
-- replies link with ![...](path)), and a viewer that shows one full size.
--
--   images.isImage(path)          true for an image file the app can show
--   images.place(parent, prefix, paths, x, y, width, opts) -> height
--                                 a wrapping row of thumbnails in parent;
--                                 click one to view it. opts: maxWidth,
--                                 maxHeight (one thumbnail's box), remove =
--                                 fn(i) (a small x on each)
--   images.linked(markdown)       the local image files a reply links to
--   images.view(path)             the viewer; images.close() closes it
--
-- Each file is shown through gitgud.showImage under a name of its own per
-- size (BragiThumb/<path>/<w>x<h>), so a picture shown twice is decoded once.

local C = require("core.palette")
local dialog = require("ui.dialog")
local geometry = require("ui.geometry")
local text = require("core.text")

local images = {}

local THUMB_W, THUMB_H = 220, 150
local GAP = 8
local MIN_FRAME = 48      -- a thumbnail's frame, at least
local VIEWER = "BragiImageViewer"
local VIEW_IMAGE = "BragiImage/View"

local known = {}         -- path -> { ok, at }: images.isImage's answers
local RECHECK_MS = 2000  -- a missing file is looked for again after this
local viewing = nil      -- { path, token } while the viewer is open

local EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true, bmp = true }

--- True for an image file the app can show.
function images.isImage(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local ext = path:match("%.([%w]+)$")
    if not ext or not EXTENSIONS[ext:lower()] then
        return false
    end
    local seen = known[path]
    local now = gitgud.now()
    if seen and (seen.ok or now - seen.at < RECHECK_MS) then
        return seen.ok
    end
    local ok = gitgud.imageSize(path) ~= nil
    known[path] = { ok = ok, at = now }
    return ok
end

--- The image name a file shows under at a size: named by its path, so
-- the pictures decoded before a hot reload are still there after it (a
-- count restarted at each reload and decoded them all again).
local function imageName(path, w, h)
    return "BragiThumb/" .. path .. "/" .. w .. "x" .. h
end

--- One thumbnail: a frame you click, the picture in it. Returns its size.
local function thumb(name, parent, path, maxW, maxH, remove)
    local w, h = gitgud.showImage(imageName(path, maxW, maxH), path, maxW, maxH)
    local missing = not w
    if missing then
        w, h = math.min(maxW, 160), 40
    end
    -- A tiny picture sits in the middle of a frame big enough to click
    -- (and to hold its x).
    local fw, fh = math.max(w + 2, MIN_FRAME), math.max(h + 2, MIN_FRAME)
    if not gitgud.getRect(name) then
        gitgud.createWindow("Bragi/Button8", name, parent)
        gitgud.setProperty(name, "Text", "")
        gitgud.setProperty(name, "NormalFillColour", C.panel)
        gitgud.setProperty(name, "HoverFillColour", C.hover)
        gitgud.setProperty(name, "PushedFillColour", C.sel)
        gitgud.setProperty(name, "BorderColour", C.border)
        gitgud.setProperty(name, "TooltipText", missing and path or ("Show it full size\n" .. path))
        gitgud.on(name .. ".clicked", function()
            images.view(path)
        end)
        if missing then
            gitgud.createWindow("Gitgud/Label", name .. "Missing", name)
            gitgud.setProperty(name .. "Missing", "Area", geometry.rect(8, 0, fw - 16, fh))
            gitgud.setProperty(name .. "Missing", "Font", "Bragi-12")
            gitgud.setProperty(name .. "Missing", "NormalTextColour", C.sub)
            gitgud.setProperty(name .. "Missing", "CursorPassThroughEnabled", "true")
            gitgud.setText(name .. "Missing", "Image not found")
        else
            gitgud.createWindow("Gitgud/Image", name .. "Picture", name)
            gitgud.setProperty(name .. "Picture", "Image", imageName(path, maxW, maxH))
            gitgud.setProperty(name .. "Picture", "Area", geometry.rect(math.floor((fw - w) / 2), math.floor((fh - h) / 2), w, h))
            gitgud.setProperty(name .. "Picture", "CursorPassThroughEnabled", "true")
        end
        if remove then
            local x = name .. "Remove"
            gitgud.createWindow("Bragi/Button8", x, name)
            gitgud.setProperty(x, "Area", geometry.rect(fw - 24, 4, 20, 20))
            gitgud.setProperty(x, "Text", "")
            gitgud.setProperty(x, "NormalFillColour", C.panel)
            gitgud.setProperty(x, "HoverFillColour", C.hover)
            gitgud.setProperty(x, "BorderColour", C.border)
            gitgud.setProperty(x, "TooltipText", "Remove")
            gitgud.createWindow("Gitgud/Icon", x .. "Icon", x)
            gitgud.setProperty(x .. "Icon", "Area", geometry.rect(5, 5, 10, 10))
            gitgud.setProperty(x .. "Icon", "IconImage", "Bragi-Icons/Close")
            gitgud.setProperty(x .. "Icon", "IconColour", C.sub)
            gitgud.setProperty(x .. "Icon", "GlowColour", "00000000")
            gitgud.setProperty(x .. "Icon", "CursorPassThroughEnabled", "true")
            gitgud.on(x .. ".clicked", remove)
        end
    end
    return fw, fh
end

--- A wrapping row of thumbnails.
-- @param parent  the window they go in
-- @param prefix  their window names' start (unique in the transcript)
-- @param paths   image files
-- @param x, y    where the row starts in parent
-- @param width   how wide it may be
-- @param opts    maxWidth, maxHeight, remove = fn(i)
-- @return its height, and the widest line's width
function images.place(parent, prefix, paths, x, y, width, opts)
    opts = opts or {}
    local maxW = math.max(40, math.min(opts.maxWidth or THUMB_W, width))
    local maxH = opts.maxHeight or THUMB_H
    local cx, cy, lineH, widest = 0, 0, 0, 0
    for i, path in ipairs(paths or {}) do
        local name = prefix .. i
        local remove = opts.remove and function()
            opts.remove(i)
        end
        local w, h = thumb(name, parent, path, maxW, maxH, remove)
        if cx > 0 and cx + w > width then
            cx, cy, lineH = 0, cy + lineH + GAP, 0
        end
        gitgud.setProperty(name, "Area", geometry.rect(x + cx, y + cy, w, h))
        cx = cx + w + GAP
        lineH = math.max(lineH, h)
        widest = math.max(widest, cx - GAP)
    end
    if lineH == 0 then
        return 0, 0
    end
    return cy + lineH, widest
end

--- The local image files a reply links to: ![what](path), a full path
-- (file:/// too) to a file that's there.
function images.linked(markdown)
    local out, seen = {}, {}
    for target in tostring(markdown or ""):gmatch("!%[[^%]]*%]%(([^%)]+)%)") do
        local path = text.trim(target):gsub("^<(.*)>$", "%1"):gsub("^file:///", "")
        path = path:gsub("%%20", " ")
        local full = path:match("^%a:[/\\]") or path:match("^/")
        if full and not seen[path] and images.isImage(path) then
            seen[path] = true
            out[#out + 1] = path
        end
    end
    return out
end

--- Build the viewer once.
local function create()
    if gitgud.getRect(VIEWER) then
        return
    end
    local ui = require("bragi.ui")
    gitgud.createWindow("Bragi/Box12", VIEWER, "Root")
    gitgud.setProperty(VIEWER, "FillColour", C.panel)
    gitgud.setProperty(VIEWER, "BorderColour", C.border)
    gitgud.setProperty(VIEWER, "AlwaysOnTop", "true")
    gitgud.setVisible(VIEWER, false)
    ui.label(VIEWER .. "Title", VIEWER, { 20, 14, 400, 24 }, "", { font = "Bragi-14-Bold" })
    gitgud.createWindow("Gitgud/Image", VIEWER .. "Picture", VIEWER)
    gitgud.setProperty(VIEWER .. "Picture", "CursorPassThroughEnabled", "true")
    ui.button(VIEWER .. "Open", VIEWER, { 0, 0, 84, 34 }, "Open")
    ui.button(VIEWER .. "Folder", VIEWER, { 0, 0, 120, 34 }, "Show in folder")
    ui.button(VIEWER .. "Close", VIEWER, { 0, 0, 84, 34 }, "Close", { primary = true })
    gitgud.on(VIEWER .. "Open.clicked", function()
        if viewing then
            gitgud.openExternal(viewing.path)
        end
    end)
    gitgud.on(VIEWER .. "Folder.clicked", function()
        if viewing then
            gitgud.showInFolder(viewing.path)
        end
    end)
    gitgud.on(VIEWER .. "Close.clicked", images.close)
end

--- Show an image file full size (scaled down to fit the window).
function images.view(path)
    if not images.isImage(path) then
        return false
    end
    create()
    local _, _, rootW, rootH = gitgud.getRect("Root")
    rootW, rootH = rootW or 1200, rootH or 800
    local w, h, fullW, fullH = gitgud.showImage(VIEW_IMAGE, path, math.max(200, rootW - 160),
        math.max(150, rootH - 200))
    if not w then
        return false
    end
    local panelW = math.max(w + 40, 420)
    local panelH = h + 112
    gitgud.setProperty(VIEWER, "Area", "{{0.5," .. -math.floor(panelW / 2) .. "},{0.5," .. -math.floor(panelH / 2)
        .. "},{0.5," .. math.ceil(panelW / 2) .. "},{0.5," .. math.ceil(panelH / 2) .. "}}")
    gitgud.setProperty(VIEWER .. "Picture", "Image", "")
    gitgud.setProperty(VIEWER .. "Picture", "Image", VIEW_IMAGE)
    gitgud.setProperty(VIEWER .. "Picture", "Area", geometry.rect(math.floor((panelW - w) / 2), 48, w, h))
    gitgud.setProperty(VIEWER .. "Title", "Area", geometry.rect(20, 14, panelW - 40, 24))
    gitgud.setText(VIEWER .. "Title", text.escape(text.basename(path)) .. "[font='Bragi-13'][colour='" .. C.sub
        .. "']  " .. fullW .. " \u{00D7} " .. fullH)
    gitgud.setProperty(VIEWER .. "Open", "Area", geometry.rect(20, panelH - 50, 84, 34))
    gitgud.setProperty(VIEWER .. "Folder", "Area", geometry.rect(112, panelH - 50, 120, 34))
    gitgud.setProperty(VIEWER .. "Close", "Area", geometry.rect(panelW - 104, panelH - 50, 84, 34))
    if viewing then
        dialog.hideModal(VIEWER, viewing.token)
    end
    viewing = { path = path }
    viewing.token = dialog.showModal(VIEWER, images.close)
    return true
end

--- Close the viewer.
function images.close()
    if viewing then
        dialog.hideModal(VIEWER, viewing.token)
        viewing = nil
    end
end

--- The file the viewer shows, or nil (for tests).
function images.viewing()
    return viewing and viewing.path
end

return images
