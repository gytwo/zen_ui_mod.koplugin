-- zen_ui: page_browser patch
-- Intercepts swipe-north from the bottom 14% of the reader screen and
-- opens KOReader's native PageBrowserWidget.

local function apply_page_browser()

    -- -----------------------------------------------------------------------
    -- Dependencies
    -- -----------------------------------------------------------------------
    local UIManager = require("ui/uimanager")
    local Event     = require("ui/event")

    -- -----------------------------------------------------------------------
    -- Feature guard
    -- -----------------------------------------------------------------------
    -- Capture the plugin reference NOW (while __ZEN_UI_PLUGIN is set by
    -- run_patch). After apply_page_browser() returns the global is cleared,
    -- so reading it inside gesture handlers would always return nil.
    local _plugin_ref = rawget(_G, "__ZEN_UI_PLUGIN")
    local function is_enabled()
        local features = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.features
        return type(features) == "table" and features.page_browser == true
    end

    -- -----------------------------------------------------------------------
    -- Zen UI customisations applied once to PageBrowserWidget
    -- -----------------------------------------------------------------------
    local _zen_pbw_patched = false

    local function zen_patch_page_browser_widget()
        if _zen_pbw_patched then return end
        _zen_pbw_patched = true

        local PageBrowserWidget = require("ui/widget/pagebrowserwidget")
        local Device     = require("device")
        local Font       = require("ui/font")
        local Geom       = require("ui/geometry")
        local IconButton = require("ui/widget/iconbutton")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan  = require("ui/widget/horizontalspan")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local TextWidget      = require("ui/widget/textwidget")
        local FrameContainer  = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local OverlapGroup    = require("ui/widget/overlapgroup")
        local Blitbuffer      = require("ffi/blitbuffer")
        local Size            = require("ui/size")
        local Screen          = Device.screen
        local ZenSlider       = require("common/zen_slider")

        -- ----------------------------------------------------------------
        -- 1. Patch init: blank title, X to left, 3 icons on right
        -- ----------------------------------------------------------------
        local _orig_init = PageBrowserWidget.init
        PageBrowserWidget.init = function(self)
            _orig_init(self)
            -- Block slider input until the opening swipe gesture completes so
            -- the northward swipe that opens us doesn't immediately move the
            -- slider (which appears right where the finger lifted).
            self._zen_slider_locked = true
            UIManager:scheduleIn(0.35, function()
                self._zen_slider_locked = false
            end)

            -- Blank the title text (no "Page browser" label)
            self.title_bar:setTitle("")

            local btn_sz  = Screen:scaleBySize(32)
            local btn_pad = self.title_bar.button_padding or Screen:scaleBySize(11)

            -- Remove the hamburger (left_button)
            if self.title_bar.left_button then
                for i = #self.title_bar, 1, -1 do
                    if self.title_bar[i] == self.title_bar.left_button then
                        table.remove(self.title_bar, i)
                        break
                    end
                end
                self.title_bar.left_button   = nil
                self.title_bar.has_left_icon = false
            end

            -- Move the close button (right_button) to the LEFT side.
            -- Extract the close callback before removing it.
            local close_cb, close_hold_cb
            if self.title_bar.right_button then
                close_cb      = self.title_bar.right_button.callback
                close_hold_cb = self.title_bar.right_button.hold_callback
                for i = #self.title_bar, 1, -1 do
                    if self.title_bar[i] == self.title_bar.right_button then
                        table.remove(self.title_bar, i)
                        break
                    end
                end
                self.title_bar.right_button   = nil
                self.title_bar.has_right_icon = false
            end

            -- Re-add close at left (overlap_align="left", tap zone extends right)
            table.insert(self.title_bar, IconButton:new{
                icon           = "close",
                width          = btn_sz,
                height         = btn_sz,
                padding        = btn_pad,
                padding_right  = 2 * btn_sz,
                padding_bottom = btn_sz,
                overlap_align  = "left",
                allow_flash    = false,
                show_parent    = self,
                callback       = close_cb or function() self:onClose() end,
                hold_callback  = close_hold_cb,
            })

            -- Add 3 icon buttons on the RIGHT side (font, toc, search)
            local slot_w  = btn_sz + btn_pad * 2
            local right_x = Screen:getWidth()

            local function make_right_btn(icon, x_pos)
                return IconButton:new{
                    icon           = icon,
                    width          = btn_sz,
                    height         = btn_sz,
                    padding        = btn_pad,
                    padding_bottom = btn_sz,
                    overlap_offset = { x_pos, 0 },
                    overlap_align  = "left",
                    allow_flash    = true,
                    show_parent    = self,
                    callback       = function() end,
                }
            end

            -- Search at far right, TOC next, Font leftmost of the three
            table.insert(self.title_bar, make_right_btn("appbar.search",     right_x - slot_w))
            table.insert(self.title_bar, make_right_btn("appbar.navigation", right_x - slot_w * 2))
            table.insert(self.title_bar, make_right_btn("appbar.textsize",   right_x - slot_w * 3))
        end

        -- ----------------------------------------------------------------
        -- 2. Patch updateLayout: swap BookMapRow ribbon for ZenSlider+labels
        -- ----------------------------------------------------------------
        local _orig_updateLayout = PageBrowserWidget.updateLayout

        -- Pre-measure panel height once so we can inject it as row_height
        -- before _orig_updateLayout runs. This means the native code computes
        -- grid_height = screen_h - title_h - panel_h, sizes thumbnails to fit
        -- that exact space, and positions them with correct offsets. No
        -- post-hoc shrinking = no thumbnail overlap.
        local zen_btn_sz = Screen:scaleBySize(28)
        local zen_btn_pad = Screen:scaleBySize(6)

        local function zen_measure_panel_h()
            -- Measure slider height from ZenSlider formula (knob_radius default)
            local knob_r   = Screen:scaleBySize(16.5)
            local slider_h = knob_r * 2 + Screen:scaleBySize(6)
            -- Measure label height from a live TextWidget
            local tw = TextWidget:new{ text = "Wg",
                                       face = Font:getFace("cfont", 14),
                                       padding = 0 }
            local lh = tw:getSize().h
            tw:free()
            local btn_h = zen_btn_sz + zen_btn_pad * 2
            -- 5× pad(2) + 2× label + 1× slider + 1× icon row
            return 5 * Screen:scaleBySize(2) + 2 * lh + slider_h + btn_h
        end

        PageBrowserWidget.updateLayout = function(self)
            -- Free any panel we built in a previous updateLayout call.
            if self._zen_row_panel then
                if self._zen_row_panel.free then self._zen_row_panel:free() end
                self._zen_row_panel = nil
            end

            -- Inject our required panel height as row_height BEFORE calling
            -- _orig_updateLayout. The native code uses self.row_height if it
            -- is already set — but it recomputes it unconditionally, so we
            -- must monkey-patch span_height temporarily to coerce the result.
            -- Simpler: just call _orig_updateLayout, then rebuild the grid
            -- from scratch with the correct height. Instead we use the cleanest
            -- approach: override nb_toc_spans to 0 via a temporary shim so
            -- the native row_height formula yields the minimum, then fix up.
            --
            -- Actually the cleanest approach: run _orig_updateLayout normally,
            -- then rebuild self.grid (OverlapGroup) with the corrected height.
            -- The native code rebuilds self.grid from scratch inside
            -- _orig_updateLayout, so we just need to redo that part.
            local zen_panel_h = zen_measure_panel_h()

            -- The native row_height formula is:
            --   ceil((nb_toc_spans + page_slots_height_ratio + 1) * span_height + 2*border)
            -- where page_slots_height_ratio = 0.2 (stats off, toc > 0) or 1 (otherwise).
            -- On books with many TOC levels (e.g. nb_toc_spans = 10) the naive
            -- approach of inflating span_height to fit zen_panel_h at factor=2
            -- blows row_height up 5-6x.  Pre-compute nb_toc_spans from settings
            -- (same path as native updateLayout) to solve for the exact span_height
            -- that targets row_height = zen_panel_h + top_pad.
            local top_pad    = Screen:scaleBySize(6)
            local nb_toc_pre
            if self.ui.handmade and self.ui.handmade:isHandmadeTocEnabled() then
                nb_toc_pre = self.ui.doc_settings:readSetting("page_browser_toc_depth_handmade_toc") or self.max_toc_depth
            else
                nb_toc_pre = self.ui.doc_settings:readSetting("page_browser_toc_depth") or self.max_toc_depth
            end
            nb_toc_pre = nb_toc_pre or 0
            local stats_on = self.ui.statistics and self.ui.statistics:isEnabled()
            local psr      = (not stats_on and nb_toc_pre > 0) and 0.2 or 1
            local BookMapRow = require("ui/widget/bookmapwidget").BookMapRow
            local border2    = 2 * BookMapRow.pages_frame_border
            local factor     = nb_toc_pre + psr + 1
            -- Solve: factor * span_height + border2 = zen_panel_h + top_pad
            local target_span = math.max(1, math.floor((zen_panel_h + top_pad - border2) / factor))
            local orig_span_h = self.span_height
            self.span_height  = target_span

            _orig_updateLayout(self)

            -- Restore span_height so the detached BookMapRow is self-consistent.
            self.span_height = orig_span_h

            -- Suppress native left-side page number widgets: we draw our own
            -- badges in paintTo() instead.  showTile() checks show_pagenum on
            -- the FrameContainer before inserting a TextBoxWidget; clearing it
            -- here stops future insertions.  Then remove any already inserted
            -- during the update() call that _orig_updateLayout makes internally.
            for i = 1, (self.nb_grid_items or 0) do
                if self.grid[i] then
                    self.grid[i].show_pagenum = false
                end
            end
            for i = #self.grid, 1, -1 do
                if self.grid[i] and self.grid[i].is_page_num_widget then
                    if self.grid[i].free then self.grid[i]:free() end
                    table.remove(self.grid, i)
                end
            end

            -- After _orig_updateLayout:
            --  self.row_height  ≈ zen_panel_h + top_pad
            --  self.grid_height  = screen_h - title_h - zen_panel_h - top_pad
            --  self.grid         = OverlapGroup sized to grid_height (correct)
            --  self.row          = CenterContainer (kept detached)

            local nb_pages  = self.nb_pages  or 1
            local cur_page  = self.focus_page or self.cur_page or 1
            local grid_w    = self.grid_width or Screen:getWidth()

            -- Derive the thumbnail-span width from the actual layout, then use
            -- roughly half of that for the slider so it sits as a short centred
            -- track rather than spanning edge-to-edge.
            local outer_margin = (self.grid[1] and self.grid[1].overlap_offset
                                  and self.grid[1].overlap_offset[1]) or 0
            local thumb_span = math.max(1, grid_w - 2 * outer_margin)
            local slider_w   = math.floor(thumb_span * 0.95)

            local function chapter_title(pg)
                if not self.ui or not self.ui.toc then return "" end
                return self.ui.toc:getTocTitleByPage(pg) or ""
            end

            -- Center page: the thumbnail in the middle of the grid.
            -- focus_page sits at index (focus_page_shift + 1) in the grid.
            -- Center index = ceil(nb_grid_items / 2).
            -- center_page = focus_page - focus_page_shift + ceil(nb_grid_items/2) - 1
            local function center_page()
                local fp    = self.focus_page or cur_page
                local shift = self.focus_page_shift or 0
                local items = self.nb_grid_items or 1
                return math.max(1, math.min(nb_pages,
                    fp - shift + math.ceil(items / 2) - 1))
            end

            local label_face = Font:getFace("cfont", 14)
            local pad_v      = Screen:scaleBySize(2)

            local cp = center_page()
            local chap_label = TextWidget:new{
                text      = chapter_title(cp),
                face      = label_face,
                max_width = slider_w,
                padding   = 0,
            }
            local page_label = TextWidget:new{
                text      = string.format("Page %d / %d", cp, nb_pages),
                face      = label_face,
                max_width = slider_w,
                padding   = 0,
            }
            local zen_slider = ZenSlider:new{
                width     = slider_w,
                value     = cp,
                value_min = 1,
                value_max = math.max(nb_pages, 1),
                on_change = function(v)
                    if self:updateFocusPage(v, false) then
                        self:update()
                    end
                end,
            }

            self._zen_slider     = zen_slider
            self._zen_page_label = page_label
            self._zen_chap_label = chap_label

            -- Two view-mode toggle buttons shown below the page label.
            -- SVG icons will replace these placeholders when available.
            local btn_view = IconButton:new{
                icon           = "appbar.pageview",
                width          = zen_btn_sz,
                height         = zen_btn_sz,
                padding        = zen_btn_pad,
                allow_flash    = true,
                show_parent    = self,
                callback       = function() end,
            }
            local btn_grid = IconButton:new{
                icon           = "column.three",
                width          = zen_btn_sz,
                height         = zen_btn_sz,
                padding        = zen_btn_pad,
                allow_flash    = true,
                show_parent    = self,
                callback       = function() end,
            }
            local btn_gap  = Screen:scaleBySize(16)
            local btn_row  = HorizontalGroup:new{
                align = "center",
                btn_view,
                HorizontalSpan:new{ width = btn_gap },
                btn_grid,
            }

            -- Panel spans full grid width, pinned to the absolute bottom of
            -- the screen via OverlapGroup offset (set below).  Height is the
            -- measured content height, not the (larger) native row_height.
            local panel = FrameContainer:new{
                width      = grid_w,
                height     = zen_panel_h,
                padding    = 0,
                margin     = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                VerticalGroup:new{
                    align = "center",
                    VerticalSpan:new{ width = pad_v },
                    CenterContainer:new{
                        dimen = Geom:new{ w = grid_w, h = chap_label:getSize().h },
                        chap_label,
                    },
                    VerticalSpan:new{ width = pad_v },
                    CenterContainer:new{
                        dimen = Geom:new{ w = grid_w, h = zen_slider:getSize().h },
                        zen_slider,
                    },
                    VerticalSpan:new{ width = pad_v },
                    CenterContainer:new{
                        dimen = Geom:new{ w = grid_w, h = page_label:getSize().h },
                        page_label,
                    },
                    VerticalSpan:new{ width = pad_v },
                    CenterContainer:new{
                        dimen = Geom:new{ w = grid_w, h = btn_row:getSize().h },
                        btn_row,
                    },
                    VerticalSpan:new{ width = pad_v },
                },
            }
            -- Pin panel to absolute screen bottom; grid gets the full space above.
            panel.overlap_offset = { 0, self.dimen.h - zen_panel_h }
            self._zen_row_panel = panel

            -- Use an OverlapGroup so the panel hovers over the bottom of the
            -- screen independently of the grid's natural height.  The
            -- VerticalGroup (title + small gap + grid) occupies the upper
            -- portion; the panel is drawn over the dead space below the grid.
            self[1] = FrameContainer:new{
                width      = self.dimen.w,
                height     = self.dimen.h,
                padding    = 0,
                margin     = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                OverlapGroup:new{
                    dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h },
                    VerticalGroup:new{
                        align = "center",
                        self.title_bar,
                        VerticalSpan:new{ width = top_pad },
                        self.grid,
                    },
                    panel,
                }
            }
        end

        -- ----------------------------------------------------------------
        -- 3. Update slider/labels whenever the focus page changes
        -- ----------------------------------------------------------------
        local _orig_update = PageBrowserWidget.update
        PageBrowserWidget.update = function(self)
            -- On the very first call (focus_page is nil, init → updateLayout → update),
            -- pre-initialise focus_page from cur_page with clamping so the grid
            -- never displays blank leading/trailing slots.  Subsequent calls
            -- (slider drag, scroll) already carry a valid focus_page and don't
            -- need adjustment.
            local shift = self.focus_page_shift
            local items = self.nb_grid_items
            local total = self.nb_pages
            if not self.focus_page and shift and items and total and total >= items then
                local fp     = self.cur_page or 1
                local min_fp = shift + 1
                local max_fp = math.max(min_fp, total - items + 1 + shift)
                self.focus_page = math.max(min_fp, math.min(max_fp, fp))
            end

            -- Block showTile() from re-adding native page number widgets.
            for i = 1, (self.nb_grid_items or 0) do
                if self.grid[i] then self.grid[i].show_pagenum = false end
            end

            -- _orig_update writes BookMapRow into self.row (detached CenterContainer)
            _orig_update(self)

            -- Clean up any page num widgets that slipped through (e.g. async tiles).
            for i = #self.grid, 1, -1 do
                if self.grid[i] and self.grid[i].is_page_num_widget then
                    if self.grid[i].free then self.grid[i]:free() end
                    table.remove(self.grid, i)
                end
            end

            -- Display info for the center thumbnail, not the focus thumbnail.
            local fp    = self.focus_page or self.cur_page or 1
            local sh    = self.focus_page_shift or 0
            local it    = self.nb_grid_items or 1
            local np    = self.nb_pages or 1
            local cp    = math.max(1, math.min(np,
                              fp - sh + math.ceil(it / 2) - 1))

            if self._zen_slider then
                self._zen_slider:setValue(cp)
            end
            if self._zen_page_label then
                self._zen_page_label:setText(
                    string.format("Page %d / %d", cp, np))
            end
            if self._zen_chap_label then
                local title = ""
                if self.ui and self.ui.toc then
                    title = self.ui.toc:getTocTitleByPage(cp) or ""
                end
                self._zen_chap_label:setText(title)
            end
        end

        -- ----------------------------------------------------------------
        -- 4. paintTo: suppress the viewfinder overlay; page-number badges
        -- ----------------------------------------------------------------
        PageBrowserWidget.paintTo = function(self, bb, x, y)
            local InputContainer = require("ui/widget/container/inputcontainer")
            InputContainer.paintTo(self, bb, x, y)
            -- viewfinder border and row-lines intentionally omitted

            if not (self.grid and self.focus_page) then return end

            local fp    = self.focus_page
            local shift = self.focus_page_shift or 0
            local np    = self.nb_pages or 1

            -- Grid top-left in blitbuffer coordinate space.
            -- OverlapGroup child 1 = VerticalGroup: title_bar → span(top_pad) → grid.
            local title_h = (self.title_bar and self.title_bar:getSize().h) or 0
            local gx      = x
            local gy      = y + title_h + Screen:scaleBySize(6) -- top_pad

            local badge_face = Font:getFace("cfont", 11)
            local ph         = Screen:scaleBySize(4)   -- badge horiz padding
            local pv         = Screen:scaleBySize(2)   -- badge vert  padding
            local bg_color   = Blitbuffer.gray(0x33)   -- dark badge fill
            local fg_color   = Blitbuffer.gray(0xFF)   -- white badge text
            local gap_bot    = Screen:scaleBySize(6)   -- badge offset from thumb bottom

            -- paintPill: horizontal capsule (rounded left/right, flat top/bottom).
            -- Ported from browser_page_count.lua.
            local function paintPill(bx, by, bw, bh, color)
                local r = bh / 2
                for row = 0, bh - 1 do
                    local dy = math.abs(row + 0.5 - r)
                    local dx = math.sqrt(math.max(0, r * r - dy * dy))
                    local x0 = math.ceil(bx + r - dx)
                    local x1 = math.floor(bx + bw - r + dx)
                    local w  = x1 - x0
                    if w > 0 then bb:paintRect(x0, by + row, w, 1, color) end
                end
            end

            -- Only iterate the real thumbnail slots (1..nb_grid_items).
            local n = self.nb_grid_items or 0
            for i = 1, n do
                local item = self.grid[i]
                if item and item.overlap_offset then
                    local page_num = fp - shift + (i - 1)
                    if page_num >= 1 and page_num <= np then
                        local ox = item.overlap_offset[1]
                        local oy = item.overlap_offset[2]
                        local sz = item:getSize()

                        local label = TextWidget:new{
                            text    = tostring(page_num),
                            face    = badge_face,
                            fgcolor = fg_color,
                            padding = 0,
                        }
                        local lsz = label:getSize()
                        local bh  = lsz.h + 2 * pv
                        local bw  = math.max(lsz.w + 2 * ph, bh)  -- never narrower than a circle
                        local bx  = gx + ox + math.floor((sz.w - bw) / 2)
                        local by  = gy + oy + sz.h - bh - gap_bot

                        paintPill(bx, by, bw, bh, bg_color)
                        label:paintTo(bb,
                            bx + math.floor((bw - lsz.w) / 2),
                            by + math.floor((bh - lsz.h) / 2))
                        label:free()
                    end
                end
            end
        end

        -- ----------------------------------------------------------------
        -- 5. Slider tap/pan gesture handling
        -- ----------------------------------------------------------------
        local _orig_onTap = PageBrowserWidget.onTap
        PageBrowserWidget.onTap = function(self, arg, ges)
            if self._zen_slider and self._zen_slider:hitTest(ges.pos) then
                self._zen_slider:applyPosition(ges.pos.x)
                return true
            end
            return _orig_onTap(self, arg, ges)
        end

        local _orig_onPan = PageBrowserWidget.onPan
        PageBrowserWidget.onPan = function(self, arg, ges)
            if self._zen_slider and not self._zen_slider_locked then
                -- Only handle if the pan started on (or near) the slider row
                local sp = ges.startpos or ges.pos
                if sp and self._zen_slider:hitTest(sp) then
                    self._zen_slider:applyPosition(ges.pos.x)
                    return true
                end
            end
            -- do NOT call _orig_onPan — it only handled mousewheel scrolling
            return true
        end

        -- ----------------------------------------------------------------
        -- 6. Gesture lockdown: only horizontal swipe (page prev/next)
        -- ----------------------------------------------------------------
        PageBrowserWidget.onSwipe = function(self, _arg, ges)
            local direction = ges.direction
            if direction == "west" then
                self:onScrollPageDown()
                return true
            elseif direction == "east" then
                self:onScrollPageUp()
                return true
            elseif direction == "north" or direction == "south" then
                -- swallow vertical swipes — no row resize, no scroll
                return true
            end
            return true
        end

        PageBrowserWidget.onPinch  = function() return true end
        PageBrowserWidget.onSpread = function() return true end
        PageBrowserWidget.onMultiSwipe = function(self)
            self:onClose()
            return true
        end
    end

    -- -----------------------------------------------------------------------
    -- Open KOReader's native PageBrowserWidget (with Zen UI tweaks)
    -- -----------------------------------------------------------------------
    local function open_page_browser(ui)
        local PageBrowserWidget = require("ui/widget/pagebrowserwidget")
        zen_patch_page_browser_widget()
        UIManager:show(PageBrowserWidget:new{ ui = ui })
    end

    -- Patch ReaderMenu.initGesListener to register the swipe-up zone
    -- -----------------------------------------------------------------------
    local ReaderMenu = require("apps/reader/modules/readermenu")
    local _orig_initGesListener = ReaderMenu.initGesListener

    local function register_page_browser_zone(ui)
        ui:registerTouchZones({
            {
                id          = "zen_page_browser_reader",
                ges         = "swipe",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0.86, ratio_w = 1, ratio_h = 0.14,
                },
                -- Override the config-menu and page-turn swipe zones so our
                -- north-swipe wins.  We deliberately do NOT override the tap
                -- zones (readerconfigmenu_tap etc.) — those cause unintended
                -- pan/brightness-slider interference via the zone sort order.
                overrides = {
                    "readerconfigmenu_swipe",
                    "readerconfigmenu_ext_swipe",
                    "paging_swipe",
                    "rolling_swipe",
                },
                handler = function(ges)
                    if not is_enabled() then return end
                    if ges.direction == "north" then
                        open_page_browser(ui)
                        ui:handleEvent(Event:new("HandledAsSwipe"))
                        return true
                    end
                end,
            },
        })
    end

    ReaderMenu.initGesListener = function(self_rm)
        if _orig_initGesListener then
            _orig_initGesListener(self_rm)
        end
        register_page_browser_zone(self_rm.ui)
    end

    -- onReaderReady is aliased to initGesListener in KOReader; keep in sync
    ReaderMenu.onReaderReady = ReaderMenu.initGesListener

    -- If a book is already open when this patch is applied (feature toggled
    -- at runtime), register the zone immediately.
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_rui and ReaderUI and ReaderUI.instance then
        pcall(register_page_browser_zone, ReaderUI.instance)
    end

    -- -----------------------------------------------------------------------
    -- Primary intercept: patch ReaderConfig.onSwipeShowConfigMenu directly.
    -- More reliable than zone-override ordering since it does not depend on
    -- the dep-graph re-serialisation happening in the right order.
    -- -----------------------------------------------------------------------
    local ok_rc, ReaderConfig = pcall(require, "apps/reader/modules/readerconfig")
    if ok_rc and ReaderConfig then
        local _orig_onSwipeShowConfigMenu = ReaderConfig.onSwipeShowConfigMenu
        ReaderConfig.onSwipeShowConfigMenu = function(self_rc, ges)
            if is_enabled() and ges.direction == "north" then
                open_page_browser(self_rc.ui)
                self_rc.ui:handleEvent(Event:new("HandledAsSwipe"))
                return true
            end
            if _orig_onSwipeShowConfigMenu then
                return _orig_onSwipeShowConfigMenu(self_rc, ges)
            end
        end
    end

end -- apply_page_browser

return apply_page_browser
