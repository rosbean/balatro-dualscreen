-- balatro-dualscreen-thor -- make the Sort Hand buttons a usable touch target.
--
-- Play Hand and Discard are comfortable at vanilla's size. Rank and Suit are
-- not: UI_definitions.lua:1011/1014 give them minh = 0.7, minw = 0.9 with text
-- at scale*0.7, which is fine for a mouse on a 1920-wide screen and fiddly for
-- a thumb on the panel.
--
-- Scaling the whole G.buttons cluster was tried first and made Play and Discard
-- oversized. Enlarging the two sort nodes at the DEFINITION level is better in
-- every way: the UIBox lays itself out around the new size, so the drawn
-- buttons and the hit rects derived from them stay in agreement automatically,
-- with no parallel transform to keep in sync.
--
-- WRAP, DON'T REPLACE. create_UIBox_buttons is a global; we call through and
-- then adjust the tree it returns, so any upstream change to the cluster is
-- inherited.

local buttons = {}

-- Identified by callback name rather than position in the tree, so a
-- reordering upstream does not silently retarget this.
local SORT_BUTTONS = {
    sort_hand_value = true,
    sort_hand_suit  = true,
}

local MINW, MINH = 1.5, 1.1   -- from 0.9 x 0.7
local TEXT_SCALE = 1.35       -- relative bump for the Rank / Suit labels

-- Play and Discard are declared align = "tm" (top-middle) at
-- UI_definitions.lua:989/995, which puts their label against the top edge.
-- That is fine at vanilla's button height; with the cluster enlarged and
-- dropped it reads as mis-centred. "cm" centres it.
local CENTRE_BUTTONS = {
    play_cards_from_highlighted = true,
    discard_cards_from_highlighted = true,
}

local function enlarge(node)
    if type(node) ~= "table" then return end

    local cfg = node.config
    if cfg and cfg.button and CENTRE_BUTTONS[cfg.button] then
        cfg.align = "cm"
    end
    if cfg and cfg.button and SORT_BUTTONS[cfg.button] then
        cfg.minw = MINW
        cfg.minh = MINH
        -- Bump the label inside it too, or a bigger button gets tiny text.
        for _, child in ipairs(node.nodes or {}) do
            if child.config and child.config.scale then
                child.config.scale = child.config.scale * TEXT_SCALE
            end
        end
        return
    end

    for _, child in ipairs(node.nodes or {}) do
        enlarge(child)
    end
end

function buttons.install()
    if type(create_UIBox_buttons) ~= "function" then
        DS.log("buttons: create_UIBox_buttons unavailable")
        return
    end

    local orig = create_UIBox_buttons
    function create_UIBox_buttons(...)
        local def = orig(...)
        -- Only when the second screen is actually in use: on a single-screen
        -- device the cluster should look exactly like vanilla.
        if DS.active then
            pcall(enlarge, def)
        end
        return def
    end

    DS.log("buttons: sort-button enlargement installed")
end

return buttons
