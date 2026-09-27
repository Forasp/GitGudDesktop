--- views/imagediff.lua — before/after view for image files.
--
-- gitgud.imageDiff(path, beforeRev, afterRev) decodes both versions in C++
-- and publishes four images: GitgudDiff/Before, /After, /Difference
-- (changed pixels painted neon pink over a dimmed copy), and /Onion (the
-- two blended). This module shows them in one of three modes and sizes each
-- picture to fit its frame without distortion.
--
-- Public API (used by views/content.lua):
--   imagediff.show(path, beforeRev, afterRev) -> true, or false + message
--   imagediff.hide()

local C = require("core.palette")
local geometry = require("ui.geometry")
local settings = require("core.settings")
local text = require("core.text")

local imagediff = { name = "imagediff" }

local info = nil   -- last gitgud.imageDiff() result

--- Fit a picture widget inside its frame at the image's aspect ratio.
-- @param image   Gitgud/Image widget
-- @param frame   its parent frame widget
-- @param width   image width in pixels
-- @param height  image height in pixels
local function fitInto(image, frame, width, height)
    local _, _, frameWidth, frameHeight = gitgud.getRect(frame)
    if not frameWidth then
        return
    end

    local x, y, w, h = geometry.fit(width, height, frameWidth - 16, frameHeight - 16)
    gitgud.setProperty(image, "Area", geometry.rect(x + 8, y + 8, w, h))
end

--- Highlight the active mode button.
-- @param mode  "twoup" | "difference" | "onion"
local function styleModeButtons(mode)
    local buttons = {
        twoup = "ImageModeTwoUp",
        difference = "ImageModeDifference",
        onion = "ImageModeOnion",
    }

    for key, name in pairs(buttons) do
        local active = key == mode
        gitgud.setProperty(name, "NormalFillColour", active and C.blue or C.bg3)
        gitgud.setProperty(name, "HoverFillColour", active and "FF93A4FF" or C.bg4)
        gitgud.setProperty(name, "PushedFillColour", active and "FF6F84E6" or C.bg2)
        gitgud.setProperty(name, "NormalTextColour", active and C.bg0 or C.text)
        gitgud.setProperty(name, "HoverTextColour", active and C.bg0 or "FFFFFFFF")
        gitgud.setProperty(name, "PushedTextColour", active and C.bg0 or C.text)
    end
end

--- Lay out the panel for a mode using the last decoded images.
-- @param mode  "twoup" | "difference" | "onion"
local function applyMode(mode)
    if not info then
        return
    end

    settings.set("imageDiffMode", mode)
    styleModeButtons(mode)

    local twoUp = mode == "twoup"
    gitgud.setVisible("ImageBeforeFrame", twoUp)
    gitgud.setVisible("ImageAfterFrame", twoUp)
    gitgud.setVisible("ImageBeforeCaption", twoUp)
    gitgud.setVisible("ImageAfterCaption", twoUp)
    gitgud.setVisible("ImageSingleFrame", not twoUp)

    if twoUp then
        gitgud.setProperty("ImageBefore", "Image", "GitgudDiff/Before")
        gitgud.setProperty("ImageAfter", "Image", "GitgudDiff/After")
        gitgud.setVisible("ImageBefore", info.hasBefore)
        gitgud.setVisible("ImageAfter", info.hasAfter)
        gitgud.setVisible("ImageBeforeMissing", not info.hasBefore)
        gitgud.setVisible("ImageAfterMissing", not info.hasAfter)
        -- Both canvases share the union size, so they line up pixel for pixel.
        fitInto("ImageBefore", "ImageBeforeFrame", info.width, info.height)
        fitInto("ImageAfter", "ImageAfterFrame", info.width, info.height)
        return
    end

    local image = mode == "difference" and "GitgudDiff/Difference" or "GitgudDiff/Onion"
    gitgud.setProperty("ImageSingle", "Image", image)
    fitInto("ImageSingle", "ImageSingleFrame", info.width, info.height)
end

--- A one-line description of the change ("64 × 64 → 128 × 64 · 12% changed").
-- @return plain text
local function describe()
    local parts = {}

    if info.hasBefore and info.hasAfter then
        if info.beforeWidth ~= info.afterWidth or info.beforeHeight ~= info.afterHeight then
            parts[#parts + 1] = string.format("%d × %d  →  %d × %d",
                info.beforeWidth, info.beforeHeight, info.afterWidth, info.afterHeight)
        else
            parts[#parts + 1] = string.format("%d × %d", info.afterWidth, info.afterHeight)
        end

        local percent = info.total > 0 and (info.changed * 100 / info.total) or 0
        if info.changed == 0 then
            parts[#parts + 1] = "no visible pixel changes"
        else
            parts[#parts + 1] = string.format("%s pixels changed (%.1f%%)",
                tostring(info.changed), percent)
        end
    elseif info.hasAfter then
        parts[#parts + 1] = string.format("New image · %d × %d", info.afterWidth, info.afterHeight)
    else
        parts[#parts + 1] = string.format("Deleted image · %d × %d", info.beforeWidth, info.beforeHeight)
    end

    return table.concat(parts, "   ·   ")
end

--- Decode and show an image diff.
-- @param path       repository-relative path
-- @param beforeRev  "head", "index", "<oid>^", ...
-- @param afterRev   "workdir", "index", "<oid>", ...
-- @return true on success, or false + error message
function imagediff.show(path, beforeRev, afterRev)
    local result, err = gitgud.imageDiff(path, beforeRev, afterRev)
    if not result then
        info = nil
        return false, err
    end

    info = result
    gitgud.setVisible("ImageDiffPanel", true)
    gitgud.setText("ImageStatsLabel", text.escape(describe()))

    -- Added or deleted images have nothing to compare pixel-wise.
    local mode = settings.get("imageDiffMode", "twoup")
    if not (info.hasBefore and info.hasAfter) then
        mode = "twoup"
    end
    gitgud.setEnabled("ImageModeDifference", info.hasBefore and info.hasAfter)
    gitgud.setEnabled("ImageModeOnion", info.hasBefore and info.hasAfter)
    applyMode(mode)

    return true
end

--- Hide the panel.
function imagediff.hide()
    gitgud.setVisible("ImageDiffPanel", false)
end

--- True while the image panel is showing.
-- @return boolean
function imagediff.isVisible()
    return info ~= nil and gitgud.getProperty("ImageDiffPanel", "Visible") == "true"
end

--- Re-fit the pictures (after the window was resized).
function imagediff.relayout()
    if imagediff.isVisible() then
        applyMode(settings.get("imageDiffMode", "twoup"))
    end
end

--- Wire the mode buttons.
function imagediff.init()
    gitgud.on("ImageModeTwoUp.clicked", function()
        applyMode("twoup")
    end)

    gitgud.on("ImageModeDifference.clicked", function()
        applyMode("difference")
    end)

    gitgud.on("ImageModeOnion.clicked", function()
        applyMode("onion")
    end)
end

return imagediff
