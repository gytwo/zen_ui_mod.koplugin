local function apply_zen_scroll_bar()
    -- Replaces the pagination footer with a pill-bar, dot-style, or page-number
    -- scroll indicator. Style is read live from config; no restart needed to toggle.
    local _           = require("gettext")
    local Blitbuffer  = require("ffi/blitbuffer")
    local Device      = require("device")
    local Font        = require("ui/font")
    local Geom        = require("ui/geometry")
    local IconWidget  = require("ui/widget/iconwidget")
    local Menu        = require("ui/widget/menu")
    local RenderText  = require("ui/rendertext")
    local Screen      = Device.screen
    local UIManager   = require("ui/uimanager")
    local target_menus = {
        filemanager = true,
        history = true,
        collections = true,
        library_view = true, -- Rakuyomi
    }

    -- Visual dimensions (scaled to device DPI).
    local BAR_H      = Screen:scaleBySize(5)    -- bar track / thumb height
    local DOT_DIAM   = Screen:scaleBySize(10)   -- dot diameter (dots style)
    local DOT_GAP    = Screen:scaleBySize(12)   -- gap between dots
    local BAR_W_PCT  = 0.92                     -- track width as fraction of screen width
    local BAR_PAD    = Screen:scaleBySize(5)    -- vertical padding above and below the indicator
    -- Footer must be tall enough for the larger of bar or dots.
    local FOOTER_H    = math.max(BAR_H, DOT_DIAM) + BAR_PAD * 2
    -- Tap zone width for each chevron in page_number style.
    local CHEV_W      = Screen:scaleBySize(60)
    -- Desired chevron icon size; page_number footer is made tall enough to fit.
    local PN_ICON_SIZE = Screen:scaleBySize(36)
    local PN_FOOTER_H  = math.max(FOOTER_H, PN_ICON_SIZE + Screen:scaleBySize(6))

    local TRACK_COLOR     = Blitbuffer.COLOR_LIGHT_GRAY
    local THUMB_COLOR     = Blitbuffer.COLOR_BLACK
    local DOT_INACT_COLOR = Blitbuffer.COLOR_DARK_GRAY

    -- Font for page_number style: same face as the status bar clock.
    local _pn_face = Font:getFace("xx_smallinfofont")

    -- Capture plugin reference while __ZEN_UI_PLUGIN is still set.
    local _plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    -- Draw a filled pill (stadium) shape using scanline paintRect.
    local function paintPill(bb, px, py, pw, ph, color)
        if pw <= 0 or ph <= 0 then return end
        local r = math.min(pw, ph) / 2.0
        for row = 0, ph - 1 do
            local dy    = (row + 0.5) - (ph * 0.5)   -- signed dist from centre row
            local inset = 0
            if math.abs(dy) < r then
                -- Horizontal inset imposed by the circular end-cap at this row.
                inset = math.ceil(r - math.sqrt(r * r - dy * dy))
            end
            local rw = pw - 2 * inset
            if rw > 0 then
                bb:paintRect(px + inset, py + row, rw, 1, color)
            end
        end
    end

    -- Config accessors — read live at paint/event time so toggles take effect
    -- on the next repaint without a menu restart.
    local function get_style()
        local p = _plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        if p and type(p.config) == "table" and type(p.config.zen_scroll_bar) == "table" then
            local s = p.config.zen_scroll_bar.style
            if s == "dots" or s == "bar" or s == "page_number" then return s end
        end
        return "bar"
    end

    local function get_page_format()
        local p = _plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        if p and type(p.config) == "table" and type(p.config.zen_scroll_bar) == "table" then
            return p.config.zen_scroll_bar.page_number_format or "current"
        end
        return "current"
    end

    local function get_hold_skip()
        local p = _plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        if p and type(p.config) == "table" and type(p.config.zen_scroll_bar) == "table" then
            return p.config.zen_scroll_bar.hold_skip or "10"
        end
        return "10"
    end

    local orig_menu_init = Menu.init

    function Menu:init()
        orig_menu_init(self)

        -- Check if this is a target menu:
        -- 1. Named menus (filemanager, history, collections)
        -- 2. File browser style menus (covers_fullscreen + is_borderless + title_bar_fm_style)
        -- 3. Bookmarks menu (is_borderless + title_bar_fm_style + title_bar_left_icon == "appbar.menu")
        local is_bookmarks_menu = self.is_borderless
            and self.title_bar_fm_style
            and self.title_bar_left_icon == "appbar.menu"

        if not target_menus[self.name]
           and not (self.covers_fullscreen and self.is_borderless and self.title_bar_fm_style)
           and not is_bookmarks_menu then
            return
        end

        if not self.page_info or not self.page_info_text or not self.page_return_arrow then
            return
        end

        local menu   = self
        local scr_w  = Screen:getWidth()
        local bar_w  = math.floor(scr_w * BAR_W_PCT)
        local bar_x  = math.floor((scr_w - bar_w) / 2)   -- centred offset from left edge
        -- Decide footer height once at init; page_number gets the taller strip.
        local foot_h = get_style() == "page_number" and PN_FOOTER_H or FOOTER_H
        local foot   = Geom:new{ w = scr_w, h = foot_h }

        -- Chevron icons for page_number style, cached per menu instance.
        local icon_size = PN_ICON_SIZE
        local _icon_l   = IconWidget:new{ icon = "chevron.left",  width = icon_size, height = icon_size }
        local _icon_r   = IconWidget:new{ icon = "chevron.right", width = icon_size, height = icon_size }

        -- _recalculateDimen uses getSize().h on these two widgets to compute
        -- bottom_height.  Returning foot reserves exactly that strip.
        self.page_info_text.getSize    = function() return foot end
        self.page_return_arrow.getSize = function() return foot end

        -- BottomContainer positions page_info at y = inner_dimen.h - h.
        self.page_info.getSize = function() return foot end

        -- Replace the chevron rendering with the configured scroll indicator.
        -- x, y: absolute screen position supplied by BottomContainer.
        self.page_info.paintTo = function(_, bb, x, y)
            local nb   = menu.page_num or 1
            local page = menu.page     or 1

            -- Nothing to show if the list fits on one page.
            if nb <= 1 then return end

            local style = get_style()

            if style == "dots" and nb <= 75 then
                -- Dots style
                -- One circle per page; the active page is filled black.
                local diam = DOT_DIAM
                local gap  = DOT_GAP
                local step = diam + gap

                -- If dots overflow the available width, shrink to fit.
                if step * nb - gap > bar_w then
                    step = math.max(2, math.floor(bar_w / nb))
                    diam = math.max(1, step - 1)
                end

                local total_w = step * (nb - 1) + diam
                local start_x = x + bar_x + math.floor((bar_w - total_w) / 2)
                -- Centre dots vertically within the footer strip.
                local dot_y   = y + math.floor((foot_h - diam) / 2)

                for i = 1, nb do
                    local dot_x = start_x + (i - 1) * step
                    local color = (i == page) and THUMB_COLOR or DOT_INACT_COLOR
                    paintPill(bb, dot_x, dot_y, diam, diam, color)
                end

            elseif style == "page_number" then
                -- Page number style: centered page text with ‹ › chevrons at
                -- the same x-positions as the bar track edges.
                local fmt = get_page_format()
                local text_str = fmt == "total"
                    and (tostring(page) .. " / " .. tostring(nb))
                    or  tostring(page)

                -- Vertical baseline: roughly centres the text in foot_h.
                local face_h     = _pn_face.bb_size or _pn_face.size or Screen:scaleBySize(10)
                local baseline_y = y + math.floor(foot_h / 2 + face_h * 0.25)

                -- Centered page label between the two chevron zones.
                local inner_w  = bar_w - CHEV_W * 2
                local text_w   = RenderText:sizeUtf8Text(0, 9999, _pn_face, text_str, true, false).x
                local text_x   = x + bar_x + CHEV_W + math.floor((inner_w - text_w) / 2)
                RenderText:renderUtf8Text(bb, text_x, baseline_y, _pn_face,
                                         text_str, false, false, THUMB_COLOR)

                -- Left and right chevron icons, centered vertically and horizontally in their tap zones.
                local icon_y = y + math.floor((foot_h - icon_size) / 2)
                local lx     = x + bar_x + math.floor((CHEV_W - icon_size) / 2)
                local rx     = x + bar_x + bar_w - CHEV_W + math.floor((CHEV_W - icon_size) / 2)
                _icon_l:paintTo(bb, lx, icon_y)
                _icon_r:paintTo(bb, rx, icon_y)

            else
                -- Bar style (default)
                -- Track (full bar width, lighter colour).
                paintPill(bb, x + bar_x, y + BAR_PAD, bar_w, BAR_H, TRACK_COLOR)

                -- Thumb (darker, positioned to reflect the current page).
                -- Thumb width is proportional to 1/nb, floored at BAR_H*2 so it
                -- remains recognisably pill-shaped even with many pages.
                local thumb_w = math.max(BAR_H * 2, math.floor(bar_w / nb))
                thumb_w       = math.min(thumb_w, bar_w)
                local travel  = bar_w - thumb_w
                local pct     = (page - 1) / (nb - 1)
                local thumb_x = bar_x + math.floor(pct * travel)
                paintPill(bb, x + thumb_x, y + BAR_PAD, thumb_w, BAR_H, THUMB_COLOR)
            end
        end

        -- Register touch zones for the page_number style.
        -- These are no-ops when another style is active (get_style() guard).
        -- screen_zone uses ratio_x/y/w/h (fractions of screen dimensions),
        -- as required by InputContainer:registerTouchZones.
        local scr_h    = Screen:getHeight()
        local footer_y = self.dimen.y + self.dimen.h - foot_h
        local menu_x   = self.dimen.x

        -- Pre-compute ratios shared across zones.
        local rz_left_x   = (menu_x + bar_x) / scr_w
        local rz_right_x  = (menu_x + bar_x + bar_w - CHEV_W) / scr_w
        local rz_center_x = (menu_x + bar_x + CHEV_W) / scr_w
        local rz_chev_w   = CHEV_W / scr_w
        local rz_center_w = math.max(0, bar_w - CHEV_W * 2) / scr_w
        local rz_y        = footer_y / scr_h
        local rz_h        = foot_h / scr_h

        self:registerTouchZones({
            -- Left chevron — tap: prev page.
            {
                id = "zen_pn_left_tap",
                ges = "tap",
                screen_zone = { ratio_x = rz_left_x,   ratio_y = rz_y, ratio_w = rz_chev_w,   ratio_h = rz_h },
                handler = function()
                    if get_style() ~= "page_number" then return end
                    local target = menu.page > 1 and (menu.page - 1) or menu.page_num
                    menu:onGotoPage(target)
                    return true
                end,
            },
            -- Right chevron — tap: next page.
            {
                id = "zen_pn_right_tap",
                ges = "tap",
                screen_zone = { ratio_x = rz_right_x,  ratio_y = rz_y, ratio_w = rz_chev_w,   ratio_h = rz_h },
                handler = function()
                    if get_style() ~= "page_number" then return end
                    local target = menu.page < menu.page_num and (menu.page + 1) or 1
                    menu:onGotoPage(target)
                    return true
                end,
            },
            -- Center area — tap: numeric "Go to page" input dialog.
            {
                id = "zen_pn_center_tap",
                ges = "tap",
                screen_zone = { ratio_x = rz_center_x, ratio_y = rz_y, ratio_w = rz_center_w, ratio_h = rz_h },
                handler = function()
                    if get_style() ~= "page_number" then return end
                    local createZenDialog = require("common/zen_dialog")
                    local nb     = menu.page_num or 1
                    local dialog = createZenDialog{
                        title           = _("Go to page"),
                        input           = "",
                        input_type      = "number",
                        input_hint      = "1 - " .. tostring(nb),
                        button_text     = "\u{F124} " .. _("Go"),
                        button_callback = function(dialog)
                            local p = tonumber(dialog:getInputText())
                            if p and p >= 1 and p <= nb then
                                UIManager:close(dialog)
                                menu:onGotoPage(math.floor(p))
                            end
                        end,
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                    return true
                end,
            },
            -- Left chevron — hold: skip back (configurable) or jump to first page.
            {
                id = "zen_pn_left_hold",
                ges = "hold",
                screen_zone = { ratio_x = rz_left_x,  ratio_y = rz_y, ratio_w = rz_chev_w, ratio_h = rz_h },
                handler = function()
                    if get_style() ~= "page_number" then return end
                    local skip   = get_hold_skip()
                    local target = skip == "ends"
                        and 1
                        or  math.max(1, menu.page - (tonumber(skip) or 10))
                    menu:onGotoPage(target)
                    return true
                end,
            },
            -- Right chevron — hold: skip forward (configurable) or jump to last page.
            {
                id = "zen_pn_right_hold",
                ges = "hold",
                screen_zone = { ratio_x = rz_right_x, ratio_y = rz_y, ratio_w = rz_chev_w, ratio_h = rz_h },
                handler = function()
                    if get_style() ~= "page_number" then return end
                    local skip   = get_hold_skip()
                    local target = skip == "ends"
                        and menu.page_num
                        or  math.min(menu.page_num, menu.page + (tonumber(skip) or 10))
                    menu:onGotoPage(target)
                    return true
                end,
            },
        })

        -- Re-run layout so the new sizes take effect before the first paint.
        self:_recalculateDimen()
    end
end

return apply_zen_scroll_bar
