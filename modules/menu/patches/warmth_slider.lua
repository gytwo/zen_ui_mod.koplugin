-- Warmth (natural light) slider section for the Quick Settings panel.
-- Returns a populated VerticalGroup and registers slider/toggle refs.
-- The caller is responsible for checking Device:hasNaturalLight() before calling.
--
-- Usage:
--   local build_warmth_slider = require("modules/menu/patches/warmth_slider")
--   if config.show_warmth and Device:hasNaturalLight() then
--       warmth_group = build_warmth_slider(touch_menu, { ... })
--   end

local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local ZenSlider       = require("common/zen_slider")
local ZenToggle       = require("common/zen_toggle")
local _               = require("gettext")
local Screen          = Device.screen

local function build_warmth_slider(touch_menu, opts)
    local inner_width     = opts.inner_width
    local slider_width    = opts.slider_width
    local small_btn_width = opts.small_btn_width
    local toggle_width    = opts.toggle_width
    local slider_gap      = opts.slider_gap
    local medium_font     = opts.medium_font
    local small_btn_font  = opts.small_btn_font
    local powerd          = opts.powerd
    local refs            = opts.refs
    local show_parent     = touch_menu.show_parent

    local nl = {
        min = powerd.fl_warmth_min,
        max = powerd.fl_warmth_max,
        cur = powerd:toNativeWarmth(powerd:frontlightWarmth()),
    }

    local nl_label = TextWidget:new{
        text      = _("Warmth") .. ": " .. tostring(nl.cur),
        face      = medium_font,
        max_width = inner_width,
    }

    local nl_progress = ZenSlider:new{
        width     = slider_width,
        value     = nl.cur,
        value_min = nl.min,
        value_max = nl.max,
        show_parent = show_parent,
    }

    local nl_label_fn = nil

    local function setWarmth(warmth)
        if warmth == nl.cur then return end
        warmth = math.max(nl.min, math.min(nl.max, warmth))
        powerd:setWarmth(powerd:fromNativeWarmth(warmth))
        nl.cur = warmth
        if nl.cur > nl.min then nl.prev_non_min = nl.cur end
        if nl_label_fn then UIManager:unschedule(nl_label_fn) ; nl_label_fn = nil end
        nl_progress:setValue(nl.cur)
        nl_label:setText(_("Warmth") .. ": " .. tostring(nl.cur))
        UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
    end

    nl.prev_non_min = nl.cur > nl.min and nl.cur or math.min(nl.max, nl.min + 1)

    -- Wire slider: hardware updates every pan frame; label debounces 100ms
    nl_progress.on_change = function(v)
        powerd:setWarmth(powerd:fromNativeWarmth(v))
        nl.cur = v
        if nl.cur > nl.min then nl.prev_non_min = nl.cur end
        UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
        if nl_label_fn then UIManager:unschedule(nl_label_fn) end
        nl_label_fn = function()
            nl_label_fn = nil
            nl_label:setText(_("Warmth") .. ": " .. tostring(nl.cur))
            UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
        end
        UIManager:scheduleIn(0.1, nl_label_fn)
    end

    local nl_minus = Button:new{
        text        = "−",
        face        = small_btn_font,
        width       = small_btn_width,
        bordersize  = 0,
        show_parent = show_parent,
        callback    = function() setWarmth(nl.cur - 1) end,
    }
    local nl_plus = Button:new{
        text        = "＋",
        face        = small_btn_font,
        width       = small_btn_width,
        bordersize  = 0,
        show_parent = show_parent,
        callback    = function() setWarmth(nl.cur + 1) end,
    }

    local nl_toggle = ZenToggle:new{
        width      = toggle_width,
        value_func = function() return nl.cur > nl.min end,
    }
    table.insert(refs.toggles, {
        toggle   = nl_toggle,
        callback = function()
            if nl.cur > nl.min then
                nl.prev_non_min = nl.cur
                setWarmth(nl.min)
            else
                setWarmth(nl.prev_non_min or math.min(nl.max, nl.min + 1))
            end
        end,
    })

    local row_gap     = VerticalSpan:new{ width = Screen:scaleBySize(10) }
    local label_width = inner_width - 2 * toggle_width

    local nl_cap_row = HorizontalGroup:new{
        align = "center",
        nl_toggle,
        CenterContainer:new{
            dimen = Geom:new{ w = label_width, h = nl_toggle:getSize().h },
            nl_label,
        },
        HorizontalSpan:new{ width = toggle_width },
    }
    local nl_row = HorizontalGroup:new{
        align = "center",
        nl_minus,
        HorizontalSpan:new{ width = slider_gap },
        nl_progress,
        HorizontalSpan:new{ width = slider_gap },
        nl_plus,
    }

    refs.nl_progress = nl_progress
    refs.nl_state    = nl
    refs.setWarmth   = setWarmth
    table.insert(refs.sliders, { slider = nl_progress })

    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(14) })
    table.insert(group, nl_cap_row)
    table.insert(group, row_gap)
    table.insert(group, nl_row)
    return group
end

return build_warmth_slider
