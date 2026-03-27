local function apply_titlebar()
    -- Custom Status Bar patch for KOReader File Manager
    -- Replaces the "KOReader" title text with left/right status info
    -- Moves home/plus buttons to the subtitle (path) row
    -- Settings menu under File Browser > Status bar

    local BD = require("ui/bidi")
    local Device = require("device")
    local FileManager = require("apps/filemanager/filemanager")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local NetworkMgr = require("ui/network/manager")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local Blitbuffer = require("ffi/blitbuffer")
    local LineWidget = require("ui/widget/linewidget")
    local Size = require("ui/size")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local utils = require("common/utils")
    local _ = require("gettext")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end

    local function is_enabled()
        local features = zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.titlebar == true
    end

    -- === Persistent config ===

    local separator_presets = {
        { key = "dot",    label = "Middle dot",    value = "  ·  " },
        { key = "bar",    label = "Vertical bar",  value = "  |  " },
        { key = "dash",   label = "Dash",          value = "  -  " },
        { key = "bullet", label = "Bullet",        value = "  •  " },
        { key = "space",  label = "Space only",    value = "   " },
        { key = "small-space",  label = "Space only (small)",    value = " " },
        { key = "none",   label = "No separator",  value = "" },
        { key = "custom", label = "Custom",        value = nil }, -- uses custom_separator
    }

    local config_default = {
        show = {
            wifi = true,
            disk = true,
            ram = false,
            frontlight = false,
            battery = true,
        },
        device_name = "",  -- empty = use Device.model
        separator_key = "dot",
        custom_separator = "  ",
        order = { "wifi", "disk", "ram", "frontlight", "battery" },
        show_time = true,
        time_12h = false,
        show_bottom_border = true,
        colored = false,
        bold_text = false,
        hide_topbar = false,
    }

    local function loadConfig()
        local config = zen_plugin.config.titlebar or {}
        -- Merge any new defaults into existing config
        for k, v in pairs(config_default) do
            if config[k] == nil then
                config[k] = utils.deepcopy(v)
            end
        end
        if type(config.show) == "table" then
            for k, v in pairs(config_default.show) do
                if config.show[k] == nil then
                    config.show[k] = v
                end
            end
        else
            config.show = utils.deepcopy(config_default.show)
        end
        -- Ensure order contains all known items
        if type(config.order) ~= "table" then
            config.order = utils.deepcopy(config_default.order)
        else
            local order_set = {}
            for _, v in ipairs(config.order) do order_set[v] = true end
            for _, v in ipairs(config_default.order) do
                if not order_set[v] then
                    table.insert(config.order, v)
                end
            end
        end
        zen_plugin.config.titlebar = config
        return config
    end

    local config = loadConfig()

    local function getSeparator()
        for _, preset in ipairs(separator_presets) do
            if preset.key == config.separator_key then
                return preset.value or config.custom_separator
            end
        end
        return "  ·  "
    end

    -- === Layout constants ===

    local function getBarFont()
        if config.bold_text then
            return Font:getFace("NotoSans-Bold.ttf", Font.sizemap["xx_smallinfofont"])
        end
        return Font:getFace("xx_smallinfofont")
    end
    local h_padding = Screen:scaleBySize(10)

    -- Disk free space cache
    local cached_disk_text = nil
    local cached_disk_time = 0

    -- === Color text support ===
    -- TextWidget uses colorblitFrom which converts RGB to grayscale.
    -- We need colorblitFromRGB32 for actual color rendering.

    local RenderText = require("ui/rendertext")

    local ColorTextWidget = TextWidget:extend{}

    function ColorTextWidget:paintTo(bb, x, y)
        self:updateSize()
        if self._is_empty then return end

        if not self.fgcolor or Blitbuffer.isColor8(self.fgcolor) or not Screen:isColorScreen() then
            TextWidget.paintTo(self, bb, x, y)
            return
        end

        if not self.use_xtext then
            -- Fallback path: render normally (no RGB support here)
            TextWidget.paintTo(self, bb, x, y)
            return
        end

        if not self._xshaping then
            self._xshaping = self._xtext:shapeLine(self._shape_start, self._shape_end,
                                                self._shape_idx_to_substitute_with_ellipsis)
        end

        local text_width = bb:getWidth() - x
        if self.max_width and self.max_width < text_width then
            text_width = self.max_width
        end
        local pen_x = 0
        local baseline = self.forced_baseline or self._baseline_h
        for _, xglyph in ipairs(self._xshaping) do
            if pen_x >= text_width then break end
            local face = self.face.getFallbackFont(xglyph.font_num)
            local glyph = RenderText:getGlyphByIndex(face, xglyph.glyph, self.bold)
            bb:colorblitFromRGB32(
                glyph.bb,
                x + pen_x + glyph.l + xglyph.x_offset,
                y + baseline - glyph.t - xglyph.y_offset,
                0, 0,
                glyph.bb:getWidth(), glyph.bb:getHeight(),
                self.fgcolor)
            pen_x = pen_x + xglyph.x_advance
        end
    end

    -- === Color definitions ===

    local colors = {
        wifi_on = Blitbuffer.ColorRGB32(0x33, 0x99, 0xFF, 0xFF),     -- blue
        wifi_off = Blitbuffer.ColorRGB32(0xDD, 0x33, 0x33, 0xFF),   -- red
        disk = Blitbuffer.ColorRGB32(0x33, 0xAA, 0x55, 0xFF),       -- green
        ram = Blitbuffer.ColorRGB32(0x33, 0xAA, 0x55, 0xFF),        -- green
        frontlight = Blitbuffer.ColorRGB32(0xFF, 0xAA, 0x00, 0xFF), -- amber
        battery_high = Blitbuffer.ColorRGB32(0x33, 0xAA, 0x55, 0xFF),   -- green
        battery_mid = Blitbuffer.ColorRGB32(0xFF, 0xAA, 0x00, 0xFF),    -- yellow/amber
        battery_low = Blitbuffer.ColorRGB32(0xDD, 0x33, 0x33, 0xFF),    -- red
    }

    -- === Data fetching functions (return icon, label, color) ===

    local function getDeviceName()
        if config.device_name and config.device_name ~= "" then
            return config.device_name
        end
        return Device.model or "KOReader"
    end

    local function getWifiInfo()
        if not config.show.wifi then return nil end
        if NetworkMgr:isWifiOn() then
            return "\u{ECA8}", nil, colors.wifi_on
        else
            return "\u{ECA9}", nil, colors.wifi_off
        end
    end

    local function getRamInfo()
        if not config.show.ram then return nil end
        local statm = io.open("/proc/self/statm", "r")
        if statm then
            local _, rss = statm:read("*number", "*number")
            statm:close()
            if rss then
                return "\u{EA5A}", string.format(" %dM", math.floor(rss / 256)), colors.ram
            end
        end
        return "\u{EA5A}", " ?M", colors.ram
    end

    local function getDiskInfo()
        if not config.show.disk then return nil end
        local now = os.time()
        if cached_disk_text and (now - cached_disk_time) < 300 then
            return "\u{F0A0}", " " .. cached_disk_text, colors.disk
        end
        local pipe = io.popen("df -h /mnt/onboard 2>/dev/null || df -h / 2>/dev/null")
        if pipe then
            local _ = pipe:read("*line") -- skip header
            local line = pipe:read("*line")
            pipe:close()
            if line then
                local avail = line:match("%S+%s+%S+%s+%S+%s+(%S+)")
                if avail then
                    cached_disk_text = avail
                    cached_disk_time = now
                    return "\u{F0A0}", " " .. avail, colors.disk
                end
            end
        end
        return "\u{F0A0}", " ?", colors.disk
    end

    local function getFrontlightInfo()
        if not config.show.frontlight then return nil end
        local powerd = Device:getPowerDevice()
        if powerd:isFrontlightOn() then
            return "☼", string.format(" %d%%", powerd:frontlightIntensity()), colors.frontlight
        else
            return "☼", " Off", colors.frontlight
        end
    end

    local function getBatteryInfo()
        if not config.show.battery then return nil end
        if Device:hasBattery() then
            local powerd = Device:getPowerDevice()
            local batt_lvl = powerd:getCapacity()
            local batt_symbol = powerd:getBatterySymbol(
                powerd:isCharged(), powerd:isCharging(), batt_lvl)
            local color
            if batt_lvl >= 50 then
                color = colors.battery_high
            elseif batt_lvl >= 20 then
                color = colors.battery_mid
            else
                color = colors.battery_low
            end
            return BD.wrap(batt_symbol), batt_lvl .. "%", color
        end
        return nil
    end

    -- === Item registry ===

    local item_fetchers = {
        wifi = getWifiInfo,
        disk = getDiskInfo,
        ram = getRamInfo,
        frontlight = getFrontlightInfo,
        battery = getBatteryInfo,
    }

    -- === Build the status row ===

    local function createStatusRow()
        local left_text = TextWidget:new{
            text = getDeviceName(),
            face = getBarFont(),
        }

        local sep = getSeparator()
        local use_color = config.colored
        local right_group = HorizontalGroup:new{}
        local first = true
        for _, key in ipairs(config.order) do
            local fn = item_fetchers[key]
            if fn then
                local icon, label, color = fn()
                if icon and icon ~= "" then
                    if not first and sep ~= "" then
                        table.insert(right_group, TextWidget:new{
                            text = sep,
                            face = getBarFont(),
                        })
                    end
                    if use_color and color then
                        -- Icon in color, label in black
                        table.insert(right_group, ColorTextWidget:new{
                            text = icon,
                            face = getBarFont(),
                            fgcolor = color,
                        })
                        if label and label ~= "" then
                            table.insert(right_group, TextWidget:new{
                                text = label,
                                face = getBarFont(),
                            })
                        end
                    else
                        -- All black: combine icon + label
                        local text = label and (icon .. label) or icon
                        table.insert(right_group, TextWidget:new{
                            text = text,
                            face = getBarFont(),
                        })
                    end
                    first = false
                end
            end
        end

        local row_height = math.max(left_text:getSize().h, right_group:getSize().h)
        local screen_w = Screen:getWidth()

        local inner_w = screen_w - h_padding * 2
        local CenterContainer = require("ui/widget/container/centercontainer")

        local row = OverlapGroup:new{
            dimen = Geom:new{ w = screen_w, h = row_height },
            LeftContainer:new{
                dimen = Geom:new{ w = screen_w, h = row_height },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = h_padding },
                    left_text,
                },
            },
            RightContainer:new{
                dimen = Geom:new{ w = screen_w, h = row_height },
                HorizontalGroup:new{
                    right_group,
                    HorizontalSpan:new{ width = h_padding },
                },
            },
        }

        if config.show_time then
            local fmt = config.time_12h and "%I:%M %p" or "%H:%M"
            local time_str = os.date(fmt)
            -- Strip leading zero from 12h hours (e.g. "09:30 AM" -> "9:30 AM")
            if config.time_12h then
                time_str = time_str:gsub("^0(%d:)", "%1")
            end
            local time_text = TextWidget:new{
                text = time_str,
                face = getBarFont(),
            }
            table.insert(row, 2, CenterContainer:new{
                dimen = Geom:new{ w = screen_w, h = row_height },
                time_text,
            })
        end

        if not config.show_bottom_border then
            return row
        end

        local border = LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = Size.line.medium },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }

        return VerticalGroup:new{
            align = "center",
            row,
            CenterContainer:new{
                dimen = Geom:new{ w = screen_w, h = Size.line.medium },
                border,
            },
        }
    end

    -- === Replace title content and reposition buttons ===

    function FileManager:_updateStatusBar()
        if not is_enabled() then
            return
        end

        local tb = self.title_bar
        if not tb or not tb.title_group then return end

        local title_group = tb.title_group
        if #title_group < 2 then return end

        local status_row = createStatusRow()
        title_group[2] = status_row
        title_group:resetLayout()

        -- title_group: [1] VerticalSpan, [2] status_row, [3] VerticalSpan, [4] subtitle
        local subtitle_y = 0
        for i = 1, math.min(3, #title_group) do
            subtitle_y = subtitle_y + title_group[i]:getSize().h
        end

        local subtitle_h = 0
        if #title_group >= 4 then
            subtitle_h = title_group[4]:getSize().h
        end

        local area_h = tb.titlebar_height - subtitle_y
        local subtitle_center_y = subtitle_y + math.floor((area_h - subtitle_h) / 2)

        -- Center button icons with subtitle text
        local btn_padding = tb.button_padding
        local icon_h = tb.left_button and tb.left_button.width or 0
        local target_center = subtitle_center_y + math.floor(subtitle_h / 2)
        local button_y = target_center - btn_padding - math.floor(icon_h / 2)

        if tb.left_button then
            tb.left_button.overlap_align = nil
            tb.left_button.overlap_offset = {0, button_y}
        end
        if tb.right_button then
            local btn_w = tb.right_button:getSize().w
            tb.right_button.overlap_align = nil
            tb.right_button.overlap_offset = {tb.width - btn_w, button_y}
        end

        -- Center subtitle vertically in the area
        if #title_group >= 3 then
            local VerticalSpan = require("ui/widget/verticalspan")
            local status_row_bottom = 0
            for i = 1, 2 do
                status_row_bottom = status_row_bottom + title_group[i]:getSize().h
            end
            local new_padding = subtitle_center_y - status_row_bottom
            if new_padding > 0 then
                title_group[3] = VerticalSpan:new{ width = new_padding }
                title_group:resetLayout()
            end
        end

        UIManager:setDirty(self.show_parent or self, "ui", tb.dimen)
    end

    -- === Hooks ===

    local orig_setupLayout = FileManager.setupLayout

    function FileManager:setupLayout()
        if not is_enabled() then
            return orig_setupLayout(self)
        end

        if config.hide_topbar then
            -- Patch TitleBar constructor to suppress only the subtitle row and
            -- icon buttons.  Our custom status row (the title area) is kept so
            -- the height accounts for it and _updateStatusBar can still paint it.
            local TitleBar = require("ui/widget/titlebar")
            local orig_new = TitleBar.new
            TitleBar.new = function(cls, t)
                if type(t) == "table" then
                    t.subtitle            = nil
                    t.subtitle_truncate_left = nil
                    t.subtitle_fullwidth  = nil
                    t.left_icon           = nil
                    t.left_icon_tap_callback  = nil
                    t.left_icon_hold_callback = nil
                    t.right_icon          = nil
                    t.right_icon_tap_callback  = nil
                    t.right_icon_hold_callback = nil
                    t.bottom_v_padding    = 0
                end
                return orig_new(cls, t)
            end
            orig_setupLayout(self)
            TitleBar.new = orig_new
        else
            orig_setupLayout(self)
        end

        -- Defer to run after all plugins (coverbrowser etc.) finish init
        local fm = self
        UIManager:nextTick(function()
            fm:_updateStatusBar()
            -- Restore subtitle path only when subtitle widget exists
            if not config.hide_topbar and fm.file_chooser and fm.file_chooser.path then
                fm:updateTitleBarPath(fm.file_chooser.path)
            end
        end)

        -- Periodic refresh for time/battery/disk
        local function autoRefresh()
            if FileManager.instance ~= fm then return end
            fm:_updateStatusBar()
            UIManager:scheduleIn(60, autoRefresh)
        end
        UIManager:scheduleIn(60, autoRefresh)
    end

    local orig_onPathChanged = FileManager.onPathChanged

    function FileManager:onPathChanged(path)
        if orig_onPathChanged then
            orig_onPathChanged(self, path)
        end
        if is_enabled() then
            self:_updateStatusBar()
        end
    end

    local function chainHook(event_name)
        local orig = FileManager[event_name]
        FileManager[event_name] = function(self)
            if orig then orig(self) end
            if is_enabled() then
                self:_updateStatusBar()
            end
        end
    end

    chainHook("onNetworkConnected")
    chainHook("onNetworkDisconnected")
    chainHook("onCharging")
    chainHook("onNotCharging")
    chainHook("onResume")
end


return apply_titlebar
