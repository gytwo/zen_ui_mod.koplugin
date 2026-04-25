-- common/zen_screen.lua
-- Fullscreen update / splash screen.
--
-- Shows the Zen UI logo centered with an optional title at the top and an
-- optional action button at the bottom. Tap or swipe anywhere to dismiss.
--
-- Usage:
--   local ZenScreen = require("common/zen_screen")
--   UIManager:show(ZenScreen:new{
--       title    = "Zen UI updated to v1.2.3",  -- nil hides the title bar
--       button   = "Get Started",               -- nil -> default label; false -> no button
--       on_close = function() ... end,
--   })

local InputContainer = require("ui/widget/container/inputcontainer")
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Screen         = Device.screen
local _              = require("gettext")

local logger           = require("logger")
local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
if not ok_iw then ImageWidget = nil end

local _plugin_root = (function()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) ~= "@" then return "" end
    return src:sub(2):match("^(.*)/common/[^/]+%.lua$") or ""
end)()

-- Filled rounded rectangle with corner cutouts (bg_color fills corner pixels).
local function paintRoundedRect(bb, rx, ry, rw, rh, color, radius, bg_color)
    bb:paintRect(rx, ry, rw, rh, color)
    local r = radius
    for dy = 0, r - 1 do
        local t   = r - dy
        local cut = math.ceil(r - math.sqrt(math.max(0, r * r - t * t)))
        if cut > 0 then
            bb:paintRect(rx,            ry + dy,          cut, 1, bg_color)
            bb:paintRect(rx + rw - cut, ry + dy,          cut, 1, bg_color)
            bb:paintRect(rx,            ry + rh - 1 - dy, cut, 1, bg_color)
            bb:paintRect(rx + rw - cut, ry + rh - 1 - dy, cut, 1, bg_color)
        end
    end
end

local ZenScreen = InputContainer:extend{
    title    = nil,   -- string shown in top bar; nil hides the title bar entirely
    subtitle = nil,   -- string rendered above the icon (e.g. "Updated to v1.2.3")
    button   = nil,   -- button label string; nil -> "Get Started"; false -> no button
    on_close = nil,
}

function ZenScreen:init()
    logger.info("ZenScreen:init title=", self.title)
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    local PAD        = Screen:scaleBySize(20)
    local TITLE_H   = self.title and Screen:scaleBySize(60) or 0
    local SEP_H     = self.title and 1 or 0
    local SUBTITLE_H = self.subtitle and Screen:scaleBySize(56) or 0
    local BTN_H     = (self.button ~= false) and Screen:scaleBySize(80) or 0

    self._L = {
        sw          = sw,
        sh          = sh,
        pad         = PAD,
        title_h     = TITLE_H,
        sep_h       = SEP_H,
        subtitle_h  = SUBTITLE_H,
        btn_h       = BTN_H,
        logo_y      = TITLE_H + SEP_H + SUBTITLE_H,
        logo_h      = sh - TITLE_H - SEP_H - SUBTITLE_H - BTN_H,
        btn_y       = sh - BTN_H,
    }
    self._btn_rect = nil

    self:registerTouchZones({
        {
            id          = "zs_swipe",
            ges         = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function() self:onClose() return true end,
        },
        {
            id          = "zs_tap",
            ges         = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onTap(ges) end,
        },
    })
end

function ZenScreen:paintTo(bb, x, y)
    local L = self._L
    bb:paintRect(x, y, L.sw, L.sh, Blitbuffer.COLOR_WHITE)

    -- Title bar
    if self.title and L.title_h > 0 then
        local tw = TextWidget:new{
            text    = self.title,
            face    = Font:getFace("cfont", 24),
            bold    = true,
            padding = 0,
        }
        local tsz = tw:getSize()
        tw:paintTo(bb,
            x + math.floor((L.sw - tsz.w) / 2),
            y + math.floor((L.title_h - tsz.h) / 2))
        tw:free()
        bb:paintRect(x, y + L.title_h, L.sw, L.sep_h, Blitbuffer.COLOR_LIGHT_GRAY)
    end

    -- Subtitle above icon
    if self.subtitle and L.subtitle_h > 0 then
        local sub_y = y + L.title_h + L.sep_h
        local sw2 = TextWidget:new{
            text    = self.subtitle,
            face    = Font:getFace("cfont", 20),
            bold    = false,
            padding = 0,
        }
        local ssz = sw2:getSize()
        sw2:paintTo(bb,
            x + math.floor((L.sw - ssz.w) / 2),
            sub_y + math.floor((L.subtitle_h - ssz.h) / 2))
        sw2:free()
    end

    -- Centered logo
    if ImageWidget and _plugin_root ~= "" then
        local logo  = _plugin_root .. "/icons/zen_ui.svg"
        local max_sz = math.min(L.sw - L.pad * 4, L.logo_h - L.pad * 4)
        if max_sz > 0 then
            pcall(function()
                local iw = ImageWidget:new{
                    file         = logo,
                    width        = max_sz,
                    height       = max_sz,
                    scale_factor = 0,
                    alpha        = true,
                }
                local isz = iw:getSize()
                iw:paintTo(bb,
                    x + math.floor((L.sw  - isz.w) / 2),
                    y + L.logo_y + math.floor((L.logo_h - isz.h) / 2))
                iw:free()
            end)
        end
    end

    -- Button
    self._btn_rect = nil
    if self.button ~= false and L.btn_h > 0 then
        local lbl = (type(self.button) == "string" and self.button ~= "")
            and self.button or _("Get Started")
        local btn_w    = Screen:scaleBySize(240)
        local btn_h    = Screen:scaleBySize(54)
        local corner_r = Screen:scaleBySize(10)
        local btn_x    = x + math.floor((L.sw - btn_w) / 2)
        local btn_y    = y + L.btn_y + math.floor((L.btn_h - btn_h) / 2)

        paintRoundedRect(bb, btn_x, btn_y, btn_w, btn_h,
            Blitbuffer.COLOR_BLACK, corner_r, Blitbuffer.COLOR_WHITE)

        local btw = TextWidget:new{
            text    = lbl,
            face    = Font:getFace("cfont", 22),
            bold    = true,
            fgcolor = Blitbuffer.COLOR_WHITE,
            padding = 0,
        }
        local bsz = btw:getSize()
        btw:paintTo(bb,
            btn_x + math.floor((btn_w - bsz.w) / 2),
            btn_y + math.floor((btn_h - bsz.h) / 2))
        btw:free()

        self._btn_rect = { x = btn_x, y = btn_y, w = btn_w, h = btn_h }
    end
end

function ZenScreen:_onTap(ges)
    local p  = ges.pos
    local L  = self._L
    local br = self._btn_rect

    -- Button tap
    if br and p.x >= br.x and p.x < br.x + br.w
           and p.y >= br.y and p.y < br.y + br.h then
        self:onClose()
        return true
    end

    -- Tap in the bottom nav area always closes (no button present or outside btn)
    if L.btn_h > 0 and p.y >= L.btn_y then
        self:onClose()
        return true
    end

    return true
end

function ZenScreen:onShow()
    logger.info("ZenScreen:onShow dimen=", self.dimen)
    UIManager:setDirty(self, function()
        return "partial", self.dimen
    end)
end

function ZenScreen:onClose()
    UIManager:setDirty(nil, "full")
    UIManager:close(self)
    -- Block filebrowser taps briefly so the dismiss gesture doesn't open a file.
    _G.__ZEN_QUICKSTART_JUST_CLOSED = true
    UIManager:scheduleIn(1.5, function() _G.__ZEN_QUICKSTART_JUST_CLOSED = nil end)
    package.loaded["common/zen_screen"] = nil
    if self.on_close then
        self.on_close()
    end
end

return ZenScreen
