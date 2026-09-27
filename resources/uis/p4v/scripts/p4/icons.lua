--- p4/icons.lua — inline icon markup and file-status icons.
--
-- The P4V UI's icons are the colour atlas imagesets/P4Icons.png (imageset
-- "P4-Icons", drawn by imagesets/make-icons.ps1). In list rows they're
-- inline CEGUI markup; on widgets they're the "Image" property.
--
--     icons.inline("Folder")          -- 16px icon markup for a row
--     icons.image("Refresh")          -- "P4-Icons/Refresh" for a property
--     icons.forStatus(fileRow)        -- the icon name for a status() row

local icons = {}

--- The image name of an icon.
-- @param name  icon name (see make-icons.ps1)
-- @return "P4-Icons/<name>"
function icons.image(name)
    return "P4-Icons/" .. name
end

--- Inline markup showing an icon, vertically centred in the row.
-- @param name  icon name
-- @param size  pixels (default 16)
-- @return markup
function icons.inline(name, size)
    size = size or 16
    return "[vert-formatting='CentreAligned'][image-size='w:" .. size .. " h:" .. size
        .. "'][image='P4-Icons/" .. name .. "']"
end

--- Horizontal space inside a row (indentation, gaps).
-- @param width  pixels
-- @return markup
function icons.space(width)
    if width <= 0 then
        return ""
    end

    return "[image-size='w:" .. width .. " h:1'][image='P4-Icons/Spacer']"
end

--- A small down-arrow for buttons that open a menu (fonts lack a
-- reliable glyph for it).
-- @return markup
function icons.dropdown()
    return " " .. icons.inline("TreeOpen", 14)
end

--- The icon for a working-tree file, P4V style: edited, added, deleted,
-- untracked, conflicted, or unchanged.
-- @param code  a gitgud.status() code (A M D ? U R), or nil for unchanged
-- @return icon name
function icons.forStatus(code)
    if code == "M" or code == "T" then
        return "FileEdit"
    end
    if code == "A" then
        return "FileAdd"
    end
    if code == "D" then
        return "FileDelete"
    end
    if code == "?" then
        return "FileUntracked"
    end
    if code == "U" then
        return "FileConflict"
    end
    if code == "R" then
        return "FileMoved"
    end

    return "File"
end

--- P4V's word for a file's pending action.
-- @param code  status code
-- @return "edit", "add", "delete", "move/add", "unresolved", "untracked"
function icons.actionName(code)
    local names = {
        M = "edit",
        T = "edit",
        A = "add",
        D = "delete",
        R = "move/add",
        U = "unresolved",
        ["?"] = "untracked",
    }

    return names[code] or "edit"
end

return icons
