--- ui/placeholder.lua — grey hint text inside empty editboxes.
--
-- CEGUI editboxes have no placeholder support, so each layout places a
-- click-through label over the empty editbox; this module shows it only
-- while the editbox is empty.
--
--     placeholder.bind("SummaryEdit", "SummaryPlaceholder")
--     placeholder.setText("SummaryEdit", "")   -- set text AND sync the hint

local placeholder = {}

local labels = {}   -- editbox name -> placeholder label name

--- Show or hide an editbox's placeholder for the given text.
-- @param edit   editbox name
-- @param value  its current text
local function sync(edit, value)
    local label = labels[edit]
    if label then
        gitgud.setVisible(label, value == "")
    end
end

--- Pair an editbox with its placeholder label.
-- @param edit   editbox name
-- @param label  placeholder label name
function placeholder.bind(edit, label)
    labels[edit] = label

    gitgud.on(edit .. ".changed", function(value)
        sync(edit, value)
    end)

    sync(edit, gitgud.getText(edit))
end

--- Set an editbox's text from code (widget events don't fire for that) and
-- keep its placeholder in step.
-- @param edit   editbox name
-- @param value  new text
function placeholder.setText(edit, value)
    gitgud.setText(edit, value)
    sync(edit, value)
end

return placeholder
