-- balatro-dualscreen-thor -- a "Dual Screen" tab in Options > Settings.
--
-- Replaces the double-tap-to-hide gesture ported from BanjoRecomp. Double-tap
-- worked, but on a panel you rest your hands on it fires by accident, and
-- accidentally losing the hand mid-round is a bad failure. A settings toggle is
-- deliberate, discoverable, and gives later options somewhere to live.
--
-- WRAP, DON'T REPLACE. create_UIBox_settings and G.UIDEF.settings_tab are both
-- globals: the wrapper calls through and appends, so any tab LocalThunk adds
-- later still appears.
--
-- The flag lives in G.SETTINGS so Balatro's own save_settings persists it --
-- no separate settings file, and it survives a restart for free.

local settings = {}

local DEFAULT = true

function settings.enabled()
    if not G or not G.SETTINGS then return DEFAULT end
    if G.SETTINGS.dualscreen_enabled == nil then
        G.SETTINGS.dualscreen_enabled = DEFAULT
    end
    -- Everything defaults ON (decided for the 1.0 release): a fresh install
    -- should show the mod at its best, and every toggle is one tap from off.
    -- Seeds only fill in nil, so nobody's saved choices are overwritten by
    -- an update -- only genuinely new installs (and new settings) see these.
    if G.SETTINGS.dualscreen_hand_score == nil then
        G.SETTINGS.dualscreen_hand_score = true
    end
    if G.SETTINGS.dualscreen_consumables == nil then
        G.SETTINGS.dualscreen_consumables = true
    end
    if G.SETTINGS.dualscreen_larger_jokers == nil then
        G.SETTINGS.dualscreen_larger_jokers = true
    end
    if G.SETTINGS.dualscreen_crt == nil then
        G.SETTINGS.dualscreen_crt = true
    end
    if G.SETTINGS.dualscreen_rgb_leds == nil then
        G.SETTINGS.dualscreen_rgb_leds = true
    end
    -- Default TRUE: this is a battery-powered handheld, and 60 fps halves
    -- CPU/GPU work (measured ~119 fps free-running in a run). The 120 fps
    -- crowd is one tap away.
    if G.SETTINGS.dualscreen_fps60 == nil then
        G.SETTINGS.dualscreen_fps60 = true
    end
    return G.SETTINGS.dualscreen_enabled and true or false
end

--- Is the hand score meant to be on screen 2? Only meaningful when the whole
--- dual-screen mode is on, so it is gated on that rather than checked twice.
function settings.hand_score()
    return settings.enabled()
       and G.SETTINGS and G.SETTINGS.dualscreen_hand_score and true or false
end

--- Likewise for the consumables row.
function settings.consumables()
    return settings.enabled()
       and G.SETTINGS and G.SETTINGS.dualscreen_consumables and true or false
end

--- Grow the joker row to the full width of the top screen. Independent of
--- where the consumables live -- the row size and the consumables' screen are
--- two separate choices, and layout.reconcile combines them.
function settings.larger_jokers()
    return settings.enabled()
       and G.SETTINGS and G.SETTINGS.dualscreen_larger_jokers and true or false
end

--- Apply the top screen's CRT effect to the panel as well.
function settings.crt2()
    return settings.enabled()
       and G.SETTINGS and G.SETTINGS.dualscreen_crt and true or false
end

--- Cap the game at 60 fps (off = 120). Independent of the master toggle:
--- like the LEDs, it is about the device, not the second screen.
function settings.fps60()
    return not (G.SETTINGS and G.SETTINGS.dualscreen_fps60 == false)
end

--- Drive the joystick RGB LEDs from the game background. DELIBERATELY not
--- gated on enabled(): the LEDs have nothing to do with the second screen and
--- the feature is useful either way.
function settings.rgb_leds()
    return G.SETTINGS and G.SETTINGS.dualscreen_rgb_leds and true or false
end

--- Called by the toggle. Persists immediately so the choice survives a crash
--- as well as a clean exit.
-- The master toggle's last-seen value, so on_change can tell a master
-- transition apart from a sub-toggle change. Seeded on install.
local last_master = nil

--- Rebuild the Dual Screen tab's contents in place, exactly as
--- G.FUNCS.change_tab does when a tab button is pressed
--- (button_callbacks.lua:1299): replace the tab_contents object with a fresh
--- box built from the definition, and recalculate.
---
--- Run through an E_MANAGER event rather than inline: the toggle that
--- triggered this lives INSIDE the box being replaced, and its click handler
--- has not finished executing yet -- vanilla only ever runs this pattern from
--- tab buttons, which live outside the contents.
local function queue_tab_rebuild()
    if not G or not G.E_MANAGER or not G.OVERLAY_MENU then return end
    G.E_MANAGER:add_event(Event({
        trigger = "immediate",
        blockable = false,
        func = function()
            local ok = pcall(function()
                if not G.OVERLAY_MENU then return end
                local tc = G.OVERLAY_MENU:get_UIE_by_ID("tab_contents")
                if not tc or not tc.config or not tc.config.object then return end
                tc.config.object:remove()
                tc.config.object = UIBox{
                    definition = G.UIDEF.settings_tab("DualScreen"),
                    config = { offset = { x = 0, y = 0 }, parent = tc, type = "cm" },
                }
                tc.UIBox:recalculate()
            end)
            if not ok then DS.log("settings: tab rebuild failed") end
            return true
        end,
    }))
end

function settings.on_change()
    -- Master transitions carry the sub-toggles with them: turning the second
    -- screen OFF stashes their values and clears them (so everything reads
    -- off, honestly); turning it back ON restores what the player had. The
    -- stash lives in G.SETTINGS, so it survives restarts via the game's own
    -- settings save.
    local master = G.SETTINGS.dualscreen_enabled and true or false
    if last_master ~= nil and master ~= last_master then
        if not master then
            G.SETTINGS.dualscreen_stash = {
                score  = G.SETTINGS.dualscreen_hand_score and true or false,
                cons   = G.SETTINGS.dualscreen_consumables and true or false,
                jokers = G.SETTINGS.dualscreen_larger_jokers and true or false,
                crt    = G.SETTINGS.dualscreen_crt and true or false,
            }
            G.SETTINGS.dualscreen_hand_score    = false
            G.SETTINGS.dualscreen_consumables   = false
            G.SETTINGS.dualscreen_larger_jokers = false
            G.SETTINGS.dualscreen_crt           = false
        else
            local st = G.SETTINGS.dualscreen_stash
            if st then
                G.SETTINGS.dualscreen_hand_score    = st.score and true or false
                G.SETTINGS.dualscreen_consumables   = st.cons and true or false
                G.SETTINGS.dualscreen_larger_jokers = st.jokers and true or false
                G.SETTINGS.dualscreen_crt           = st.crt and true or false
            end
            G.SETTINGS.dualscreen_stash = nil
        end
        -- The tab shows the sub-toggles only while the master is on, so its
        -- contents have to be rebuilt for the change to be visible.
        queue_tab_rebuild()
    end
    last_master = master

    -- Persist through the game's own save. (This call was once dropped in a
    -- rewrite and all three toggles silently stopped saving -- it stays.)
    DS.log("settings: enabled=" .. tostring(settings.enabled())
           .. " score=" .. tostring(settings.hand_score())
           .. " cons=" .. tostring(settings.consumables())
           .. " jokers=" .. tostring(settings.larger_jokers())
           .. " crt2=" .. tostring(settings.crt2())
           .. " rgb=" .. tostring(settings.rgb_leds()))
    if G and G.save_settings then
        pcall(G.save_settings, G)
    end

    -- Nothing else to do. The hand score and the top-screen layout are
    -- converged by per-tick reconcilers (hud.reconcile, layout.reconcile),
    -- so every toggle applies on the next frame -- including mid-run.
end


-- The badge IMAGE is cached for the session; the Sprite wrapping it is not
-- (see the tab builder). false = tried and failed, so a missing file costs
-- one attempt rather than one per tab open.
local kofi_image = nil

function settings.kofi_badge()
    if kofi_image == nil then
        local ok, img = pcall(love.graphics.newImage,
                              "dualscreen/support_me_on_kofi_dark.png")
        kofi_image = (ok and img) or false
    end
    if not kofi_image then return nil end
    local ok, sprite = pcall(function()
        local w = 3.0
        local h = w * kofi_image:getHeight() / kofi_image:getWidth()
        return Sprite(0, 0, w, h, {
            image = kofi_image,
            px = kofi_image:getWidth(),
            py = kofi_image:getHeight(),
        }, { x = 0, y = 0 })
    end)
    if not ok then
        DS.log("kofi badge sprite failed: " .. tostring(sprite))
        return nil
    end
    return sprite
end

function settings.install()
    if type(create_tabs) ~= "function"
       or not G or not G.UIDEF or type(G.UIDEF.settings_tab) ~= "function" then
        DS.log("settings: hooks unavailable, tab not installed")
        return
    end

    -- Seed the flag so the toggle has something to bind to.
    settings.enabled()
    last_master = G.SETTINGS.dualscreen_enabled and true or false

    -- Append our tab by wrapping create_tabs rather than create_UIBox_settings.
    -- The settings box builds its list inline and passes it straight to
    -- create_tabs, so intercepting there means we never reproduce LocalThunk's
    -- list -- any tab added upstream still appears, in its original order,
    -- with ours after it.
    --
    -- A settings tab list is identified by its entries pointing at
    -- G.UIDEF.settings_tab. That is our own wrapper by this point, which is
    -- exactly what makes the comparison work: create_UIBox_settings reads the
    -- field at call time.
    -- The Ko-fi button's callback. pcall'd: openURL can be refused by the
    -- OS, and a settings button must never take the game down.
    G.FUNCS.dualscreen_kofi = function()
        pcall(love.system.openURL, "https://ko-fi.com/rosbean")
    end

    local orig_create_tabs = create_tabs
    function create_tabs(args)
        if args and type(args.tabs) == "table" then
            local is_settings, already = false, false
            for _, t in ipairs(args.tabs) do
                if t.tab_definition_function == G.UIDEF.settings_tab then
                    is_settings = true
                end
                if t.tab_definition_function_args == "DualScreen" then
                    already = true
                end
            end
            if is_settings and not already then
                args.tabs[#args.tabs + 1] = {
                    label = "Dual Screen",
                    tab_definition_function = G.UIDEF.settings_tab,
                    tab_definition_function_args = "DualScreen",
                }
            end
        end
        return orig_create_tabs(args)
    end

    local orig_settings_tab = G.UIDEF.settings_tab
    G.UIDEF.settings_tab = function(tab)
        if tab == "DualScreen" then
            -- The sub-toggles appear only while the master is on: with the
            -- second screen disabled they are all forced off (and stashed for
            -- restore), and dead toggles would only mislead.
            local nodes = {
                create_toggle({
                    label = "Use second screen",
                    ref_table = G.SETTINGS,
                    ref_value = "dualscreen_enabled",
                    callback = settings.on_change,
                }),
            }
            if G.SETTINGS.dualscreen_enabled then
                nodes[#nodes + 1] = create_toggle({
                    label = "Hand score on second screen",
                    ref_table = G.SETTINGS,
                    ref_value = "dualscreen_hand_score",
                    callback = settings.on_change,
                })
                nodes[#nodes + 1] = create_toggle({
                    label = "Consumables on second screen",
                    ref_table = G.SETTINGS,
                    ref_value = "dualscreen_consumables",
                    callback = settings.on_change,
                })
                nodes[#nodes + 1] = create_toggle({
                    label = "Larger joker area",
                    ref_table = G.SETTINGS,
                    ref_value = "dualscreen_larger_jokers",
                    callback = settings.on_change,
                })
                nodes[#nodes + 1] = create_toggle({
                    label = "Enable CRT effect on 2nd screen",
                    ref_table = G.SETTINGS,
                    ref_value = "dualscreen_crt",
                    callback = settings.on_change,
                })
            end
            -- Independent of the master toggle: the LEDs are hardware on the
            -- device itself, not a second-screen feature. Visible always,
            -- never stashed.
            nodes[#nodes + 1] = create_toggle({
                label = "AYN Thor: Enable RGB effects.",
                ref_table = G.SETTINGS,
                ref_value = "dualscreen_rgb_leds",
                callback = settings.on_change,
            })
            nodes[#nodes + 1] = create_toggle({
                label = "Limit to 60 FPS (saves battery)",
                ref_table = G.SETTINGS,
                ref_value = "dualscreen_fps60",
                callback = settings.on_change,
            })
            -- Credit and a Ko-fi link. The button goes through
            -- love.system.openURL, which Android routes to the default
            -- browser; G.FUNCS.dualscreen_kofi is defined in install().
            nodes[#nodes + 1] = {
                n = G.UIT.R,
                config = { align = "cm", padding = 0.06 },
                nodes = {
                    { n = G.UIT.T, config = {
                        text = "Balatro Dual Screen mod by Rosbean.",
                        scale = 0.3, colour = G.C.UI.TEXT_LIGHT, shadow = true,
                    } },
                },
            }
            nodes[#nodes + 1] = {
                n = G.UIT.R,
                config = { align = "cm" },
                nodes = {
                    { n = G.UIT.T, config = {
                        text = "If you want to say thank you, feel free to support me on Ko-Fi!",
                        scale = 0.3, colour = G.C.UI.TEXT_LIGHT, shadow = true,
                    } },
                },
            }
            -- The real Ko-fi badge when its image is available (shipped at
            -- dualscreen/support_me_on_kofi_dark.png), a styled pill when not.
            -- A Sprite accepts any {image, px, py} table as its atlas, and a
            -- single-image "atlas" with cell (0,0) is just the image -- no
            -- game asset involved. Built fresh per tab open: removing the tab
            -- destroys the object node's Sprite with it.
            local badge = settings.kofi_badge()
            if badge then
                nodes[#nodes + 1] = {
                    n = G.UIT.R,
                    config = { align = "cm", padding = 0.08 },
                    nodes = {
                        { n = G.UIT.R, config = {
                            align = "cm", padding = 0.03, r = 0.1,
                            colour = G.C.CLEAR,
                            button = "dualscreen_kofi",
                            hover = true,
                        }, nodes = {
                            { n = G.UIT.O, config = { object = badge } },
                        } },
                    },
                }
            else
                nodes[#nodes + 1] = {
                    n = G.UIT.R,
                    config = { align = "cm", padding = 0.08 },
                    nodes = {
                        { n = G.UIT.R, config = {
                            align = "cm", padding = 0.12, r = 0.1,
                            minw = 3.4, minh = 0.7,
                            -- The Ko-fi badge's near-black pill.
                            colour = { 0.09, 0.09, 0.11, 1 },
                            button = "dualscreen_kofi",
                            hover = true, shadow = true,
                        }, nodes = {
                            { n = G.UIT.T, config = {
                                text = "Support me on Ko-fi",
                                scale = 0.4, colour = G.C.WHITE, shadow = true,
                            } },
                        } },
                    },
                }
            end
            return {
                n = G.UIT.ROOT,
                config = { align = "cm", padding = 0.05, colour = G.C.CLEAR },
                nodes = nodes,
            }
        end
        return orig_settings_tab(tab)
    end

    DS.log("settings: Dual Screen tab installed")
end

return settings
