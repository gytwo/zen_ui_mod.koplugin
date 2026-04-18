-- Zen UI Stats Page
-- Fullscreen reading statistics display for the navbar Stats tab.
-- Uses Menu widget for correct TitleBar/height, matching history/collections.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("gettext")

-- Format seconds as "Xh Ym" or "Ym"
local function formatTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then
        return h .. "h " .. m .. "m"
    else
        return m .. "m"
    end
end

-- Format longer durations with day-scale support: "Xd Xh", "Xh Ym", or "Ym"
local function formatLongTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    local m = math.floor((secs % 3600) / 60)
    if d > 0 then
        return h > 0 and (d .. "d " .. h .. "h") or (d .. "d")
    elseif h > 0 then
        return h .. "h " .. m .. "m"
    else
        return m .. "m"
    end
end

local StatsDB   = require("common/db_stats")
local LibraryDB = require("common/db_library")

local StatsPage = {}

-- ─── Query statistics ──────────────────────────────────────────────

local function queryStats()
    local stats = StatsDB.queryStats()
    local book_counts = LibraryDB.getBookCounts()
    stats.books_finished = book_counts.finished
    stats.books_reading  = book_counts.reading
    stats.total_books    = book_counts.total
    return stats
end

-- ─── Card widget helper ────────────────────────────────────────────

local function createCard(opts)
    local card_w = opts.width
    local card_h = opts.height
    local value_text  = opts.value  or ""
    local label_text  = opts.label  or ""
    local header_text = opts.header or ""  -- optional small text shown above the value

    local value_font  = Font:getFace("infofont",      opts.value_size  or 28)
    local label_font  = Font:getFace("smallinfofont", opts.label_size  or 16)
    local header_font = Font:getFace("smallinfofont", opts.header_size or 16)

    local padding = Screen:scaleBySize(8)
    local margin  = Screen:scaleBySize(4)
    local border  = 0
    -- Inner width available to content
    local inner_w = card_w - (margin + padding) * 2

    local value_widget = TextWidget:new{
        text = value_text,
        face = value_font,
        max_width = inner_w,
    }

    local label_widget = TextWidget:new{
        text = label_text,
        face = label_font,
        fgcolor = Blitbuffer.Color8(0x66),
        max_width = inner_w,
    }

    local content_items = { align = "center" }
    if header_text ~= "" then
        table.insert(content_items, TextWidget:new{
            text      = header_text,
            face      = header_font,
            fgcolor   = Blitbuffer.Color8(0x66),
            max_width = inner_w,
        })
        table.insert(content_items, VerticalSpan:new{ width = Screen:scaleBySize(2) })
    end
    table.insert(content_items, value_widget)
    table.insert(content_items, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(content_items, label_widget)

    local content = VerticalGroup:new(content_items)

    -- Compute content natural height so the card can grow to fit.
    -- Use whichever is larger: the fixed card_h or content + chrome.
    local chrome_h = (margin + padding) * 2
    local natural_h = content:getSize().h + chrome_h
    local actual_h = math.max(card_h, natural_h)

    local inner_h = actual_h - chrome_h

    return FrameContainer:new{
        width  = card_w,
        height = actual_h,
        padding = padding,
        margin  = margin,
        bordersize = border,
        radius = Screen:scaleBySize(8),
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            content,
        },
    }
end

-- ─── Section header ────────────────────────────────────────────────

local function createSectionHeader(text, width, padding)
    local header_font = Font:getFace("smallinfofontbold", 18)
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = Screen:scaleBySize(30) },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = padding },
            TextWidget:new{
                text = text,
                face = header_font,
            },
        },
    }
end

-- ─── Progress bar row (for reading goal or weekly bar chart) ───────

local function createProgressRow(label, value, max_value, width, duration_str)
    local row_h = Screen:scaleBySize(24)
    local label_font = Font:getFace("smallinfofont", 14)
    local value_font = Font:getFace("smallinfofont", 14)

    local bar_width = math.floor(width * 0.55)
    local progress = max_value > 0 and math.min(1.0, value / max_value) or 0

    local label_w = TextWidget:new{
        text = label,
        face = label_font,
        max_width = math.floor(width * 0.25),
    }

    local bar = ProgressWidget:new{
        width = bar_width,
        height = Screen:scaleBySize(8),
        percentage = progress,
        ticks = nil,
        last = nil,
        margin_h = 0,
        margin_v = 0,
    }

    local val_text = duration_str or tostring(value)
    local val_w = TextWidget:new{
        text = val_text,
        face = value_font,
        max_width = math.floor(width * 0.18),
    }

    return HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width * 0.25), h = row_h },
            label_w,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = bar_width, h = row_h },
            bar,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width * 0.20), h = row_h },
            val_w,
        },
    }
end

-- ─── Build the stats page (Menu widget) ────────────────────────────

--- Create and return a fully-configured stats page Menu.
-- Uses the same TitleBar / height infrastructure as history/collections.
-- @param createStatusRow  function from zen_shared (or nil)
-- @return Menu widget ready for injectStandaloneNavbar + UIManager:show
function StatsPage.create(createStatusRow)
    local stats = queryStats()
    -- Daily Breakdown is kept in data but hidden until enabled in settings
    local show_daily_breakdown = false

    -- ── Peak date label helpers ─────────────────────────────────────────────
    -- All timestamps are raw Unix UTC; os.date (without '!') uses local time.
    local function fmtPeakDay(ts)
        if not ts then return "" end
        return os.date("%b %d", ts):gsub(" 0(%d)", " %1")
    end

    local function fmtPeakWeek(ts)
        if not ts then return "" end
        local t = os.date("*t", ts)
        -- wday: 1=Sun, 2=Mon…7=Sat → compute Monday of that week
        local days_to_mon = (t.wday - 2) % 7
        local mon_ts = ts - days_to_mon * 86400
        local sun_ts = mon_ts + 6 * 86400
        local mon_str = os.date("%b %d", mon_ts):gsub(" 0(%d)", " %1")
        if os.date("%m", mon_ts) == os.date("%m", sun_ts) then
            return mon_str .. "\u{2013}" .. os.date("%d", sun_ts):gsub("^0", "")
        else
            return mon_str .. "\u{2013}" .. os.date("%b %d", sun_ts):gsub(" 0(%d)", " %1")
        end
    end

    local function fmtPeakMonth(ts)
        if not ts then return "" end
        return os.date("%b %Y", ts)
    end

    -- Hook TitleBar.new to create a minimal bar (same pattern as history.lua).
    -- Must happen BEFORE Menu:new so title_top_padding is computed without icons.
    local orig_tb_new = TitleBar.new
    TitleBar.new = function(cls, t)
        if type(t) == "table" then
            t.subtitle                 = nil
            t.subtitle_fullwidth       = nil
            t.left_icon                = nil
            t.left_icon_tap_callback   = nil
            t.left_icon_hold_callback  = nil
            t.right_icon               = nil
            t.right_icon_tap_callback  = nil
            t.right_icon_hold_callback = nil
            t.close_callback           = nil
            t.title_tap_callback       = nil
            t.title_hold_callback      = nil
            t.bottom_v_padding         = 0
            t.title                    = " "
        end
        return orig_tb_new(cls, t)
    end

    local menu = Menu:new{
        name = "stats",
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        no_title = false,
        title = " ",
        item_table = {},
    }

    TitleBar.new = orig_tb_new

    -- Prevent Menu from ever re-running item/pagination logic
    menu.updateItems = function() end

    -- Hide page-return arrow (same as history clean_nav)
    local page_arrow = menu.page_return_arrow
    if page_arrow then
        page_arrow:hide()
        page_arrow.show     = function() end
        page_arrow.showHide = function() end
        page_arrow.dimen    = Geom:new{ w = 0, h = 0 }
    end

    -- ── Clean nav: status row + remove icons (same as history/collections) ──
    local tb = menu.title_bar
    if tb and createStatusRow then
        local FileManager = require("apps/filemanager/filemanager")

        local function remove_from_overlap(group, widget)
            if not widget then return end
            for i = #group, 1, -1 do
                if rawequal(group[i], widget) then
                    table.remove(group, i)
                    return
                end
            end
        end
        remove_from_overlap(tb, tb.left_button)
        remove_from_overlap(tb, tb.right_button)
        tb.has_left_icon  = false
        tb.has_right_icon = false

        if tb.title_group and #tb.title_group >= 2 then
            tb.title_group[2] = createStatusRow(nil, FileManager.instance)
            tb.title_group:resetLayout()
        end

        -- Clock refresh callback (called by autoRefresh or self-contained timer)
        menu._zen_status_refresh = function()
            if tb.title_group and #tb.title_group >= 2 then
                tb.title_group[2] = createStatusRow(nil, FileManager.instance)
                tb.title_group:resetLayout()
                UIManager:setDirty(menu, "ui", tb.dimen)
            end
        end
    end

    -- ── Build stats content ──
    -- Compute available body height first so we can scale content to fit it
    -- without scrolling.
    local tb_h   = tb and tb:getSize().h or 0
    local body_h = (menu.inner_dimen and menu.inner_dimen.h or menu.dimen.h) - tb_h
    local page_w = menu.inner_dimen and menu.inner_dimen.w or Screen:getWidth()
    local h_padding = Screen:scaleBySize(16)
    local content_w = page_w - h_padding * 2

    -- buildContent(sc) builds the full stats layout, scaling every pixel
    -- dimension by `sc` (1.0 = natural size; <1.0 = shrink to fit body_h).
    -- Called once at sc=1.0 to measure, then again at the computed scale if
    -- the content is taller than body_h.
    local function buildContent(sc)
        local function sz(x) return math.floor(Screen:scaleBySize(x) * sc) end
        -- Scale font pt sizes; clamp so text stays legible
        local function fsz(base) return math.max(8, math.floor(base * sc)) end

        -- Wrapper around createCard that auto-scales font sizes
        local function card(opts)
            opts.value_size  = fsz(opts.value_size  or 28)
            opts.label_size  = fsz(opts.label_size  or 16)
            opts.header_size = fsz(opts.header_size or 16)
            return createCard(opts)
        end

        -- Build a row of cards with correct separators and a CenterContainer
        -- whose height derives from the tallest actual card (handles auto-grown
        -- cards, e.g. PR cards that carry a header row above the value).
        local function makeRow(cards)
            local row_h = 0
            for _, c in ipairs(cards) do
                local h = c:getSize().h
                if h > row_h then row_h = h end
            end
            local hg = HorizontalGroup:new{ align = "center" }
            for i, c in ipairs(cards) do
                hg[#hg + 1] = c
                if i < #cards then
                    hg[#hg + 1] = LineWidget:new{
                        dimen      = Geom:new{ w = 1, h = row_h },
                        background = Blitbuffer.COLOR_BLACK,
                    }
                end
            end
            return CenterContainer:new{
                dimen = Geom:new{ w = page_w, h = row_h + sz(8) },
                hg,
            }
        end

        -- Section header (height and font both scale with sc)
        local function hdr(text)
            return LeftContainer:new{
                dimen = Geom:new{ w = page_w, h = sz(28) },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = h_padding },
                    TextWidget:new{
                        text = text,
                        face = Font:getFace("smallinfofontbold", fsz(18)),
                    },
                },
            }
        end

        -- ── Today ────────────────────────────────────────────────────────────
        local c3_w = math.floor((content_w - sz(8)) / 3)
        local c3_h = sz(80)
        local today_row = makeRow{
            card{ width=c3_w, height=c3_h,
                  value=tostring(stats.today_pages), label=_("pages today") },
            card{ width=c3_w, height=c3_h,
                  value=formatTime(stats.today_duration), label=_("read today") },
            card{ width=c3_w, height=c3_h,
                  value=tostring(stats.streak), label=_("day streak") },
        }

        -- ── This Week ────────────────────────────────────────────────────────
        local c4_w = math.floor((content_w - sz(8)) / 4)
        local c4_h = sz(80)
        local avg_pages = stats.week_pages    > 0 and math.floor(stats.week_pages    / 7) or 0
        local avg_time  = stats.week_duration > 0 and math.floor(stats.week_duration / 7) or 0
        local week_row = makeRow{
            card{ width=c4_w, height=c4_h, value_size=24,
                  value=tostring(stats.week_pages),        label=_("pages") },
            card{ width=c4_w, height=c4_h, value_size=24,
                  value=formatTime(stats.week_duration),   label=_("total time") },
            card{ width=c4_w, height=c4_h, value_size=24,
                  value=tostring(avg_pages),               label=_("avg pages/day") },
            card{ width=c4_w, height=c4_h, value_size=24,
                  value=formatTime(avg_time),              label=_("avg time/day") },
        }

        -- ── All Time ─────────────────────────────────────────────────────────
        local alltime_row = makeRow{
            card{ width=c4_w, height=c4_h, value_size=24,
                  value=formatLongTime(stats.lifetime_read_time), label=_("total read time") },
            card{ width=c4_w, height=c4_h, value_size=24,
                  value=tostring(stats.lifetime_pages),           label=_("total pages read") },
            card{ width=c4_w, height=c4_h, value_size=24,
                  value=tostring(stats.books_read),               label=_("books read") },
            card{ width=c4_w, height=c4_h, value_size=24,
                  value=formatTime(stats.avg_time_per_book),      label=_("avg time/book") },
        }

        -- ── Personal Records ─────────────────────────────────────────────────
        local records_row = makeRow{
            card{ width=c3_w, height=c4_h, value_size=24,
                  header=_("best day"),   value=formatTime(stats.peak_day_duration),
                  label=fmtPeakDay(stats.peak_day_ts) },
            card{ width=c3_w, height=c4_h, value_size=24,
                  header=_("best week"),  value=formatTime(stats.peak_week_duration),
                  label=fmtPeakWeek(stats.peak_week_ts) },
            card{ width=c3_w, height=c4_h, value_size=24,
                  header=_("best month"), value=formatLongTime(stats.peak_month_duration),
                  label=fmtPeakMonth(stats.peak_month_ts) },
        }

        -- ── Library ──────────────────────────────────────────────────────────
        local c2_h = sz(60)
        local books_row = makeRow{
            card{ width=c3_w, height=c2_h,
                  value=tostring(stats.total_books),    label=_("total books") },
            card{ width=c3_w, height=c2_h,
                  value=tostring(stats.books_reading),  label=_("Reading") },
            card{ width=c3_w, height=c2_h,
                  value=tostring(stats.books_finished), label=_("finished") },
        }

        -- ── Assemble ─────────────────────────────────────────────────────────
        local content = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = sz(10) },
            hdr(_("Today")),
            VerticalSpan:new{ width = sz(4) },
            today_row,
            VerticalSpan:new{ width = sz(12) },
            hdr(_("This Week")),
            VerticalSpan:new{ width = sz(4) },
            week_row,
            VerticalSpan:new{ width = sz(12) },
            hdr(_("All Time")),
            VerticalSpan:new{ width = sz(4) },
            alltime_row,
            VerticalSpan:new{ width = sz(12) },
            hdr(_("Personal Records")),
            VerticalSpan:new{ width = sz(4) },
            records_row,
            VerticalSpan:new{ width = sz(12) },
            hdr(_("Library")),
            VerticalSpan:new{ width = sz(4) },
            books_row,
        }

        if show_daily_breakdown then
            -- Build daily chart
            local chart_rows_inner = VerticalGroup:new{ align = "left" }
            local daily_lookup = {}
            local max_day_duration = 1
            for _, day_data in ipairs(stats.week_daily) do
                daily_lookup[day_data.date] = day_data
                if day_data.duration > max_day_duration then
                    max_day_duration = day_data.duration
                end
            end
            local one_day_sec = 86400
            for i = 6, 0, -1 do
                local day_ts    = os.time() - i * one_day_sec
                local day_str   = os.date("%Y-%m-%d", day_ts)
                local day_label = os.date("%a", day_ts)
                local day_data  = daily_lookup[day_str]
                local dur       = day_data and day_data.duration or 0
                local pgs       = day_data and day_data.pages or 0
                table.insert(chart_rows_inner, createProgressRow(
                    day_label, dur, max_day_duration, content_w,
                    formatTime(dur) .. " · " .. tostring(pgs) .. "p"
                ))
            end
            content[#content + 1] = VerticalSpan:new{ width = sz(12) }
            content[#content + 1] = hdr(_("Daily Breakdown"))
            content[#content + 1] = VerticalSpan:new{ width = sz(4) }
            content[#content + 1] = CenterContainer:new{
                dimen = Geom:new{ w = page_w, h = chart_rows_inner:getSize().h },
                chart_rows_inner,
            }
            content:resetLayout()
        end

        return content
    end

    -- Scale content to fit body_h.  Cards have fixed chrome (padding/margin)
    -- that doesn't scale, so a single pass may still overflow after auto-grow.
    -- Iterate up to 3 times to converge.
    local sc = 1.0
    local content = buildContent(sc)
    local content_h = content:getSize().h
    for _ = 1, 3 do
        if content_h <= body_h then break end
        sc = sc * body_h / content_h
        content = buildContent(sc)
        content_h = content:getSize().h
    end
    -- Fill any remaining gap so the item_group occupies the full body
    if content_h < body_h then
        content[#content + 1] = VerticalSpan:new{ width = body_h - content_h }
        content:resetLayout()
    end

    -- Replace Menu's item_group with our stats dashboard
    while #menu.item_group > 0 do
        table.remove(menu.item_group)
    end
    table.insert(menu.item_group, content)
    menu.item_group:resetLayout()
    if menu.content_group then
        menu.content_group:resetLayout()
    end

    -- Collapse pagination footer so it doesn't take space
    if menu.page_info then
        while #menu.page_info > 0 do
            table.remove(menu.page_info)
        end
        menu.page_info:resetLayout()
    end

    -- ── Minute-aligned clock refresh (self-cancels when page leaves stack) ──
    if createStatusRow then
        local function refreshClock()
            local stack = UIManager._window_stack
            local alive = false
            if stack then
                for i = #stack, 1, -1 do
                    if rawequal(stack[i].widget, menu) then
                        alive = true
                        break
                    end
                end
            end
            if not alive then
                menu._zen_clock_timer = nil
                return
            end
            if menu._zen_status_refresh then
                menu._zen_status_refresh()
            end
            local t = os.date("*t")
            UIManager:scheduleIn(60 - t.sec, refreshClock)
        end
        menu._zen_clock_timer = refreshClock
        local t = os.date("*t")
        UIManager:scheduleIn(60 - t.sec, refreshClock)
    end

    -- ── Close handler: clean up timer ──
    menu.close_callback = function()
        if menu._zen_clock_timer then
            UIManager:unschedule(menu._zen_clock_timer)
            menu._zen_clock_timer = nil
        end
        UIManager:close(menu)
    end

    return menu
end

return StatsPage
