-- balatro-dualscreen-thor -- stack the main menu buttons vertically.
--
-- Vanilla lays PLAY / OPTIONS / QUIT / COLLECTION out as a horizontal strip.
-- That reads fine across a wide desktop window and badly on the companion
-- panel, which is close to square and where each button ends up narrow.
--
-- WHY IT IS HORIZONTAL, which turned out to be a one-word answer. UIBox_button
-- picks its own node type from an argument:
--
--     local but_UIT = args.col == true and G.UIT.C or G.UIT.R
--                                       (UI_definitions.lua:6391)
--
-- and every main-menu button is built with `col = true`. The engine then gives
-- C children a common HEIGHT and R children a common WIDTH
-- (engine/ui.lua:569-570), so C children sit side by side and R children stack.
-- Retyping the wrappers from C to R therefore both stacks the buttons AND
-- makes them equal width, which is exactly the wide vertical stack wanted.
--
-- WRAP, DO NOT REPLACE. This calls vanilla's own definition and edits the tree
-- it returns; it does not restate the menu. New buttons, renamed labels or
-- layout changes upstream are inherited, and anything this cannot find is left
-- alone rather than dropped.

local menu = {}

-- The buttons to stack, in the order they should appear. `start_run` and
-- `setup_run` are the same slot: which one PLAY carries depends on whether the
-- tutorial has been completed (UI_definitions.lua:6216).
local ORDER = { "setup_run", "start_run", "options", "quit", "your_collection" }

local WANTED = {}
for _, name in ipairs(ORDER) do WANTED[name] = true end

-- Big. This is the primary UI of the panel with nothing competing for space,
-- so the buttons are sized to be read and hit at arm's length rather than to
-- match the desktop strip they came from.
local BUTTON_W = 11.0
local BUTTON_H = 2.0
local LABEL_SCALE = 2.2      -- multiplier on vanilla's own text scale

-- Margin from the room edge, in TILES, chosen to land on 20 px of panel.
--
-- The menu section supplies no region, so the panel shows the whole room:
-- background_region fits the room's 20-tile width to 1240 px, giving 62 px per
-- tile (36.3 px/tile at TILESCALE, times the 1.708 fit). 20 / 62 = 0.32.
--
-- Stated in tiles rather than pixels because that is the space the layout is
-- expressed in, and a pixel constant here would be a Thor-specific number --
-- the kind check_guards.py exists to keep out.
local ROOM_MARGIN = 0.32

-- Inset from the panel edge, in pixels, matching sections.lua's MENU_EDGE_PX.
local EDGE_PX = 20

--- Depth-first walk yielding (node, parent, index_in_parent).
local function walk(node, parent, index, fn)
    if type(node) ~= "table" then return end
    fn(node, parent, index)
    if node.nodes then
        for i, child in ipairs(node.nodes) do
            walk(child, node, i, fn)
        end
    end
end

--- Rebuild the button cluster as a vertical stack.
--- Returns true if it changed anything.
local function stack_buttons(t)
    -- inner[name] = the node carrying config.button
    -- wrapper[name] = its parent, whose `n` decides row-vs-column
    -- holder = the node that contains the PLAY wrapper; its nodes get replaced
    local inner, wrapper = {}, {}
    local holder = nil

    walk(t, nil, nil, function(node, parent)
        local b = node.config and node.config.button
        if b and WANTED[b] and parent then
            inner[b] = node
            wrapper[b] = parent
        end
    end)

    -- The holder is whichever node directly contains a wrapper. Found by a
    -- second pass so it does not depend on the shape of vanilla's nesting.
    local play_wrapper = wrapper["setup_run"] or wrapper["start_run"]
    if not play_wrapper then
        return false
    end
    walk(t, nil, nil, function(node)
        if node.nodes then
            for _, child in ipairs(node.nodes) do
                if child == play_wrapper then holder = node end
            end
        end
    end)
    if not holder then
        return false
    end

    local rows = {}
    for _, name in ipairs(ORDER) do
        local w, i = wrapper[name], inner[name]
        if w and i then
            -- C -> R: stacks it, and gives it the common width of the column.
            w.n = G.UIT.R
            i.config.minw = BUTTON_W
            i.config.maxw = BUTTON_W
            i.config.minh = BUTTON_H
            -- Scale the label with the button. Vanilla sets its own per-button
            -- text scale (PLAY is larger than OPTIONS); multiplying preserves
            -- that relationship instead of flattening it.
            walk(w, nil, nil, function(node)
                if node.n == G.UIT.T and node.config and node.config.scale then
                    node.config.scale = node.config.scale * LABEL_SCALE
                end
            end)
            rows[#rows + 1] = w
        end
    end

    if #rows == 0 then
        return false
    end

    -- Replacing rather than reordering drops vanilla's spacer nodes and the
    -- column that held OPTIONS and QUIT side by side. Anything not recognised
    -- above is left where it was, in its own part of the tree.
    holder.nodes = rows

    -- SIZE THE ROOT SO ITS CORNERS LAND WHERE WE WANT THEM.
    --
    -- Done on the DEFINITION, which is the only place that works: setting
    -- UIRoot.config after the box exists and calling recalculate does not take,
    -- and nudging a laid-out element by its role offset moves the element's own
    -- background while its children stay behind.
    --
    -- The box is aligned 'bmi' against G.ROOM_ATTACH (common_events.lua:756) --
    -- horizontally centred, bottom-aligned -- and sections.lua offsets it so
    -- its bottom lands EDGE px above the panel floor. So:
    --
    --   width  = 2 * (right_inset_x - room_centre)   right edge on the inset
    --   height = 2 * (bottom - panel_centre)         contents centred on screen
    --
    -- The room is letterboxed into the panel, so those anchors are asked for in
    -- panel pixels and converted; a fixed tile margin gives a different pixel
    -- inset on each edge. DS.panel_tile is unavailable on the very first menu,
    -- before the companion has published its size, and the room-based fallback
    -- is used then.
    local room_w = (G.ROOM and G.ROOM.T and G.ROOM.T.w) or 20
    local room_h = (G.ROOM and G.ROOM.T and G.ROOM.T.h) or 11.5

    local right_x, bottom_y, centre_y
    if DS.panel_tile and (DS.panel_w or 0) > 0 and (DS.panel_h or 0) > 0 then
        right_x  = select(1, DS.panel_tile(DS.panel_w - EDGE_PX, 0))
        _, bottom_y = DS.panel_tile(0, DS.panel_h - EDGE_PX)
        _, centre_y = DS.panel_tile(0, DS.panel_h / 2)
    end
    if not right_x or not bottom_y or not centre_y then
        right_x  = room_w - ROOM_MARGIN
        bottom_y = room_h - ROOM_MARGIN
        centre_y = room_h / 2
    end

    local root_w = 2 * (right_x - room_w / 2)
    local root_h = 2 * (bottom_y - centre_y)

    t.config = t.config or {}
    t.config.minw = root_w
    t.config.minh = root_h

    -- Find the language column -- vanilla aligns it 'br' -- and give it the
    -- full height, so 'bottom right of its cell' means the bottom right of the
    -- whole box rather than the bottom of a cell only as tall as its contents.
    local lang_col, lang_w = nil, 3.2
    for _, child in ipairs(t.nodes or {}) do
        if child and child.config and child.config.align == "br" then
            lang_col = child
            lang_w = child.config.minw or lang_w
        end
    end
    if lang_col then
        lang_col.config.minh = root_h
    end

    -- ROOT children sit side by side, so the columns have to ADD UP to the
    -- root width or the language column simply stops where its contents end --
    -- which is what left it 74 px short of the edge. A spacer of equal width on
    -- the left keeps the button stack centred.
    local button_col = nil
    for _, child in ipairs(t.nodes or {}) do
        if child and child.config and child.nodes and #child.nodes > 0
           and child ~= lang_col then
            button_col = child
        end
    end
    if button_col then
        button_col.config.align = "cm"
        button_col.config.minh = root_h
        button_col.config.minw = math.max(root_w - 2 * lang_w, BUTTON_W)
    end
    if lang_col then
        table.insert(t.nodes, 1, {
            n = G.UIT.C,
            config = { align = "bm", minw = lang_w, minh = root_h },
            nodes = {},
        })
    end

    return true
end

function menu.install()
    if type(create_UIBox_main_menu_buttons) ~= "function" then
        DS.log("menu: create_UIBox_main_menu_buttons missing; not stacking")
        return
    end

    local orig = create_UIBox_main_menu_buttons

    function create_UIBox_main_menu_buttons(...)
        local t = orig(...)

        -- Gated on the SETTING rather than on DS.active. The menu is built
        -- before the companion display is known, so DS.active is still
        -- false at that moment and the stack would never be applied on the
        -- first menu. The setting is loaded with the profile and is the
        -- player's stated intent either way.
        --
        -- Consequence worth knowing: toggling Dual Screen does not restyle a
        -- menu that is already on screen. It takes effect next time the menu is
        -- built.
        local want = DS.settings and DS.settings.enabled()
        if not want then
            return t
        end

        local ok, changed = pcall(stack_buttons, t)
        if not ok then
            DS.log("menu: stacking failed: " .. tostring(changed))
        elseif not changed then
            DS.log("menu: no buttons matched; left as vanilla")
        end
        return t
    end

    DS.log("menu: main-menu buttons will stack vertically")
end

return menu
