--- core/sprites.lua: the small pictures drawn inside list rows (the include
-- boxes in Changes and the diff, the branch tree's icons).
--
-- The GitGud UI's come from its atlas (imagesets/Gitgud.xml) with their
-- colours baked in. A UI package can shadow this file with its own
-- scripts/core/sprites.lua to draw them another way (the Bragi UI tints
-- white pictures with its theme).
--
--   sprites.image(name, w, h)   inline markup for one picture

local sprites = {}

--- Inline markup for a picture at a size.
-- @param name  image in Gitgud-Images: HunkOn / HunkOff / HunkPart,
--              BlockOn / BlockOff / BlockPart, NavBranch, NavRemote, NavTag,
--              NavStash, NavSubmodule, NavWorktree, NavOpen, NavClosed
-- @param w     width in pixels
-- @param h     height in pixels
-- @return markup
function sprites.image(name, w, h)
    return "[image-size='w:" .. w .. " h:" .. h .. "'][image='Gitgud-Images/" .. name .. "']"
end

return sprites
