-- Brightness (frontlight) slider section for the Quick Settings panel.
-- Returns a populated VerticalGroup and registers slider/toggle refs.
--
-- Usage:
--   local build_brightness_slider = require("modules/menu/patches/brightness_slider")
--   local group = build_brightness_slider(touch_menu, {
--       inner_width, slider_width, small_btn_width, toggle_width, slider_gap,
--       medium_font, small_btn_font, powerd, refs,
--   })

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
local _               = require("gettext")
local Screen          = Device.screen

local function build_brightness_slider(touch_menu, opts)
    local inner_width     = opts.inner_width
    local slider_width    = opts.slider_width
    local small_btn_width = opts.small_btn_width
    local toggle_width    = opts.toggle_width
    local slider_gap      = opts.slider_gap
    local medium_font     = opts.medium_font
    local small_btn_size  = opts.small_btn_size
    local powerd          = opts.powerd
    local refs            = opts.refs
    local show_parent     = touch_menu.show_parent

    local fl = {
        min = powerd.fl_min,
        max = powerd.fl_max,
        cur = powerd:frontlightIntensity(),
    }

    local fl_label = TextWidget:new{
        text      = _("Brightness") .. ": " .. tostring(fl.cur),
        face      = medium_font,
        max_width = inner_width,
    }

    local fl_progress = ZenSlider:new{
        width     = slider_width,
        value     = fl.cur,
        value_min = fl.min,
        value_max = fl.max,
        show_parent = show_parent,
    }

    local fl_minus = Button:new{
        text           = "−",
        text_font_face = "infofont",
        text_font_size = small_btn_size,
        text_font_bold = false,
        width          = small_btn_width,
        bordersize     = 0,
        show_parent    = show_parent,
        callback       = function() end, -- placeholder, wired below
    }

    local fl_label_fn = nil

    local function setBrightness(intensity)
        if intensity ~= fl.min and intensity == fl.cur then return end
        intensity = math.max(fl.min, math.min(fl.max, intensity))
        powerd:setIntensity(intensity)
        fl.cur = intensity
        if fl.cur > fl.min then fl.prev_non_min = fl.cur end
        if fl_label_fn then UIManager:unschedule(fl_label_fn) ; fl_label_fn = nil end
        fl_progress:setValue(fl.cur)
        fl_label:setText(_("Brightness") .. ": " .. tostring(fl.cur))
        UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
    end

    fl.prev_non_min = fl.cur > fl.min and fl.cur or math.min(fl.max, fl.min + 1)

    -- During drag: paint directly to Screen.bb and push A2 refresh via
    -- setDirty(nil) — bypasses the widget tree entirely, so no competing
    -- GL16 from other widgets can cause flicker.  A2 completes in ~60ms
    -- and renders the pure B/W slider content without ghosting.
    -- On release / tap: full menu GL16 refresh to update label + slider.
    fl_progress.on_change = function(v)
        powerd:setIntensity(v)
        fl.cur = v
        if fl.cur > fl.min then fl.prev_non_min = fl.cur end
        if fl_progress._dragging then
            fl_progress:paintTo(Screen.bb, fl_progress.dimen.x, fl_progress.dimen.y)
            UIManager:setDirty(nil, "fast", fl_progress.dimen)
        else
            if fl_label_fn then UIManager:unschedule(fl_label_fn) ; fl_label_fn = nil end
            fl_label:setText(_("Brightness") .. ": " .. tostring(fl.cur))
            UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
        end
    end

    fl_minus.callback = function() setBrightness(fl.cur - 1) end
    local fl_plus = Button:new{
        text           = "＋",
        text_font_face = "infofont",
        text_font_size = small_btn_size,
        text_font_bold = false,
        width          = small_btn_width,
        bordersize     = 0,
        show_parent    = show_parent,
        callback       = function() setBrightness(fl.cur + 1) end,
    }

    local row_gap = VerticalSpan:new{ width = Screen:scaleBySize(10) }

    local fl_cap_row = CenterContainer:new{
        dimen = Geom:new{ w = inner_width, h = fl_label:getSize().h },
        fl_label,
    }
    local fl_row = HorizontalGroup:new{
        align = "center",
        fl_minus,
        HorizontalSpan:new{ width = slider_gap },
        fl_progress,
        HorizontalSpan:new{ width = slider_gap },
        fl_plus,
    }

    refs.fl_progress   = fl_progress
    refs.fl_state      = fl
    refs.setBrightness = setBrightness
    table.insert(refs.sliders, { slider = fl_progress })

    local section_pad = VerticalSpan:new{ width = Screen:scaleBySize(10) }
    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, section_pad)
    table.insert(group, fl_cap_row)
    table.insert(group, row_gap)
    table.insert(group, fl_row)
    table.insert(group, section_pad)
    return group
end

return build_brightness_slider
