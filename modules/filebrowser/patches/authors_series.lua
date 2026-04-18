local logger = require("logger")

local M = {}

-- One-time patch guards
local _mosaic_item_patched = false
local _list_item_patched   = false

-- Active group view menus (so we can refresh them)
local _authors_menu = nil
local _series_menu  = nil

-- Set during apply (called at init while __ZEN_UI_PLUGIN is set)
local _zen_shared  = nil
local _zen_plugin  = nil  -- captured at init; __ZEN_UI_PLUGIN is cleared after init

-------------------------------------------------------------------------------
-- Utility: walk upvalue chain to find a named upvalue
-------------------------------------------------------------------------------
local function get_upvalue(fn, name)
    if type(fn) ~= "function" then return nil end
    for i = 1, 64 do
        local upname, value = debug.getupvalue(fn, i)
        if not upname then break end
        if upname == name then return value end
    end
end

-------------------------------------------------------------------------------
-- setup_display_mode: mirror fi CoverMenu/MosaicMenu/ListMenu onto menu
-- Returns "mosaic", "list", or "classic"
-------------------------------------------------------------------------------
local function setup_display_mode(menu, is_group_view)
    local BookInfoManager = require("bookinfomanager")
    local display_mode = BookInfoManager:getSetting("filemanager_display_mode")
    if is_group_view then
        menu._zen_group_view = true
    end

    if not display_mode then return "classic" end

    local ok_cm, CoverMenu = pcall(require, "covermenu")
    if not ok_cm then return false end

    local display_mode_type = display_mode:gsub("_.*", "")  -- "mosaic" or "list"

    menu.updateItems   = CoverMenu.updateItems
    menu.onCloseWidget = CoverMenu.onCloseWidget

    menu.nb_cols_portrait  = BookInfoManager:getSetting("nb_cols_portrait")  or 3
    menu.nb_rows_portrait  = BookInfoManager:getSetting("nb_rows_portrait")  or 3
    menu.nb_cols_landscape = BookInfoManager:getSetting("nb_cols_landscape") or 4
    menu.nb_rows_landscape = BookInfoManager:getSetting("nb_rows_landscape") or 2
    menu.files_per_page    = BookInfoManager:getSetting("files_per_page")
    menu.display_mode_type = display_mode_type

    if display_mode_type == "mosaic" then
        local ok_mm, MosaicMenu = pcall(require, "mosaicmenu")
        if not ok_mm then return false end
        menu._recalculateDimen    = MosaicMenu._recalculateDimen
        menu._updateItemsBuildUI  = MosaicMenu._updateItemsBuildUI
        menu._do_cover_images     = display_mode ~= "mosaic_text"
        menu._do_center_partial_rows = false
        menu._do_hint_opened      = false
    elseif display_mode_type == "list" then
        local ok_lm, ListMenu = pcall(require, "listmenu")
        if not ok_lm then return false end
        menu._recalculateDimen    = ListMenu._recalculateDimen
        menu._updateItemsBuildUI  = ListMenu._updateItemsBuildUI
        menu._do_cover_images     = display_mode ~= "list_only_meta"
        menu._do_filename_only    = display_mode == "list_image_filename"
    end

    -- Provide proper getBookInfo for badge support
    if not menu.getBookInfo then
        if is_group_view then
            menu.getBookInfo = function() return {} end
        else
            -- Return reading status (percent_finished, status, been_opened) from sidecar.
            -- Called as menu.getBookInfo(filepath) — dot syntax, ONE arg only.
            menu.getBookInfo = function(file_path)
                if not file_path then return {} end
                local ok_ds, DocSettings = pcall(require, "docsettings")
                if not ok_ds then return {} end
                if not DocSettings:hasSidecarFile(file_path) then return {} end
                local ok2, doc = pcall(DocSettings.open, DocSettings, file_path)
                if not ok2 or not doc then return {} end
                local summary = doc:readSetting("summary")
                return {
                    been_opened      = true,
                    percent_finished = doc:readSetting("percent_finished"),
                    status           = summary and summary.status,
                }
            end
        end
    end
    if not menu.resetBookInfoCache then
        menu.resetBookInfoCache = function() end
    end

    return display_mode_type
end

-------------------------------------------------------------------------------
-- patch_mosaic_item: one-time install of MosaicMenuItem.update override
-- Uses self.entry._zen_files (list of absolute file paths)
-------------------------------------------------------------------------------
local function patch_mosaic_item()
    if _mosaic_item_patched then return end

    local ok, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok then return end
    local MosaicMenuItem = get_upvalue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem then return end
    _mosaic_item_patched = true

    local BookInfoManager = require("bookinfomanager")

    -- Keep underlines hidden on focus (same guard as collections.lua)
    local Blitbuffer_uc = require("ffi/blitbuffer")
    if not MosaicMenuItem._zen_as_focus_patched then
        MosaicMenuItem._zen_as_focus_patched = true
        local orig_onFocus = MosaicMenuItem.onFocus
        function MosaicMenuItem:onFocus()
            if self._underline_container then
                self._underline_container.color = Blitbuffer_uc.COLOR_WHITE
            end
            if orig_onFocus then return orig_onFocus(self) end
            return true
        end
    end

    local orig_update = MosaicMenuItem.update
    function MosaicMenuItem:update(...)
        if not (self.menu and self.menu._zen_group_view
                and self.entry and self.entry._zen_files) then
            return orig_update(self, ...)
        end

        self.is_directory = true

        local files      = self.entry._zen_files
        local book_count = #files
        local covers     = {}
        for i = 1, math.min(book_count, 4) do
            local bi = BookInfoManager:getBookInfo(files[i], true)
            if bi and bi.cover_bb and bi.has_cover
                    and bi.cover_fetched and not bi.ignore_cover then
                table.insert(covers, {
                    data = bi.cover_bb:copy(),
                    w    = bi.cover_w,
                    h    = bi.cover_h,
                })
            end
        end

        -- Delegate to browser_folder_cover's method when available
        if self._setFolderCover then
            self:_setFolderCover{ gallery = covers, book_count = book_count }
            return
        end

        -- Inline fallback gallery (matches collections.lua)
        local Blitbuffer      = require("ffi/blitbuffer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local FrameContainer  = require("ui/widget/container/framecontainer")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local ImageWidget     = require("ui/widget/imagewidget")
        local LineWidget      = require("ui/widget/linewidget")
        local OverlapGroup    = require("ui/widget/overlapgroup")
        local Size            = require("ui/size")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")

        local border = Size.border.thin
        local max_w  = self.width  - 2 * border
        local bh     = self.height - 2 * border
        local portrait_w, portrait_h
        if bh * 2 <= max_w * 3 then
            portrait_h = bh
            portrait_w = math.floor(bh * 2 / 3)
        else
            portrait_w = max_w
            portrait_h = math.min(math.floor(max_w * 3 / 2), bh)
        end

        local sep     = 1
        local half_w  = math.floor((portrait_w - sep) / 2)
        local half_w2 = portrait_w - sep - half_w
        local half_h  = math.floor((portrait_h - sep) / 2)
        local half_h2 = portrait_h - sep - half_h
        local cell_dims = {
            { w = half_w,  h = half_h  },
            { w = half_w2, h = half_h  },
            { w = half_w,  h = half_h2 },
            { w = half_w2, h = half_h2 },
        }
        local cells = {}
        for i = 1, 4 do
            local c  = covers[i]
            local cd = cell_dims[i]
            if c then
                cells[i] = CenterContainer:new{
                    dimen = { w = cd.w, h = cd.h },
                    ImageWidget:new{ image = c.data, width = cd.w, height = cd.h },
                }
            else
                cells[i] = CenterContainer:new{
                    dimen = { w = cd.w, h = cd.h },
                    VerticalSpan:new{ width = 1 },
                }
            end
        end
        local dimen = { w = portrait_w + 2 * border, h = portrait_h + 2 * border }
        local image_widget = FrameContainer:new{
            padding = 0, bordersize = border,
            width = dimen.w, height = dimen.h,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            CenterContainer:new{
                dimen = { w = portrait_w, h = portrait_h },
                VerticalGroup:new{
                    HorizontalGroup:new{
                        cells[1],
                        LineWidget:new{
                            background = Blitbuffer.COLOR_WHITE,
                            dimen = { w = sep, h = half_h },
                        },
                        cells[2],
                    },
                    LineWidget:new{
                        background = Blitbuffer.COLOR_WHITE,
                        dimen = { w = portrait_w, h = sep },
                    },
                    HorizontalGroup:new{
                        cells[3],
                        LineWidget:new{
                            background = Blitbuffer.COLOR_WHITE,
                            dimen = { w = sep, h = half_h2 },
                        },
                        cells[4],
                    },
                },
            },
            overlap_align = "center",
        }
        local centered_top = math.floor((self.height - dimen.h) / 2)
        local widget = OverlapGroup:new{
            dimen = { w = self.width, h = self.height },
            VerticalGroup:new{
                VerticalSpan:new{ width = centered_top },
                CenterContainer:new{
                    dimen = { w = self.width, h = dimen.h },
                    image_widget,
                },
            },
        }
        if self._underline_container[1] then
            self._underline_container[1]:free()
        end
        self._underline_container[1] = widget
    end
end

-------------------------------------------------------------------------------
-- patch_list_item: one-time install of ListMenuItem.update override
-------------------------------------------------------------------------------
local function patch_list_item()
    if _list_item_patched then return end

    local ok, ListMenu = pcall(require, "listmenu")
    if not ok then return end
    local ListMenuItem = get_upvalue(ListMenu._updateItemsBuildUI, "ListMenuItem")
    if not ListMenuItem then return end
    _list_item_patched = true

    local BD              = require("ui/bidi")
    local Blitbuffer      = require("ffi/blitbuffer")
    local BookInfoManager = require("bookinfomanager")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device          = require("device")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local ImageWidget     = require("ui/widget/imagewidget")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local LineWidget      = require("ui/widget/linewidget")
    local OverlapGroup    = require("ui/widget/overlapgroup")
    local RightContainer  = require("ui/widget/container/rightcontainer")
    local Size            = require("ui/size")
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    local TextWidget      = require("ui/widget/textwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")

    local Screen = Device.screen
    local scale_by_size = Screen:scaleBySize(1000000) * (1 / 1000000)

    local orig_list_update = ListMenuItem.update

    function ListMenuItem:update(...)
        if not (self.menu and self.menu._zen_group_view
                and self.entry and self.entry._zen_files) then
            return orig_list_update(self, ...)
        end

        self.is_directory = true

        local files      = self.entry._zen_files
        local book_count = #files
        local display_name = self.entry.text or ""

        local underline_h  = 1
        local dimen_h      = self.height - 2 * underline_h
        local border_size  = Size.border.thin
        local cover_zone_w = dimen_h
        local max_img      = dimen_h - 2 * border_size
        local cover_w      = math.floor(max_img * 2 / 3)

        local function _fontSize(nominal, max_size)
            local fs = math.floor(nominal * dimen_h * (1 / 64) / scale_by_size)
            if max_size and fs >= max_size then return max_size end
            return fs
        end

        local wleft
        if self.do_cover_image then
            local gallery_mode = BookInfoManager:getSetting("folder_gallery_mode")
            local max_covers   = gallery_mode and 4 or 1
            local covers       = {}
            for i = 1, #files do
                local bi = BookInfoManager:getBookInfo(files[i], true)
                if bi and bi.cover_bb and bi.has_cover
                        and bi.cover_fetched and not bi.ignore_cover then
                    table.insert(covers, { data = bi.cover_bb:copy() })
                    if #covers >= max_covers then break end
                end
            end

            local cover_frame
            if gallery_mode then
                local gall_w = cover_w
                local gall_h = max_img
                if #covers > 0 then
                    local sep     = 1
                    local half_w  = math.floor((gall_w - sep) / 2)
                    local half_w2 = gall_w - sep - half_w
                    local half_h  = math.floor((gall_h - sep) / 2)
                    local half_h2 = gall_h - sep - half_h
                    local cell_dims = {
                        { w = half_w,  h = half_h  },
                        { w = half_w2, h = half_h  },
                        { w = half_w,  h = half_h2 },
                        { w = half_w2, h = half_h2 },
                    }
                    local cells = {}
                    for i = 1, 4 do
                        local c  = covers[i]
                        local cd = cell_dims[i]
                        if c then
                            cells[i] = CenterContainer:new{
                                dimen = { w = cd.w, h = cd.h },
                                ImageWidget:new{ image = c.data, width = cd.w, height = cd.h },
                            }
                        else
                            cells[i] = CenterContainer:new{
                                dimen = { w = cd.w, h = cd.h },
                                VerticalSpan:new{ width = 1 },
                            }
                        end
                    end
                    cover_frame = FrameContainer:new{
                        width = gall_w + 2 * border_size,
                        height = gall_h + 2 * border_size,
                        margin = 0, padding = 0, bordersize = border_size,
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                        CenterContainer:new{
                            dimen = { w = gall_w, h = gall_h },
                            VerticalGroup:new{
                                HorizontalGroup:new{
                                    cells[1],
                                    LineWidget:new{
                                        background = Blitbuffer.COLOR_WHITE,
                                        dimen = { w = sep, h = half_h },
                                    },
                                    cells[2],
                                },
                                LineWidget:new{
                                    background = Blitbuffer.COLOR_WHITE,
                                    dimen = { w = gall_w, h = sep },
                                },
                                HorizontalGroup:new{
                                    cells[3],
                                    LineWidget:new{
                                        background = Blitbuffer.COLOR_WHITE,
                                        dimen = { w = sep, h = half_h2 },
                                    },
                                    cells[4],
                                },
                            },
                        },
                    }
                    self.menu._has_cover_images = true
                    self._has_cover_image = true
                else
                    cover_frame = FrameContainer:new{
                        width = gall_w + 2 * border_size,
                        height = gall_h + 2 * border_size,
                        margin = 0, padding = 0, bordersize = border_size,
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                        CenterContainer:new{
                            dimen = { w = gall_w, h = gall_h },
                            VerticalSpan:new{ width = 1 },
                        },
                    }
                end
            elseif #covers > 0 then
                local bb       = covers[1].data
                local bb_w     = bb:getWidth()
                local bb_h     = bb:getHeight()
                local sf       = math.max(cover_w / bb_w, max_img / bb_h)
                local scaled_w = math.max(cover_w,  math.ceil(bb_w * sf))
                local scaled_h = math.max(max_img, math.ceil(bb_h * sf))
                local x_off    = math.floor((scaled_w - cover_w) / 2)
                local y_off    = math.floor((scaled_h - max_img) / 2)
                local scaled_bb = bb:scale(scaled_w, scaled_h)
                local fill_bb   = Blitbuffer.new(cover_w, max_img, scaled_bb:getType())
                fill_bb:blitFrom(scaled_bb, 0, 0, x_off, y_off, cover_w, max_img)
                scaled_bb:free()
                bb:free()
                local wimage = ImageWidget:new{
                    image = fill_bb, scale_factor = 1, _free_image = true,
                }
                wimage:_render()
                cover_frame = FrameContainer:new{
                    width = cover_w + 2 * border_size,
                    height = max_img + 2 * border_size,
                    margin = 0, padding = 0, bordersize = border_size,
                    CenterContainer:new{
                        dimen = { w = cover_w, h = max_img },
                        wimage,
                    },
                }
                self.menu._has_cover_images = true
                self._has_cover_image = true
            else
                cover_frame = FrameContainer:new{
                    width = cover_w + 2 * border_size,
                    height = max_img + 2 * border_size,
                    margin = 0, padding = 0, bordersize = border_size,
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                    CenterContainer:new{
                        dimen = { w = max_img, h = max_img },
                        VerticalSpan:new{ width = 1 },
                    },
                }
            end
            wleft = CenterContainer:new{
                dimen = { w = cover_zone_w, h = dimen_h },
                cover_frame,
            }
            self._cover_frame = cover_frame
        end

        local pad_left    = self.do_cover_image and Screen:scaleBySize(6) or Screen:scaleBySize(10)
        local pad_right   = Screen:scaleBySize(10)
        local fs_title    = _fontSize(18, 21)
        local fs_meta     = _fontSize(14, 18)
        local left_offset = self.do_cover_image and (cover_zone_w + pad_left) or pad_left

        local count_str = tostring(book_count) .. " " .. (book_count == 1 and "book" or "books")
        local wright_status = TextWidget:new{
            text    = count_str,
            face    = Font:getFace("cfont", fs_meta),
            fgcolor = Blitbuffer.COLOR_GRAY_3,
            padding = 0,
        }
        local wright_w = wright_status:getWidth()
        local main_w = math.max(1, self.width - left_offset - wright_w - 2 * pad_right)

        local wtitle = TextBoxWidget:new{
            text      = BD.auto(display_name),
            face      = Font:getFace("cfont", fs_title),
            width     = main_w,
            height    = dimen_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            bold      = true,
        }

        local wmain = LeftContainer:new{
            dimen = { w = self.width, h = dimen_h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = left_offset },
                LeftContainer:new{
                    dimen = { w = main_w, h = dimen_h },
                    wtitle,
                },
            },
        }

        local row_dimen = { w = self.width, h = dimen_h }
        local widget = OverlapGroup:new{
            dimen = row_dimen,
            wmain,
        }
        if wleft then
            table.insert(widget, 1, wleft)
        end
        table.insert(widget, RightContainer:new{
            dimen = row_dimen,
            HorizontalGroup:new{
                wright_status,
                HorizontalSpan:new{ width = pad_right },
            },
        })

        if self._underline_container[1] then
            self._underline_container[1]:free()
        end
        self._underline_container[1] = VerticalGroup:new{
            VerticalSpan:new{ width = underline_h },
            widget,
        }
        self.bookinfo_found = true
        self.init_done = true
    end
end

-------------------------------------------------------------------------------
-- remove_from_overlap: remove widget from an OverlapGroup/widget list
-------------------------------------------------------------------------------
local function remove_from_overlap(group, widget)
    if not widget then return end
    for i = #group, 1, -1 do
        if rawequal(group[i], widget) then
            table.remove(group, i)
            return
        end
    end
end

-------------------------------------------------------------------------------
-- clean_nav: suppress back arrow, inject status bar row, set display mode
-- back_callback: optional function for the status bar back chevron
-------------------------------------------------------------------------------
local function clean_nav(menu, tab_label, back_callback)
    if not menu then return end

    local UIManager_mod = require("ui/uimanager")

    menu._do_center_partial_rows = false

    local arrow = menu.page_return_arrow
    if arrow then
        local Geom = require("ui/geometry")
        arrow:hide()
        arrow.show     = function() end
        arrow.showHide = function() end
        arrow.dimen    = Geom:new{ w = 0, h = 0 }
    end

    local tb = menu.title_bar
    if not tb then
        logger.warn("zen-authors-series: clean_nav: no title_bar")
        return
    end

    local createStatusRow     = _zen_shared and _zen_shared.createStatusRow
    local createStatusRowCB   = _zen_shared and _zen_shared.createStatusRowCustomBack
    local repaintTitleBar     = _zen_shared and _zen_shared.repaintTitleBar

    local function makeRow()
        if back_callback and createStatusRowCB then
            return createStatusRowCB(back_callback)
        elseif createStatusRow then
            local FileManager = require("apps/filemanager/filemanager")
            return createStatusRow(nil, FileManager.instance)
        end
    end

    local status_row = makeRow()
    if status_row and tb.title_group and #tb.title_group >= 2 then
        tb.title_group[2] = status_row
        tb.title_group:resetLayout()

        remove_from_overlap(tb, tb.left_button)
        remove_from_overlap(tb, tb.right_button)
        tb.has_left_icon  = false
        tb.has_right_icon = false

        menu._zen_status_refresh = function()
            local row = makeRow()
            if row and tb.title_group and #tb.title_group >= 2 then
                tb.title_group[2] = row
                tb.title_group:resetLayout()
                if repaintTitleBar then repaintTitleBar(tb) end
            end
        end
    else
        remove_from_overlap(tb, tb.left_button)
        remove_from_overlap(tb, tb.right_button)
        tb.has_left_icon  = false
        tb.has_right_icon = false
    end
end

-------------------------------------------------------------------------------
-- build_group_item_table: convert db_bookinfo groups to Menu item_table entries
-- data_type: "authors" or "series"
-- groups: output of db_bookinfo.getGroupedByAuthor() / getGroupedBySeries()
-------------------------------------------------------------------------------
local function build_group_item_table(groups, data_type)
    local _ = require("gettext")
    local items = {}
    for _, group in ipairs(groups) do
        local files
        if data_type == "authors" then
            files = group.files
        else
            -- series items: extract file paths in order
            files = {}
            for _, item in ipairs(group.items) do
                table.insert(files, item.file)
            end
        end
        local display = group.author or group.series or "?"
        table.insert(items, {
            text        = display,
            _zen_files  = files,
            _zen_type   = data_type,
            _zen_group  = (data_type == "series") and group or nil,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text     = _("No books found"),
            dim      = true,
            callback = function() end,
        })
    end

    -- Apply reverse sort if enabled
    local settings_key = data_type == "authors" and "zen_authors_reverse" or "zen_series_reverse"
    local g_settings = rawget(_G, "G_reader_settings")
    if g_settings and g_settings:isTrue(settings_key) and #items > 0 then
        -- Reverse the array (skip the placeholder)
        if items[1].text ~= _("No books found") then
            local reversed = {}
            for i = #items, 1, -1 do
                table.insert(reversed, items[i])
            end
            items = reversed
        end
    end

    return items
end

-------------------------------------------------------------------------------
-- showDisplayModeDialog: show display mode selection dialog
-- menu: optional Menu instance to refresh after mode change
-------------------------------------------------------------------------------
local function showDisplayModeDialog(menu)
    local _ = require("gettext")
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")

    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FM and FM.instance
    local ok_bim, bim = pcall(require, "bookinfomanager")
    local cur_mode
    if ok_bim and bim then
        local ok3, m = pcall(function()
            return bim:getSetting("filemanager_display_mode")
        end)
        if ok3 then cur_mode = m end
    end

    local function apply_mode(mode)
        if fm and type(fm.onSetDisplayMode) == "function" then
            pcall(fm.onSetDisplayMode, fm, mode)
        elseif ok_bim and bim then
            pcall(bim.saveSetting, bim, "filemanager_display_mode", mode)
        end

        -- Refresh the menu to apply new display mode
        if menu then
            UIManager:close(menu)
            UIManager:nextTick(function()
                -- Trigger a rebuild based on menu type
                if menu._zen_group_view and menu.name == "authors" then
                    if _authors_menu then
                        UIManager:close(_authors_menu)
                        _authors_menu = nil
                    end
                    local ok_db, db = pcall(require, "common/db_bookinfo")
                    if ok_db then
                        local groups = db.getGroupedByAuthor()
                        local injectNav = _zen_shared and _zen_shared.navbar and _zen_shared.navbar.injectStandaloneNavbar
                        showGroupView("authors", injectNav, groups)
                    end
                elseif menu._zen_group_view and menu.name == "series" then
                    if _series_menu then
                        UIManager:close(_series_menu)
                        _series_menu = nil
                    end
                    local ok_db, db = pcall(require, "common/db_bookinfo")
                    if ok_db then
                        local groups = db.getGroupedBySeries()
                        local injectNav = _zen_shared and _zen_shared.navbar and _zen_shared.navbar.injectStandaloneNavbar
                        showGroupView("series", injectNav, groups)
                    end
                else
                    -- Detail view: just reopen with current settings
                    setup_display_mode(menu, false)
                    menu:updateItems()
                    UIManager:show(menu)
                end
            end)
        end
    end

    local view_dialog
    local function viewBtn(label, icon, mode)
        local active = cur_mode == mode
        return {{
            text     = icon .. "  " .. label .. (active and "  \u{2713}" or ""),
            align    = "left",
            enabled  = not active,
            callback = function()
                UIManager:close(view_dialog)
                apply_mode(mode)
            end,
        }}
    end

    view_dialog = ButtonDialog:new{
        title       = _("Display mode"),
        title_align = "center",
        buttons     = {
            viewBtn(_("Mosaic"),          "\u{F00A}", "mosaic_image"),
            viewBtn(_("List (detailed)"), "\u{F03A}", "list_image_meta"),
            viewBtn(_("List (basic)"),    "\u{F0CA}", "list_image_filename"),
        },
    }
    UIManager:show(view_dialog)
end

-------------------------------------------------------------------------------
-- showGroupContextMenu: context menu for folder hold or blank-space hold
-- item: if provided, shows folder context (cover gallery, name, count, Sort)
--       if nil, shows tab context (blank placeholder, tab name, Sort + Display)
-- tab_id: "authors" | "series"
-- menu: the Menu instance for callbacks
-------------------------------------------------------------------------------
local function showGroupContextMenu(item, tab_id, menu)
    local BD           = require("ui/bidi")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Device       = require("device")
    local UIManager    = require("ui/uimanager")
    local _            = require("gettext")

    local is_folder = item ~= nil
    local files      = is_folder and (item._zen_files or {}) or {}
    local group_name = is_folder and (item.text or "?") or (tab_id == "authors" and _("Authors") or _("Series"))
    local info_str
    if is_folder then
        local n = #files
        info_str = n == 1 and _("1 book") or (tostring(n) .. " " .. _("books"))
    else
        local n = (menu and menu.item_table) and #menu.item_table or 0
        if tab_id == "authors" then
            info_str = n == 1 and _("1 author") or (tostring(n) .. " " .. _("authors"))
        else
            info_str = n == 1 and _("1 series") or (tostring(n) .. " " .. _("series"))
        end
    end

    local Screen  = Device.screen
    local Size    = require("ui/size")
    local border  = Size.border.thin
    local gap     = Screen:scaleBySize(8)
    local dlg_w   = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    local avail_w = dlg_w - 2 * (Size.border.window + Size.padding.button)
                           - 2 * (Size.padding.default + Size.margin.default)
    local cover_max_w = Screen:scaleBySize(90)
    local cover_max_h = Screen:scaleBySize(140)

    -- Rounded corners helper function
    local function apply_rounded_corners(frame_widget, bsz)
        local plug = _zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local enabled = plug
            and type(plug.config) == "table"
            and type(plug.config.features) == "table"
            and plug.config.features.browser_cover_rounded_corners == true
        logger.info("zen-ui authors_series: rounded_corners plug=", tostring(plug ~= nil),
            "enabled=", tostring(enabled == true))
        if not enabled then return end
        local Blitbuffer = require("ffi/blitbuffer")
        local r       = Screen:scaleBySize(6)
        local r_inner = r - bsz
        local orig_pt = frame_widget.paintTo
        frame_widget.paintTo = function(self, bb, x, y)
            orig_pt(self, bb, x, y)
            if not (self.dimen and self.dimen.x) then return end
            local tx, ty = self.dimen.x, self.dimen.y
            local tw, th = self.dimen.w, self.dimen.h
            local wh  = Blitbuffer.COLOR_WHITE
            local blk = Blitbuffer.COLOR_BLACK
            for j = 0, r - 1 do
                local inner = math.sqrt(r * r - (r - j) * (r - j))
                local cut   = math.ceil(r - inner)
                if cut > 0 then
                    bb:paintRect(tx,            ty + j,           cut, 1, wh)
                    bb:paintRect(tx + tw - cut, ty + j,           cut, 1, wh)
                    bb:paintRect(tx,            ty + th - 1 - j,  cut, 1, wh)
                    bb:paintRect(tx + tw - cut, ty + th - 1 - j,  cut, 1, wh)
                end
            end
            for j = 0, r - 1 do
                for c = 0, r - 1 do
                    local dx   = r - c - 0.5
                    local dy   = r - j - 0.5
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist >= r_inner and dist <= r then
                        bb:paintRect(tx + c,          ty + j,           1, 1, blk)
                        bb:paintRect(tx + tw - 1 - c, ty + j,           1, 1, blk)
                        bb:paintRect(tx + c,          ty + th - 1 - j,  1, 1, blk)
                        bb:paintRect(tx + tw - 1 - c, ty + th - 1 - j,  1, 1, blk)
                    end
                end
            end
        end
    end

    -- Collect up to 4 covers from the group's files (folder mode only)
    local covers = {}
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if ok_bim and is_folder then
        for i = 1, math.min(#files, 4) do
            local fpath = files[i]
            local ok2, bi = pcall(BookInfoManager.getBookInfo, BookInfoManager, fpath, true)
            if ok2 and bi and bi.has_cover and bi.cover_bb and not bi.ignore_cover then
                table.insert(covers, { data = bi.cover_bb:copy() })
            end
        end
    end

    local Blitbuffer      = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Geom            = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local ImageWidget     = require("ui/widget/imagewidget")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local LineWidget      = require("ui/widget/linewidget")
    local TextWidget      = require("ui/widget/textwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local Widget          = require("ui/widget/widget")

    local sep     = 1
    local half_w  = math.floor((cover_max_w - sep) / 2)
    local half_w2 = cover_max_w - sep - half_w
    local half_h  = math.floor((cover_max_h - sep) / 2)
    local half_h2 = cover_max_h - sep - half_h
    local cell_dims = {
        { w = half_w,  h = half_h  },
        { w = half_w2, h = half_h  },
        { w = half_w,  h = half_h2 },
        { w = half_w2, h = half_h2 },
    }

    local cells = {}
    for i = 1, 4 do
        local c  = covers[i]
        local cd = cell_dims[i]
        if c then
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cd.w, h = cd.h },
                ImageWidget:new{
                    image            = c.data,
                    image_disposable = true,
                    width            = cd.w,
                    height           = cd.h,
                },
            }
        else
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cd.w, h = cd.h },
                VerticalSpan:new{ width = 1 },
            }
        end
    end

    local framed = FrameContainer:new{
        padding    = 0,
        bordersize = border,
        width      = cover_max_w + 2 * border,
        height     = cover_max_h + 2 * border,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = cover_max_w, h = cover_max_h },
            #covers > 0 and VerticalGroup:new{
                HorizontalGroup:new{
                    cells[1],
                    LineWidget:new{
                        background = Blitbuffer.COLOR_WHITE,
                        dimen = { w = sep, h = half_h },
                    },
                    cells[2],
                },
                LineWidget:new{
                    background = Blitbuffer.COLOR_WHITE,
                    dimen = { w = cover_max_w, h = sep },
                },
                HorizontalGroup:new{
                    cells[3],
                    LineWidget:new{
                        background = Blitbuffer.COLOR_WHITE,
                        dimen = { w = sep, h = half_h2 },
                    },
                    cells[4],
                },
            } or Widget:new{ dimen = Geom:new{ w = cover_max_w, h = cover_max_h } },
        },
    }

    -- Apply rounded corners to the frame
    apply_rounded_corners(framed, border)

    local framed_h   = cover_max_h + 2 * border
    local text_col_w = math.max(avail_w - cover_max_w - 2 * border - gap, Screen:scaleBySize(60))
    local vstack = VerticalGroup:new{ align = "left" }
    table.insert(vstack, TextWidget:new{
        text      = BD.auto(group_name),
        face      = Font:getFace("cfont", 20),
        bold      = true,
        max_width = text_col_w,
    })
    -- Show count for both folder (# books) and top-level (# authors/series)
    table.insert(vstack, VerticalSpan:new{ width = Screen:scaleBySize(2) })
    table.insert(vstack, TextWidget:new{
        text      = info_str,
        face      = Font:getFace("cfont", 17),
        max_width = text_col_w,
    })

    local cover_widget = LeftContainer:new{
        dimen = Geom:new{ w = avail_w, h = framed_h },
        HorizontalGroup:new{
            align = "top",
            framed,
            HorizontalSpan:new{ width = gap },
            vstack,
        },
    }

    local dlg
    local buttons = {}

    if is_folder then
        -- Folder hold: show Sort button only
        table.insert(buttons, {{
            text     = "\u{F0DC}  " .. _("Sort  \u{25B8}"),
            align    = "left",
            callback = function()
                UIManager:close(dlg)
                showGroupSortDialog(tab_id, menu)
            end,
        }})
    else
        -- Blank-space hold: show Sort + Display buttons
        table.insert(buttons, {{
            text     = "\u{F0DC}  " .. _("Sort  \u{25B8}"),
            align    = "left",
            callback = function()
                UIManager:close(dlg)
                showGroupSortDialog(tab_id, menu)
            end,
        }})
        table.insert(buttons, {{
            text     = "\u{F06E}  " .. _("Display  \u{25B8}"),
            align    = "left",
            callback = function()
                UIManager:close(dlg)
                showDisplayModeDialog(menu)
            end,
        }})
    end

    dlg = ButtonDialog:new{
        buttons        = buttons,
        _added_widgets = { cover_widget },
    }
    UIManager:show(dlg)
end

-------------------------------------------------------------------------------
-- showGroupSortDialog: show ascending/descending sort dialog for group view
-- tab_id: "authors" | "series"
-- menu: the Menu instance to refresh after sort change
-------------------------------------------------------------------------------
local function showGroupSortDialog(tab_id, menu)
    local _ = require("gettext")
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")

    local settings_key = tab_id == "authors" and "zen_authors_reverse" or "zen_series_reverse"
    local g_settings = rawget(_G, "G_reader_settings")
    if not g_settings then return end

    local cur_reverse = g_settings:isTrue(settings_key)
    local title = tab_id == "authors" and _("Sort authors") or _("Sort series")

    local sort_dialog
    local sort_buttons = {
        {{
            text     = "\u{F15D}  " .. _("Ascending") .. (not cur_reverse and "  \u{2713}" or ""),
            align    = "left",
            enabled  = cur_reverse,
            callback = function()
                g_settings:delSetting(settings_key)
                UIManager:close(sort_dialog)
                if menu then
                    -- Re-fetch and rebuild
                    local ok, db = pcall(require, "common/db_bookinfo")
                    if ok then
                        local groups = tab_id == "authors"
                            and db.getGroupedByAuthor()
                            or db.getGroupedBySeries()
                        menu.item_table = build_group_item_table(groups, tab_id)
                        menu:updateItems()
                    end
                end
            end,
        }},
        {{
            text     = "\u{F15E}  " .. _("Descending") .. (cur_reverse and "  \u{2713}" or ""),
            align    = "left",
            enabled  = not cur_reverse,
            callback = function()
                g_settings:saveSetting(settings_key, true)
                UIManager:close(sort_dialog)
                if menu then
                    -- Re-fetch and rebuild
                    local ok, db = pcall(require, "common/db_bookinfo")
                    if ok then
                        local groups = tab_id == "authors"
                            and db.getGroupedByAuthor()
                            or db.getGroupedBySeries()
                        menu.item_table = build_group_item_table(groups, tab_id)
                        menu:updateItems()
                    end
                end
            end,
        }},
    }

    sort_dialog = ButtonDialog:new{
        title       = title,
        title_align = "center",
        buttons     = sort_buttons,
    }
    UIManager:show(sort_dialog)
end

-------------------------------------------------------------------------------
-- sortDetailFiles: sort files array by collate field and reverse flag
-- Returns sorted array of file paths
-------------------------------------------------------------------------------
local function sortDetailFiles(files, collate, reverse)
    if not files or #files == 0 then return files end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim then return files end

    -- Build sortable array with metadata
    local items = {}
    for _, fpath in ipairs(files) do
        local bookinfo = BookInfoManager:getBookInfo(fpath, true)
        local sort_key

        if collate == "title" then
            sort_key = (bookinfo and bookinfo.title) or fpath:match("([^/]+)$") or fpath
        elseif collate == "series" then
            sort_key = (bookinfo and bookinfo.series) or ""
        elseif collate == "access" then
            -- Recently read: use last_read timestamp (higher = more recent)
            sort_key = (bookinfo and bookinfo.last_read) or 0
        else
            sort_key = fpath:match("([^/]+)$") or fpath
        end

        table.insert(items, { path = fpath, key = sort_key })
    end

    -- Sort by key
    table.sort(items, function(a, b)
        if collate == "access" then
            -- For access, higher timestamp = more recent, so reverse the comparison
            return reverse and (a.key < b.key) or (a.key > b.key)
        else
            -- For title/series, alphabetical
            local a_lower = type(a.key) == "string" and a.key:lower() or tostring(a.key)
            local b_lower = type(b.key) == "string" and b.key:lower() or tostring(b.key)
            return reverse and (a_lower > b_lower) or (a_lower < b_lower)
        end
    end)

    -- Extract sorted paths
    local sorted = {}
    for _, item in ipairs(items) do
        table.insert(sorted, item.path)
    end

    return sorted
end

-------------------------------------------------------------------------------
-- showDetailSortDialog: show sort options dialog for detail view
-- group_name: the author or series name
-- tab_id: "authors" | "series"
-- menu: the Menu instance to refresh after sort change
-- files: list of file paths
-------------------------------------------------------------------------------
local function showDetailSortDialog(group_name, tab_id, menu, files)
    local _ = require("gettext")
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")

    local collate_key = "zen_" .. tab_id .. "_detail_collate_" .. group_name
    local reverse_key = "zen_" .. tab_id .. "_detail_reverse_" .. group_name
    local g_settings = rawget(_G, "G_reader_settings")
    if not g_settings then return end

    local cur_collate = g_settings:readSetting(collate_key) or "title"
    local cur_reverse = g_settings:isTrue(reverse_key)

    local SORT_OPTIONS = {
        { key = "title",  text = "\u{F031}  " .. _("Title") },
        { key = "series", text = "\u{F0CB}  " .. _("Series") },
        { key = "access", text = "\u{F073}  " .. _("Recently read") },
    }

    local function rebuildMenu(collate, reverse)
        if not (menu and files) then return end

        local sorted_files = sortDetailFiles(files, collate, reverse)

        local book_items = {}
        for _, fpath in ipairs(sorted_files) do
            local fname = fpath:match("([^/]+)$") or fpath
            local display = fname:gsub("%.[^%.]+$", "")

            table.insert(book_items, {
                text = display,
                path = fpath,      -- Standard KOReader file item field
                is_file = true,    -- Required for CoverBrowser to recognize as file
            })
        end

        menu.item_table = book_items
        menu:updateItems()
    end

    local sort_dialog
    local sort_buttons = {}

    -- Add collate field options
    for _, opt in ipairs(SORT_OPTIONS) do
        local is_active = cur_collate == opt.key
        table.insert(sort_buttons, {{
            text     = opt.text .. (is_active and "  \u{2713}" or ""),
            align    = "left",
            enabled  = not is_active,
            callback = function()
                g_settings:saveSetting(collate_key, opt.key)
                UIManager:close(sort_dialog)
                rebuildMenu(opt.key, cur_reverse)
            end,
        }})
    end

    -- Order submenu
    table.insert(sort_buttons, {{
        text     = "\u{F0DC}  " .. _("Order  ▶"),
        align    = "left",
        callback = function()
            local order_dialog
            local order_buttons = {
                {{
                    text     = "\u{F15D}  " .. _("Ascending") .. (not cur_reverse and "  \u{2713}" or ""),
                    align    = "left",
                    enabled  = cur_reverse,
                    callback = function()
                        g_settings:delSetting(reverse_key)
                        UIManager:close(order_dialog)
                        UIManager:close(sort_dialog)
                        rebuildMenu(cur_collate, false)
                    end,
                }},
                {{
                    text     = "\u{F15E}  " .. _("Descending") .. (cur_reverse and "  \u{2713}" or ""),
                    align    = "left",
                    enabled  = not cur_reverse,
                    callback = function()
                        g_settings:saveSetting(reverse_key, true)
                        UIManager:close(order_dialog)
                        UIManager:close(sort_dialog)
                        rebuildMenu(cur_collate, true)
                    end,
                }},
            }
            order_dialog = ButtonDialog:new{
                title       = _("Sort order"),
                title_align = "center",
                buttons     = order_buttons,
            }
            UIManager:show(order_dialog)
        end,
    }})

    sort_dialog = ButtonDialog:new{
        title       = _("Sort books by"),
        title_align = "center",
        buttons     = sort_buttons,
    }
    UIManager:show(sort_dialog)
end

-------------------------------------------------------------------------------
-- showDetailView: book list for one author/series group
-- Called from onMenuSelect on the group list menu
-------------------------------------------------------------------------------
local function showDetailView(group_item, injectNavbar, tab_id)
    local _ = require("gettext")
    local Menu      = require("ui/widget/menu")
    local TitleBar  = require("ui/widget/titlebar")
    local UIManager = require("ui/uimanager")
    local ReaderUI  = require("apps/reader/readerui")

    local files      = group_item._zen_files or {}
    local group_name = group_item.text or ""
    local detail_name = tab_id == "authors" and "authors_detail" or "series_detail"

    -- Get sort settings for this group
    local collate_key = "zen_" .. tab_id .. "_detail_collate_" .. group_name
    local reverse_key = "zen_" .. tab_id .. "_detail_reverse_" .. group_name
    local g_settings = rawget(_G, "G_reader_settings")
    local cur_collate = g_settings and g_settings:readSetting(collate_key) or "title"
    local cur_reverse = g_settings and g_settings:isTrue(reverse_key) or false

    -- Sort files based on current settings
    local sorted_files = sortDetailFiles(files, cur_collate, cur_reverse)

    -- Build menu items from sorted files
    local book_items = {}
    for _, fpath in ipairs(sorted_files) do
        local fname = fpath:match("([^/]+)$") or fpath
        local display = fname:gsub("%.[^%.]+$", "")

        table.insert(book_items, {
            text = display,
            path = fpath,      -- Standard KOReader file item field
            filepath = fpath,  -- Required for MosaicMenuItem badge access
            is_file = true,    -- Required for CoverBrowser to recognize as file
        })
    end
    if #book_items == 0 then
        table.insert(book_items, {
            text = _("No books found"),
            dim  = true,
            callback = function() end,
        })
    end

    -- Minimise TitleBar during Menu creation
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

    local detail_menu = Menu:new{
        name               = detail_name,
        title              = group_name,
        covers_fullscreen  = true,
        is_borderless      = true,
        is_popout          = false,
        title_bar_fm_style = true,  -- picked up by zen_scroll_bar patch
        item_table         = book_items,
        onMenuSelect       = function(menu_self, item)
            if item.path then
                ReaderUI:showReader(item.path)
            end
        end,
        onMenuHold         = function(menu_self, item)
            if not item.path then return end
            local FileManager = require("apps/filemanager/filemanager")
            local fm = FileManager.instance
            if fm and fm.file_chooser and fm.file_chooser.showFileDialog then
                fm.file_chooser:showFileDialog({
                    path    = item.path,
                    is_file = true,
                    text    = item.text,
                })
            end
        end,
        updateItems        = function(menu_self, ...) end,  -- prevent default pagination
    }
    TitleBar.new = orig_tb_new

    -- Install same display mode as the library (mosaic/list/classic)
    local mode_type = setup_display_mode(detail_menu, false)
    if mode_type == "mosaic" then
        patch_mosaic_item()
    elseif mode_type == "list" then
        patch_list_item()
    elseif mode_type == "classic" or not mode_type then
        local Menu_class = require("ui/widget/menu")
        detail_menu.updateItems = Menu_class.updateItems
    end

    detail_menu.close_callback = function()
        UIManager:close(detail_menu)
    end

    -- Close the parent group menu too (used by navbar tap to unwind the full stack)
    detail_menu._zen_close_stack = function()
        local parent = tab_id == "authors" and _authors_menu or _series_menu
        if parent then
            UIManager:close(parent)
            if tab_id == "authors" then _authors_menu = nil else _series_menu = nil end
        end
    end

    local back_to_group = function() UIManager:close(detail_menu) end
    clean_nav(detail_menu, group_name, back_to_group)

    if injectNavbar then
        injectNavbar(detail_menu, tab_id)  -- keep authors/series tab active
    end

    -- Add blank-space hold gesture handler for context menu
    local Device3 = require("device")
    if Device3:isTouchDevice() then
        local GestureRange2 = require("ui/gesturerange")
        local Geom2         = require("ui/geometry")
        if not detail_menu.ges_events then
            detail_menu.ges_events = {}
        end
        detail_menu.ges_events.ZenDetailBlankHold = {
            GestureRange2:new{
                ges   = "hold",
                range = Geom2:new{
                    x = 0, y = 0,
                    w = Device3.screen:getWidth(),
                    h = Device3.screen:getHeight(),
                },
            },
        }
        function detail_menu:onZenDetailBlankHold(arg, ges)
            local BD2           = require("ui/bidi")
            local ButtonDialog2 = require("ui/widget/buttondialog")
            local UIManager2    = require("ui/uimanager")
            local _2            = require("gettext")

            -- Build context menu with book covers from folder
            local Device4       = require("device")
            local Screen2       = Device4.screen
            local Size2         = require("ui/size")
            local border2       = Size2.border.thin
            local gap2          = Screen2:scaleBySize(8)
            local dlg_w2        = math.floor(math.min(Screen2:getWidth(), Screen2:getHeight()) * 0.9)
            local avail_w2      = dlg_w2 - 2 * (Size2.border.window + Size2.padding.button)
                                       - 2 * (Size2.padding.default + Size2.margin.default)
            local cover_max_w2  = Screen2:scaleBySize(90)
            local cover_max_h2  = Screen2:scaleBySize(140)

            -- Collect up to 4 covers from files in this detail view
            local covers2 = {}
            local ok_bim2, BookInfoManager2 = pcall(require, "bookinfomanager")
            if ok_bim2 and files then
                for i = 1, math.min(#files, 4) do
                    local fpath = files[i]
                    local ok2, bi2 = pcall(BookInfoManager2.getBookInfo, BookInfoManager2, fpath, true)
                    if ok2 and bi2 and bi2.has_cover and bi2.cover_bb and not bi2.ignore_cover then
                        table.insert(covers2, { data = bi2.cover_bb:copy() })
                    end
                end
            end

            local Blitbuffer2      = require("ffi/blitbuffer")
            local CenterContainer2 = require("ui/widget/container/centercontainer")
            local Font2            = require("ui/font")
            local FrameContainer2  = require("ui/widget/container/framecontainer")
            local Geom3            = require("ui/geometry")
            local HorizontalGroup2 = require("ui/widget/horizontalgroup")
            local HorizontalSpan2  = require("ui/widget/horizontalspan")
            local ImageWidget2     = require("ui/widget/imagewidget")
            local LeftContainer2   = require("ui/widget/container/leftcontainer")
            local LineWidget2      = require("ui/widget/linewidget")
            local TextWidget2      = require("ui/widget/textwidget")
            local VerticalGroup2   = require("ui/widget/verticalgroup")
            local VerticalSpan2    = require("ui/widget/verticalspan")
            local Widget2          = require("ui/widget/widget")

            local sep2     = 1
            local half_w2  = math.floor((cover_max_w2 - sep2) / 2)
            local half_w22 = cover_max_w2 - sep2 - half_w2
            local half_h2  = math.floor((cover_max_h2 - sep2) / 2)
            local half_h22 = cover_max_h2 - sep2 - half_h2
            local cell_dims2 = {
                { w = half_w2,  h = half_h2  },
                { w = half_w22, h = half_h2  },
                { w = half_w2,  h = half_h22 },
                { w = half_w22, h = half_h22 },
            }

            local cells2 = {}
            for i = 1, 4 do
                local cw, ch = cell_dims2[i].w, cell_dims2[i].h
                local cell
                if covers2[i] then
                    cell = CenterContainer2:new{
                        dimen = Geom3:new{ w = cw, h = ch },
                        ImageWidget2:new{
                            image            = covers2[i].data,
                            image_disposable = true,
                            width            = cw,
                            height           = ch,
                        },
                    }
                else
                    cell = CenterContainer2:new{
                        dimen = Geom3:new{ w = cw, h = ch },
                        VerticalSpan2:new{ width = 1 },
                    }
                end
                table.insert(cells2, cell)
            end

            local framed2 = FrameContainer2:new{
                padding    = 0,
                bordersize = border2,
                width      = cover_max_w2 + 2 * border2,
                height     = cover_max_h2 + 2 * border2,
                background = Blitbuffer2.COLOR_LIGHT_GRAY,
                VerticalGroup2:new{
                    align = "left",
                    HorizontalGroup2:new{
                        align = "top",
                        cells2[1],
                        LineWidget2:new{
                            background = Blitbuffer2.COLOR_WHITE,
                            dimen      = { w = sep2, h = half_h2 },
                        },
                        cells2[2],
                    },
                    LineWidget2:new{
                        background = Blitbuffer2.COLOR_WHITE,
                        dimen      = { w = cover_max_w2, h = sep2 },
                    },
                    HorizontalGroup2:new{
                        align = "top",
                        cells2[3],
                        LineWidget2:new{
                            background = Blitbuffer2.COLOR_WHITE,
                            dimen      = { w = sep2, h = half_h22 },
                        },
                        cells2[4],
                    },
                },
            }

            -- Apply rounded corners
            local function apply_rounded_corners2(frame_widget, bsz)
                local plug = _zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
                local enabled = plug
                    and type(plug.config) == "table"
                    and type(plug.config.features) == "table"
                    and plug.config.features.browser_cover_rounded_corners == true
                logger.info("zen-ui authors_series detail: rounded_corners plug=", tostring(plug ~= nil),
                    "enabled=", tostring(enabled == true))
                if not enabled then return end
                local r       = Screen2:scaleBySize(6)
                local r_inner = r - bsz
                local orig_pt = frame_widget.paintTo
                frame_widget.paintTo = function(self, bb, x, y)
                    orig_pt(self, bb, x, y)
                    if not (self.dimen and self.dimen.x) then return end
                    local tx, ty = self.dimen.x, self.dimen.y
                    local tw, th = self.dimen.w, self.dimen.h
                    local wh  = Blitbuffer2.COLOR_WHITE
                    local blk = Blitbuffer2.COLOR_BLACK
                    for j = 0, r - 1 do
                        local inner = math.sqrt(r * r - (r - j) * (r - j))
                        local cut   = math.ceil(r - inner)
                        if cut > 0 then
                            bb:paintRect(tx,            ty + j,           cut, 1, wh)
                            bb:paintRect(tx + tw - cut, ty + j,           cut, 1, wh)
                            bb:paintRect(tx,            ty + th - 1 - j,  cut, 1, wh)
                            bb:paintRect(tx + tw - cut, ty + th - 1 - j,  cut, 1, wh)
                        end
                    end
                    for j = 0, r - 1 do
                        for c = 0, r - 1 do
                            local dx   = r - c - 0.5
                            local dy   = r - j - 0.5
                            local dist = math.sqrt(dx * dx + dy * dy)
                            if dist >= r_inner and dist <= r then
                                bb:paintRect(tx + c,          ty + j,           1, 1, blk)
                                bb:paintRect(tx + tw - 1 - c, ty + j,           1, 1, blk)
                                bb:paintRect(tx + c,          ty + th - 1 - j,  1, 1, blk)
                                bb:paintRect(tx + tw - 1 - c, ty + th - 1 - j,  1, 1, blk)
                            end
                        end
                    end
                end
            end
            apply_rounded_corners2(framed2, border2)

            local framed_h2   = cover_max_h2 + 2 * border2
            local text_col_w2 = math.max(avail_w2 - cover_max_w2 - 2 * border2 - gap2, Screen2:scaleBySize(60))
            local book_count2 = files and #files or 0
            local count_str2  = book_count2 == 1
                and _2("1 book")
                or (tostring(book_count2) .. " " .. _2("books"))
            local vstack2 = VerticalGroup2:new{ align = "left" }
            table.insert(vstack2, TextWidget2:new{
                text      = BD2.auto(group_name),
                face      = Font2:getFace("cfont", 20),
                bold      = true,
                max_width = text_col_w2,
            })
            table.insert(vstack2, VerticalSpan2:new{ width = Screen2:scaleBySize(2) })
            table.insert(vstack2, TextWidget2:new{
                text      = count_str2,
                face      = Font2:getFace("cfont", 17),
                max_width = text_col_w2,
            })

            local cover_widget2 = LeftContainer2:new{
                dimen = Geom3:new{ w = avail_w2, h = framed_h2 },
                HorizontalGroup2:new{
                    align = "top",
                    framed2,
                    HorizontalSpan2:new{ width = gap2 },
                    vstack2,
                },
            }

            local detail_dlg
            detail_dlg = ButtonDialog2:new{
                buttons = {
                    {{
                        text     = "\u{F0DC}  " .. _2("Sort  \u{25B8}"),
                        align    = "left",
                        callback = function()
                            UIManager2:close(detail_dlg)
                            showDetailSortDialog(group_name, tab_id, self, files)
                        end,
                    }},
                    {{
                        text     = "\u{F06E}  " .. _2("Display  \u{25B8}"),
                        align    = "left",
                        callback = function()
                            UIManager2:close(detail_dlg)
                            showDisplayModeDialog(self)
                        end,
                    }},
                },
                _added_widgets = { cover_widget2 },
            }
            UIManager2:show(detail_dlg)
            return true
        end
    end

    UIManager:show(detail_menu)
    UIManager:nextTick(function()
        detail_menu:updateItems()
        -- Re-inject status row after updateItems (it may reset title_group).
        local createSR2   = _zen_shared and _zen_shared.createStatusRowCustomBack
        local repaintTB2  = _zen_shared and _zen_shared.repaintTitleBar
        local tb2 = detail_menu.title_bar
        if tb2 and createSR2 and tb2.title_group and #tb2.title_group >= 2 then
            tb2.title_group[2] = createSR2(back_to_group)
            tb2.title_group:resetLayout()
            if repaintTB2 then repaintTB2(tb2) end
        end
    end)
end

-------------------------------------------------------------------------------
-- showGroupView: shared group-list menu builder for authors and series
-- tab_id: "authors" | "series"
-- injectNavbar: the injectStandaloneNavbar function from navbar.lua
-- groups: pre-loaded data from db_bookinfo
-------------------------------------------------------------------------------
local function showGroupView(tab_id, injectNavbar, groups)
    local _ = require("gettext")
    local Menu      = require("ui/widget/menu")
    local TitleBar  = require("ui/widget/titlebar")
    local UIManager = require("ui/uimanager")

    local title = tab_id == "authors" and _("Authors") or _("Series")
    local item_table = build_group_item_table(groups, tab_id)

    -- Minimise TitleBar during Menu creation
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
        name               = tab_id,
        title              = title,
        covers_fullscreen  = true,
        is_borderless      = true,
        is_popout          = false,
        title_bar_fm_style = true,  -- picked up by zen_scroll_bar patch
        item_table         = item_table,
        onMenuSelect       = function(menu_self, item)
            if item._zen_files then
                showDetailView(item, injectNavbar, tab_id)
            end
        end,
        onMenuHold         = function(menu_self, item)
            if item._zen_files then
                showGroupContextMenu(item, tab_id, menu_self)
            end
        end,
        updateItems        = function(menu_self, ...) end,  -- prevent default pagination
    }
    TitleBar.new = orig_tb_new

    -- Install display mode (mosaic/list) and set _zen_group_view sentinel
    local mode_type = setup_display_mode(menu, true)
    if mode_type == "mosaic" then
        patch_mosaic_item()
    elseif mode_type == "list" then
        patch_list_item()
    end

    -- For classic mode (no CoverBrowser), restore the base updateItems
    if mode_type == "classic" or not mode_type then
        local Menu_class = require("ui/widget/menu")
        menu.updateItems = Menu_class.updateItems
    end

    menu.close_callback = function()
        UIManager:close(menu)
        if tab_id == "authors" then
            _authors_menu = nil
        else
            _series_menu = nil
        end
    end

    clean_nav(menu, title)

    if injectNavbar then
        injectNavbar(menu, tab_id)
    end

    if tab_id == "authors" then
        _authors_menu = menu
    else
        _series_menu = menu
    end

    -- Add blank-space hold gesture handler for context menu
    local Device2 = require("device")
    if Device2:isTouchDevice() then
        local GestureRange = require("ui/gesturerange")
        local Geom         = require("ui/geometry")
        if not menu.ges_events then
            menu.ges_events = {}
        end
        menu.ges_events.ZenGroupBlankHold = {
            GestureRange:new{
                ges   = "hold",
                range = Geom:new{
                    x = 0, y = 0,
                    w = Device2.screen:getWidth(),
                    h = Device2.screen:getHeight(),
                },
            },
        }
        function menu:onZenGroupBlankHold(arg, ges)
            showGroupContextMenu(nil, tab_id, self)
            return true
        end
    end

    UIManager:show(menu)
    -- updateItems was stubbed during Menu:new to skip the premature init-time call.
    -- Trigger the real render now via nextTick, after the menu has been dimensioned.
    UIManager:nextTick(function()
        menu:updateItems()
        -- Re-inject status row after updateItems (it may reset title_group).
        local createSR2 = _zen_shared and _zen_shared.createStatusRow
        local repaintTB2 = _zen_shared and _zen_shared.repaintTitleBar
        local tb2 = menu.title_bar
        if tb2 and createSR2 and tb2.title_group and #tb2.title_group >= 2 then
            local FileManager2 = require("apps/filemanager/filemanager")
            tb2.title_group[2] = createSR2(nil, FileManager2.instance)
            tb2.title_group:resetLayout()
            if repaintTB2 then repaintTB2(tb2) end
        end
    end)
end

-------------------------------------------------------------------------------
-- Public API called by navbar.lua tab callbacks
-------------------------------------------------------------------------------
function M.showAuthorsView(injectNavbar)
    local ok, db = pcall(require, "common/db_bookinfo")
    if not ok then return end
    local groups = db.getGroupedByAuthor()
    showGroupView("authors", injectNavbar, groups)
end

function M.showSeriesView(injectNavbar)
    local ok, db = pcall(require, "common/db_bookinfo")
    if not ok then return end
    local groups = db.getGroupedBySeries()
    showGroupView("series", injectNavbar, groups)
end

return function()
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then return end
    if not zen_plugin._zen_shared then zen_plugin._zen_shared = {} end
    _zen_shared  = zen_plugin._zen_shared
    _zen_plugin  = zen_plugin  -- keep reference; __ZEN_UI_PLUGIN is cleared after init
    zen_plugin._zen_shared.authors_series = M
end
