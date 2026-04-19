-- Full-screen onboarding / "what's new" slideshow widget.
-- Follows zen_toc_widget.lua conventions: InputContainer, paintTo, registerTouchZones.
--
-- Usage:
--   local QuickstartScreen = require("common/quickstart_screen")
--   UIManager:show(QuickstartScreen:new{
--       pages    = require("common/quickstart_pages").INSTALL_PAGES,
--       on_close = function() ... end,
--   })

local InputContainer = require("ui/widget/container/inputcontainer")
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Screen         = Device.screen
local _              = require("gettext")

local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
if not ok_iw then ImageWidget = nil end

local ok_ico, IconWidget = pcall(require, "ui/widget/iconwidget")
if not ok_ico then IconWidget = nil end

local QuickstartScreen = InputContainer:extend{
    pages    = nil,
    on_close = nil,
}

function QuickstartScreen:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self.pages     = self.pages or {}
    self._page_idx = 1
    self._total    = #self.pages

    local PAD     = Screen:scaleBySize(20)
    local TITLE_H = Screen:scaleBySize(60)
    local SEP_H   = 1
    local IMG_H   = math.min(Screen:scaleBySize(340), math.floor(sh * 0.48))
    local DOT_H   = Screen:scaleBySize(36)
    local NAV_H   = Screen:scaleBySize(64)
    local DESC_H  = sh - TITLE_H - SEP_H - IMG_H - DOT_H - NAV_H

    local DOT_R   = Screen:scaleBySize(5)
    local DOT_GAP = Screen:scaleBySize(14)
    local n       = math.max(1, self._total)
    local dot_total_w = n * (DOT_R * 2) + (n - 1) * DOT_GAP

    self._L = {
        sw = sw, sh = sh, pad = PAD,
        title_h     = TITLE_H,
        sep_h       = SEP_H,
        img_y       = TITLE_H + SEP_H,
        img_h       = IMG_H,
        desc_y      = TITLE_H + SEP_H + IMG_H,
        desc_h      = DESC_H,
        dot_y       = TITLE_H + SEP_H + IMG_H + DESC_H,
        dot_h       = DOT_H,
        nav_y       = sh - NAV_H,
        nav_h       = NAV_H,
        dot_r       = DOT_R,
        dot_gap     = DOT_GAP,
        dot_start_x = math.floor((sw - dot_total_w) / 2),
    }

    self:registerTouchZones({
        {
            id          = "qs_swipe",
            ges         = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onSwipe(ges) end,
        },
        {
            id          = "qs_tap",
            ges         = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onTap(ges) end,
        },
    })
end

function QuickstartScreen:paintTo(bb, x, y)
    local L = self._L

    bb:paintRect(x, y, L.sw, L.sh, Blitbuffer.COLOR_WHITE)

    local page = self.pages[self._page_idx] or {}

    -- -------------------------------------------------------------------------
    -- Title bar
    -- -------------------------------------------------------------------------
    local title_tw = TextWidget:new{
        text    = page.title or "",
        face    = Font:getFace("cfont", 24),
        bold    = true,
        padding = 0,
    }
    local tsz = title_tw:getSize()
    title_tw:paintTo(bb,
        x + math.floor((L.sw - tsz.w) / 2),
        y + math.floor((L.title_h - tsz.h) / 2))
    title_tw:free()

    bb:paintRect(x, y + L.title_h, L.sw, L.sep_h, Blitbuffer.COLOR_LIGHT_GRAY)

    -- -------------------------------------------------------------------------
    -- Image area: named icon (IconWidget) or file path (ImageWidget)
    -- -------------------------------------------------------------------------
    if page.icon and IconWidget then
        pcall(function()
            local max_h = L.img_h - Screen:scaleBySize(8)
            local icon_sz = math.min(L.sw - L.pad * 2, max_h)
            local ico = IconWidget:new{
                icon   = page.icon,
                width  = icon_sz,
                height = icon_sz,
            }
            local isz = ico:getSize()
            ico:paintTo(bb,
                x + math.floor((L.sw - isz.w) / 2),
                y + L.img_y + math.floor((L.img_h - isz.h) / 2))
            ico:free()
        end)
    elseif page.image and ImageWidget then
        pcall(function()
            local max_w = L.sw - L.pad * 2
            local max_h = L.img_h - Screen:scaleBySize(8)
            local iw = ImageWidget:new{
                file         = page.image,
                width        = max_w,
                height       = max_h,
                scale_factor = 0,
                alpha        = false,
            }
            local isz = iw:getSize()
            iw:paintTo(bb,
                x + math.floor((L.sw - isz.w) / 2),
                y + L.img_y + math.floor((L.img_h - isz.h) / 2))
            iw:free()
        end)
    end

    -- -------------------------------------------------------------------------
    -- Description text
    -- -------------------------------------------------------------------------
    local desc_w  = L.sw - L.pad * 4
    local desc_tb = TextBoxWidget:new{
        text      = page.description or "",
        face      = Font:getFace("cfont", 20),
        width     = desc_w,
        alignment = "center",
    }
    local dsz = desc_tb:getSize()
    desc_tb:paintTo(bb,
        x + math.floor((L.sw - desc_w) / 2),
        y + L.desc_y + math.floor((L.desc_h - dsz.h) / 2))
    desc_tb:free()

    -- -------------------------------------------------------------------------
    -- Dot indicators
    -- -------------------------------------------------------------------------
    local dot_cy = y + L.dot_y + math.floor(L.dot_h / 2)
    for i = 1, self._total do
        local dcx = x + L.dot_start_x + (i - 1) * (L.dot_r * 2 + L.dot_gap) + L.dot_r
        local color = (i == self._page_idx)
            and Blitbuffer.COLOR_BLACK
            or  Blitbuffer.COLOR_LIGHT_GRAY
        for row = -L.dot_r, L.dot_r do
            local half = math.floor(math.sqrt(L.dot_r * L.dot_r - row * row) + 0.5)
            if half > 0 then
                bb:paintRect(dcx - half, dot_cy + row, half * 2, 1, color)
            end
        end
    end

    -- -------------------------------------------------------------------------
    -- Navigation row
    -- -------------------------------------------------------------------------
    local nav_top = y + L.nav_y
    bb:paintRect(x, nav_top, L.sw, 1, Blitbuffer.COLOR_LIGHT_GRAY)

    -- Prev — hidden on the first page
    if self._page_idx > 1 then
        local prev_tw = TextWidget:new{
            text    = "‹  " .. _("Prev"),
            face    = Font:getFace("cfont", 20),
            fgcolor = Blitbuffer.COLOR_BLACK,
            padding = 0,
        }
        local psz = prev_tw:getSize()
        prev_tw:paintTo(bb,
            x + L.pad,
            nav_top + math.floor((L.nav_h - psz.h) / 2))
        prev_tw:free()
    end

    -- Next / Get Started
    local is_last  = (self._page_idx == self._total)
    local next_lbl = is_last and _("Get Started") or (_("Next") .. "  ›")
    local next_tw  = TextWidget:new{
        text    = next_lbl,
        face    = Font:getFace("cfont", 20),
        bold    = is_last,
        fgcolor = Blitbuffer.COLOR_BLACK,
        padding = 0,
    }
    local nsz = next_tw:getSize()
    next_tw:paintTo(bb,
        x + L.sw - L.pad - nsz.w,
        nav_top + math.floor((L.nav_h - nsz.h) / 2))
    next_tw:free()
end

function QuickstartScreen:setPage(n)
    if n < 1 or n > self._total then return end
    self._page_idx = n
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function QuickstartScreen:_nextPage()
    if self._page_idx >= self._total then
        self:onClose()
    else
        self:setPage(self._page_idx + 1)
    end
end

function QuickstartScreen:_prevPage()
    if self._page_idx > 1 then
        self:setPage(self._page_idx - 1)
    end
end

function QuickstartScreen:_onSwipe(ges)
    if ges.direction == "west" then
        self:_nextPage()
    elseif ges.direction == "east" then
        self:_prevPage()
    end
    return true
end

function QuickstartScreen:_onTap(ges)
    local p = ges.pos
    local L = self._L

    -- Navigation row
    if p.y >= L.nav_y then
        if p.x < math.floor(L.sw / 2) then
            self:_prevPage()
        else
            self:_nextPage()
        end
        return true
    end

    -- Dot row — tap a dot to jump directly to that page
    if p.y >= L.dot_y and p.y < L.dot_y + L.dot_h then
        for i = 1, self._total do
            local dx = L.dot_start_x + (i - 1) * (L.dot_r * 2 + L.dot_gap)
            if p.x >= dx and p.x < dx + L.dot_r * 2 then
                self:setPage(i)
                return true
            end
        end
    end

    return true
end

function QuickstartScreen:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.dimen
    end)
end

function QuickstartScreen:onClose()
    UIManager:close(self)
    if self.on_close then
        self.on_close()
    end
end

return QuickstartScreen
