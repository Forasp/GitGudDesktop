--- depot/util.lua — small helpers shared by the Depot views.

local text = require("core.text")

local util = {}

--- The paths of a list of { path = ... } rows.
-- @param rows  array
-- @return array of paths
function util.pathsOf(rows)
    local out = {}
    for _, row in ipairs(rows or {}) do
        out[#out + 1] = row.path
    end

    return out
end

--- Date and time: "2026/09/26 14:05:09".
-- @param timestamp  seconds since the epoch
-- @return formatted local time
function util.dateTime(timestamp)
    if not timestamp or timestamp == 0 then
        return ""
    end

    return os.date("%Y/%m/%d %H:%M:%S", timestamp)
end

--- A short date: "2026/09/26".
-- @param timestamp  seconds since the epoch
-- @return formatted local date
function util.date(timestamp)
    if not timestamp or timestamp == 0 then
        return ""
    end

    return os.date("%Y/%m/%d", timestamp)
end

--- Human-readable size: "1.2 KB".
-- @param bytes  size
-- @return text
function util.size(bytes)
    bytes = bytes or 0
    if bytes < 1024 then
        return bytes .. " B"
    end
    if bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    end

    return string.format("%.1f MB", bytes / (1024 * 1024))
end

--- A file's type column: its extension in capitals.
-- @param path  file path
-- @return "text", "binary", or the extension
function util.fileType(path)
    local ext = text.extension(path)
    local binary = {
        png = true, jpg = true, jpeg = true, gif = true, bmp = true, ico = true, psd = true,
        exe = true, dll = true, lib = true, pdb = true, zip = true, ["7z"] = true, pdf = true,
        ttf = true, otf = true, wav = true, mp3 = true, fbx = true, uasset = true, umap = true,
    }
    if binary[ext] then
        return "binary"
    end

    return "text"
end

--- The first line of a message.
-- @param message  text
-- @return summary
function util.summary(message)
    return (message or ""):match("^[^\n]*") or ""
end

--- Is `path` inside folder `dir` ("" = everywhere)?
-- @param path  file path
-- @param dir   folder path
-- @return boolean
function util.inside(path, dir)
    if dir == "" then
        return true
    end

    return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

--- Short commit id (8 hex digits, standing in for a changelist number).
-- @param oid  full id
-- @return short id
function util.change(oid)
    return (oid or ""):sub(1, 8)
end

return util
