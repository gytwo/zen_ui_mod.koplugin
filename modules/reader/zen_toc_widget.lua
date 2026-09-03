-- ZenTocWidget: popup table-of-contents modal for the page browser.
--
-- Usage:
--   local ZenTocWidget = require("modules/reader/zen_toc_widget")
--   UIManager:show(ZenTocWidget:new{
--       ui         = pbw.ui,          -- ReaderUI instance
--       focus_page = pbw.focus_page,  -- current page for highlighting
--       on_goto    = function(page)   -- called when user taps a chapter
--           if pbw:updateFocusPage(page, false) then pbw:update() end
--       end,
--   })
--
-- Interaction:
--   Tap entry         → navigate to chapter, close modal
--   Tap outside / ‹   → close modal
--   Swipe left/right  → next / prev page of TOC entries
--   Zen scroll bar    → shows current position in TOC list

local InputContainer = require("ui/widget/container/inputcontainer")
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local IconWidget     = require("ui/widget/iconwidget")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Screen         = Device.screen

-- ---------------------------------------------------------------------------
-- paintPill: shared scanline helper (same as zen_scroll_bar / zen_slider)
-- ---------------------------------------------------------------------------
local function paintPill(bb, px, py, pw, ph, color)
    if pw <= 0 or ph <= 0 then return end
    local r = math.min(pw, ph) / 2.0
    for row = 0, ph - 1 do
        local dy    = (row + 0.5) - ph * 0.5
        local inset = 0
        if math.abs(dy) < r then
            inset = math.ceil(r - math.sqrt(r * r - dy * dy))
        end
        local rw = pw - 2 * inset
        if rw > 0 then bb:paintRect(px + inset, py + row, rw, 1, color) end
    end
end

-- ---------------------------------------------------------------------------
-- Title normalization: strips zero-width spaces and collapses whitespace.
-- Epub NCX parsers sometimes insert ZWSP (U+200B) between characters, which
-- later surfaces as visible spaces (e.g. "I NTRODUCTION").
-- ---------------------------------------------------------------------------
local function normalize_title(s)
    if not s or s == "" then return "" end
    -- Zero-width space / non-joiner / joiner (E2 80 8B/8C/8D)
    s = s:gsub("\xE2\x80[\x8B\x8C\x8D]", "")
    -- BOM / zero-width no-break space (EF BB BF)
    s = s:gsub("\xEF\xBB\xBF", "")
    -- Non-breaking space (C2 A0) → regular space
    s = s:gsub("\xC2\xA0", " ")
    -- Narrow no-break space (E2 80 AF) → regular space
    s = s:gsub("\xE2\x80\xAF", " ")
    -- Collapse runs of whitespace and trim
    s = s:gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or s
    return s
end

-- ---------------------------------------------------------------------------
-- Captured once by page_browser.lua while __ZEN_UI_PLUGIN is still set.
local _plugin_ref = nil

-- Read scroll-bar style from config (live, no restart needed).
-- ---------------------------------------------------------------------------
local function get_style()
    local p = _plugin_ref or rawget(_G, "__ZEN_UI_PLUGIN")
    if p
        and type(p.config) == "table"
        and type(p.config.zen_scroll_bar) == "table"
    then
        return p.config.zen_scroll_bar.style or "dots"
    end
    return "dots"
end

-- ---------------------------------------------------------------------------
-- ZenTocWidget
-- ---------------------------------------------------------------------------
local ZenTocWidget = InputContainer:extend{
    ui         = nil,   -- ReaderUI instance
    on_goto    = nil,   -- callback(page_num) when entry tapped
    focus_page = 1,     -- current page; used to highlight active chapter
}

function ZenTocWidget:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    -- Collect TOC entries, cap depth at 3 to avoid overwhelming the list.
    -- ReaderToc exposes the raw array as .toc (not a method).
    -- Entries sharing the same page are merged: titles joined with " · ".
    local raw = (self.ui and self.ui.toc and self.ui.toc.toc) or {}
    local entries = {}
    local page_to_idx = {}
    for _, e in ipairs(raw) do
        local pg    = e.page or 1
        local depth = e.depth or 1
        if depth <= 3 then
            local title = normalize_title(e.title or "")
            local idx   = page_to_idx[pg]
            if idx then
                -- Merge: append title only if it's not a duplicate string
                local existing = entries[idx].title
                if title ~= "" and title ~= existing then
                    entries[idx].title = existing .. " · " .. title
                end
                -- Keep the shallowest (lowest) depth
                if depth < entries[idx].depth then
                    entries[idx].depth = depth
                end
            else
                page_to_idx[pg] = #entries + 1
                table.insert(entries, {
                    title = title,
                    page  = pg,
                    depth = depth,
                })
            end
        end
    end
    self._entries = entries

    -- -----------------------------------------------------------------------
    -- Layout constants (all screen-scaled)
    -- -----------------------------------------------------------------------
    local MODAL_W     = sw
    local BORDER      = 0
    local PAD         = Screen:scaleBySize(16)   -- horizontal content padding
    local TITLE_H     = Screen:scaleBySize(50)
    local SEP_H       = 1
    local ROW_H       = Screen:scaleBySize(48)
    local BAR_H       = Screen:scaleBySize(5)
    local BAR_PAD_V   = Screen:scaleBySize(7)
    local DOT_DIAM    = Screen:scaleBySize(10)
    local DOT_GAP     = Screen:scaleBySize(12)

    -- Fit rows into full screen height (minus title bar and optional scrollbar).
    local max_list_h_full = sh - TITLE_H - SEP_H
    local per_page_full   = math.max(1, math.floor(max_list_h_full / ROW_H))

    -- Only add a scrollbar when entries overflow one screenful.
    -- Height must accommodate the larger of bar and dots so live style toggle works.
    local needs_bar   = #entries > per_page_full
    local SCROLLBAR_H = needs_bar and (math.max(BAR_H, DOT_DIAM) + BAR_PAD_V * 2) or 0

    local max_list_h = max_list_h_full - SCROLLBAR_H
    local per_page   = math.max(1, math.floor(max_list_h / ROW_H))
    local list_h     = per_page * ROW_H
    local MODAL_H    = sh
    local MODAL_X    = 0
    local MODAL_Y    = 0

    -- Close-button hit-area: left TITLE_H-wide strip of the title bar.
    local CLOSE_W = TITLE_H   -- square hit zone
    local CLOSE_X = 0
    local CLOSE_Y = MODAL_Y

    -- Y where entry rows start (absolute screen coords).
    local LIST_Y = MODAL_Y + TITLE_H + SEP_H

    self._L = {
        sw = sw, sh = sh,
        modal_w = MODAL_W, modal_h = MODAL_H,
        modal_x = MODAL_X, modal_y = MODAL_Y,
        border  = BORDER,  pad     = PAD,
        title_h = TITLE_H, sep_h   = SEP_H,
        row_h   = ROW_H,   per_page = per_page,
        list_h  = list_h,  list_y   = LIST_Y,
        bar_h   = BAR_H,   bar_pad_v = BAR_PAD_V,
        dot_diam = DOT_DIAM, dot_gap = DOT_GAP,
        scrollbar_h = SCROLLBAR_H,
        close_x = CLOSE_X, close_y = CLOSE_Y,
        close_w = CLOSE_W, close_h = TITLE_H,
    }

    local nb_pages = math.max(1, math.ceil(#entries / per_page))
    self._nb_pages = nb_pages
    self._toc_page = 1

    -- Scroll to the page containing the active (current) chapter.
    self:_initActivePage()

    -- -----------------------------------------------------------------------
    -- Touch zones
    -- -----------------------------------------------------------------------
    self:registerTouchZones({
        {
            id          = "zen_toc_swipe",
            ges         = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onSwipe(ges) end,
        },
        {
            id          = "zen_toc_tap",
            ges         = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onTap(ges) end,
        },
    })
end

-- ---------------------------------------------------------------------------
-- Determine which TOC page contains the current chapter
-- ---------------------------------------------------------------------------
function ZenTocWidget:_initActivePage()
    local active_idx = 1
    for i, e in ipairs(self._entries) do
        if e.page <= self.focus_page then
            active_idx = i
        end
    end
    self._active_entry_idx = active_idx
    local L = self._L
    self._toc_page = math.max(1,
        math.min(self._nb_pages, math.ceil(active_idx / L.per_page)))
end

-- ---------------------------------------------------------------------------
-- paintTo: full custom rendering — no child widgets
-- ---------------------------------------------------------------------------
function ZenTocWidget:paintTo(bb, x, y)
    local L  = self._L

    -- Cover the full screen with white so the page browser beneath is hidden.
    bb:paintRect(x, y, L.sw, L.sh, Blitbuffer.COLOR_WHITE)

    -- Modal is full-screen: origin is (x, y).
    local mx = x + L.modal_x
    local my = y + L.modal_y

    -- -----------------------------------------------------------------------
    -- Title bar: "Contents" centred, left chevron on the left
    -- -----------------------------------------------------------------------
    local title_tw = TextWidget:new{
        text    = "Contents",
        face    = Font:getFace("cfont", 18),
        fgcolor = Blitbuffer.COLOR_BLACK,
        bold    = true,
        padding = 0,
    }
    local tsz = title_tw:getSize()
    title_tw:paintTo(bb,
        mx + math.floor((L.modal_w - tsz.w) / 2),
        my + math.floor((L.title_h - tsz.h) / 2))
    title_tw:free()

    -- Close icon (left chevron, positioned on the left)
    local icon_sz    = Screen:scaleBySize(26)
    local close_icon = IconWidget:new{
        icon   = "chevron.left",
        width  = icon_sz,
        height = icon_sz,
    }
    close_icon:paintTo(bb,
        mx + L.close_x + math.floor((L.close_w - icon_sz) / 2),
        my + math.floor((L.title_h - icon_sz) / 2))
    close_icon:free()

    -- Title separator line.
    bb:paintRect(mx, my + L.title_h, L.modal_w, L.sep_h, Blitbuffer.COLOR_LIGHT_GRAY)

    -- -----------------------------------------------------------------------
    -- TOC entry rows
    -- -----------------------------------------------------------------------
    local start_i = (self._toc_page - 1) * L.per_page + 1
    local end_i   = math.min(start_i + L.per_page - 1, #self._entries)
    local ry      = y + L.list_y   -- absolute y of the first row

    if #self._entries == 0 then
        -- Empty state
        local etw = TextWidget:new{
            text    = "No table of contents available",
            face    = Font:getFace("cfont", 15),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            padding = 0,
        }
        local esz = etw:getSize()
        etw:paintTo(bb,
            mx + math.floor((L.modal_w - esz.w) / 2),
            ry + math.floor((L.list_h - esz.h) / 2))
        etw:free()
    else
        for i = start_i, end_i do
            local e        = self._entries[i]
            local row_top  = ry + (i - start_i) * L.row_h
            local is_active = (i == self._active_entry_idx)

            -- Row separator (above every row except the first)
            if i > start_i then
                bb:paintRect(mx, row_top, L.modal_w, 1, Blitbuffer.gray(220))
            end

            -- Active row highlight band
            if is_active then
                bb:paintRect(mx + L.border, row_top + 1,
                    L.modal_w - L.border * 2, L.row_h - 1,
                    Blitbuffer.gray(238))
            end

            -- Depth indent
            local indent = Screen:scaleBySize(14 * math.max(0, (e.depth or 1) - 1))
            local text_x = mx + L.pad + indent

            -- Page number (right-aligned)
            local page_str = tostring(e.page)
            local pface    = Font:getFace("cfont", 16)
            local pn_tw    = TextWidget:new{
                text    = page_str,
                face    = pface,
                fgcolor = Blitbuffer.COLOR_BLACK,
                bold    = is_active,
                padding = 0,
            }
            local pn_sz = pn_tw:getSize()
            local pn_x  = mx + L.modal_w - L.pad - pn_sz.w
            pn_tw:paintTo(bb, pn_x,
                row_top + math.floor((L.row_h - pn_sz.h) / 2))
            pn_tw:free()

            -- Chapter title (truncated to available width)
            local title_max_w = pn_x - text_x - Screen:scaleBySize(8)
            local tface = Font:getFace("cfont", 18)
            local title_tw2 = TextWidget:new{
                text      = e.title,
                face      = tface,
                fgcolor   = Blitbuffer.COLOR_BLACK,
                bold      = is_active,
                max_width = title_max_w,
                padding   = 0,
            }
            local t_sz = title_tw2:getSize()
            title_tw2:paintTo(bb, text_x,
                row_top + math.floor((L.row_h - t_sz.h) / 2))
            title_tw2:free()
        end
    end

    -- -----------------------------------------------------------------------
    -- Zen scroll bar (pill track + thumb) at modal bottom
    -- Only rendered when there is more than one page of entries.
    -- -----------------------------------------------------------------------
    if self._nb_pages > 1 then
        local scrollbar_top = my + L.modal_h - L.scrollbar_h
        local bar_w = math.floor(L.modal_w * 0.78)
        local bar_x = mx + math.floor((L.modal_w - bar_w) / 2)

        if get_style() == "dots" then
            local diam = L.dot_diam
            local gap  = L.dot_gap
            local step = diam + gap
            local nb   = self._nb_pages

            if step * nb - gap > bar_w then
                step = math.max(2, math.floor(bar_w / nb))
                diam = math.max(1, step - 1)
            end

            local total_w = step * (nb - 1) + diam
            local start_x = bar_x + math.floor((bar_w - total_w) / 2)
            local dot_y   = scrollbar_top + math.floor((L.scrollbar_h - diam) / 2)

            for i = 1, nb do
                local dot_x = start_x + (i - 1) * step
                local color = (i == self._toc_page) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
                paintPill(bb, dot_x, dot_y, diam, diam, color)
            end
        else
            local by = scrollbar_top + math.floor((L.scrollbar_h - L.bar_h) / 2)
            paintPill(bb, bar_x, by, bar_w, L.bar_h, Blitbuffer.COLOR_LIGHT_GRAY)

            local thumb_w = math.max(L.bar_h * 2, math.floor(bar_w / self._nb_pages))
            thumb_w       = math.min(thumb_w, bar_w)
            local travel  = bar_w - thumb_w
            local pct     = (self._toc_page - 1) / (self._nb_pages - 1)
            local thumb_x = bar_x + math.floor(pct * travel)
            paintPill(bb, thumb_x, by, thumb_w, L.bar_h, Blitbuffer.COLOR_BLACK)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Helper: get line-height of a font face for vertical centring
-- ---------------------------------------------------------------------------
function ZenTocWidget:_textH(face_name, size)
    local tw = TextWidget:new{ text = "Wg", face = Font:getFace(face_name, size), padding = 0 }
    local h  = tw:getSize().h
    tw:free()
    return h
end

-- ---------------------------------------------------------------------------
-- Gesture handlers
-- ---------------------------------------------------------------------------
function ZenTocWidget:_onTap(ges)
    local p = ges.pos
    local L = self._L

    -- Tap on close button hit zone (top-left of title bar)
    if p.x >= L.close_x and p.x < L.close_x + L.close_w
    and p.y >= L.close_y and p.y < L.close_y + L.close_h then
        self:onClose()
        return true
    end

    -- Tap on an entry row
    if p.y >= L.list_y and p.y < L.list_y + L.list_h then
        local row_idx   = math.floor((p.y - L.list_y) / L.row_h)
        local entry_idx = (self._toc_page - 1) * L.per_page + row_idx + 1
        if entry_idx >= 1 and entry_idx <= #self._entries then
            local entry = self._entries[entry_idx]
            local page  = entry.page
            self:onClose()
            if self.on_goto then
                self.on_goto(page)
            end
            return true
        end
    end

    return true
end

function ZenTocWidget:_onSwipe(ges)
    local L = self._L

    -- Top 14% south swipe → open reader menu
    if ges.direction == "south" and ges.pos.y < Device.screen:getHeight() * 0.14 then
        local ok_rui, RUI = pcall(require, "apps/reader/readerui")
        if ok_rui and RUI and RUI.instance then
            local reader_menu = RUI.instance.menu
            if reader_menu and reader_menu.activation_menu ~= "tap" then
                reader_menu:onShowMenu(reader_menu:_getTabIndexFromLocation(ges))
                return true
            end
        end
    end

    -- East/west: internal TOC page navigation.
    if ges.direction == "west" and self._toc_page < self._nb_pages then
        self._toc_page = self._toc_page + 1
        UIManager:setDirty(self, function()
            return "ui", Geom:new{
                x = L.modal_x, y = L.modal_y, w = L.modal_w, h = L.modal_h,
            }
        end)
        return true
    elseif ges.direction == "east" and self._toc_page > 1 then
        self._toc_page = self._toc_page - 1
        UIManager:setDirty(self, function()
            return "ui", Geom:new{
                x = L.modal_x, y = L.modal_y, w = L.modal_w, h = L.modal_h,
            }
        end)
        return true
    end

    -- Swallow all other swipes to prevent the underlying page browser from turning pages.
    return true
end

function ZenTocWidget:onClose()
    UIManager:close(self)
end

function ZenTocWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.dimen
    end)
end

function ZenTocWidget.set_plugin(plugin)
    _plugin_ref = plugin
end

return ZenTocWidget
