local function apply_browser_list_item_layout()
    local BD = require("ui/bidi")
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device = require("device")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local util = require("util")
    local _ = require("gettext")

    local Screen = Device.screen
    local scale_by_size = Screen:scaleBySize(1000000) * (1 / 1000000)

    local function get_upvalue(fn, name)
        if type(fn) ~= "function" then return nil end
        for i = 1, 64 do
            local upname, value = debug.getupvalue(fn, i)
            if not upname then break end
            if upname == name then return value end
        end
    end

    local function patchListMenu()
        local ListMenu = require("listmenu")
        local ListMenuItem = get_upvalue(ListMenu._updateItemsBuildUI, "ListMenuItem")
        if not ListMenuItem then return end

        local BookInfoManager = get_upvalue(ListMenuItem.update, "BookInfoManager")
        if not BookInfoManager then return end

        local original_update = ListMenuItem.update

        function ListMenuItem:update()
            -- Only intercept file items in cover-image mode that have been indexed.
            -- Folders and the loading-spinner path fall through to the original.
            if not self.do_cover_image then
                return original_update(self)
            end

            local is_dir = not (self.entry.is_file or self.entry.file)
            if is_dir then
                return original_update(self)
            end

            -- filepath set in ListMenuItem:init()
            local filepath = self.filepath
            if not filepath then
                return original_update(self)
            end

            local underline_h = 1 -- matches self.underline_h in ListMenuItem:init()
            local dimen_h = self.height - 2 * underline_h
            local border_size = Size.border.thin
            local cover_zone_w = dimen_h  -- squared, identical to stock list mode
            local max_img = dimen_h - 2 * border_size
            -- Standard portrait width (2:3) so every cover frame is the same size
            local cover_w = math.floor(max_img * 2 / 3)

            -- Font sizing identical to listmenu.lua's internal _fontSize closure.
            local function _fontSize(nominal, max_size)
                local fs = math.floor(nominal * dimen_h * (1 / 64) / scale_by_size)
                if max_size and fs >= max_size then return max_size end
                return fs
            end

            -- Attempt to get bookinfo (without cover) first to check availability.
            local bookinfo = BookInfoManager:getBookInfo(filepath, false)

            -- If not yet indexed fall back to the original renderer so the
            -- loading hint ("…") is shown and the item queues for extraction.
            if not bookinfo then
                return original_update(self)
            end

            -- Re-fetch with cover only when in cover-image mode and cover exists.
            if self.do_cover_image and bookinfo.has_cover and not bookinfo.ignore_cover
               and not self.menu.no_refresh_covers then
                bookinfo = BookInfoManager:getBookInfo(filepath, true) or bookinfo
            end

            local file_deleted = self.entry.dim
            local fgcolor = file_deleted and Blitbuffer.COLOR_DARK_GRAY or nil

            -- ── Cover image (left zone) ──────────────────────────────────────
            local cover_bb_used = false
            local wleft

            if self.do_cover_image then
                local cover_specs = {
                    max_cover_w = cover_w,
                    max_cover_h = max_img,
                }
                self.menu.cover_specs = cover_specs

                if bookinfo.has_cover and not bookinfo.ignore_cover
                   and bookinfo.cover_bb and not self.menu.no_refresh_covers
                   and not BookInfoManager.isCachedCoverInvalid(bookinfo, cover_specs)
                then
                    cover_bb_used = true
                    local _, _, scale_factor = BookInfoManager.getCachedCoverSize(
                        bookinfo.cover_w, bookinfo.cover_h, cover_w, max_img)
                    local wimage = ImageWidget:new{
                        image = bookinfo.cover_bb,
                        scale_factor = scale_factor,
                    }
                    wimage:_render()
                    wleft = CenterContainer:new{
                        dimen = { w = cover_zone_w, h = dimen_h },
                        FrameContainer:new{
                            width = cover_w + 2 * border_size,
                            height = max_img + 2 * border_size,
                            margin = 0, padding = 0, bordersize = border_size,
                            dim = file_deleted,
                            CenterContainer:new{
                                dimen = { w = cover_w, h = max_img },
                                wimage,
                            },
                        },
                    }
                    self.menu._has_cover_images = true
                    self._has_cover_image = true
                else
                    -- Placeholder (no cover or not yet fetched)
                    wleft = CenterContainer:new{
                        dimen = { w = cover_zone_w, h = dimen_h },
                        FrameContainer:new{
                            width = cover_w + 2 * border_size,
                            height = max_img + 2 * border_size,
                            margin = 0, padding = 0, bordersize = border_size,
                            dim = file_deleted,
                            CenterContainer:new{
                                dimen = { w = cover_w, h = max_img },
                                TextWidget:new{
                                    text = "⛶",
                                    face = Font:getFace("cfont", _fontSize(20)),
                                },
                            },
                        },
                    }
                end
            end

            -- Free unused cover blitbuffer
            if bookinfo.cover_bb and not cover_bb_used then
                bookinfo.cover_bb:free()
            end

            -- ── Metadata ─────────────────────────────────────────────────────
            local book_info = self.menu.getBookInfo(filepath)
            self.been_opened = book_info.been_opened

            local directory, filename = util.splitFilePathName(filepath)
            local filename_without_suffix = filemanagerutil.splitFileNameType(filename)
            local has_description = bookinfo.description ~= nil
            self.has_description = has_description

            local title   = (not bookinfo.ignore_meta and bookinfo.title)   or filename_without_suffix
            local authors = (not bookinfo.ignore_meta and bookinfo.authors)
            local series  = (not bookinfo.ignore_meta and bookinfo.series)
            local series_index = (not bookinfo.ignore_meta and bookinfo.series_index)

            title   = title   and BD.auto(title)   or BD.filename(filename_without_suffix)
            authors = authors and BD.auto(authors)

            local series_str
            if series then
                series = BD.auto(series)
                if series_index then
                    series_str = string.format("#%.4g – %s", series_index, series)
                else
                    series_str = series
                end
            end

            -- ── Progress / right widget ───────────────────────────────────────
            local percent_finished = book_info.percent_finished
            local status = book_info.status
            local pages = book_info.pages or bookinfo.pages

            local status_label, progress_str
            if status == "complete" then
                status_label = _("Finished")
                progress_str = "\u{F00C}"
            elseif status == "abandoned" then
                status_label = _("On hold")
                progress_str = "\u{F04C}"
            elseif status == "reading" or percent_finished then
                if percent_finished then
                    status_label = string.format(_("%d%% Read"), math.floor(100 * percent_finished))
                else
                    status_label = _("Reading")
                end
            else
                status_label = _("Unread")
            end

            -- ── Book tags (Calibre keywords field from bookinfo DB) ──────────
            -- Only show tags in "list with metadata" mode, not filename-only modes.
            local tags_str
            if not self.do_filename_only
                and not bookinfo.ignore_meta and bookinfo.keywords
                and bookinfo.keywords ~= "" then
                -- Normalize any separator (newline, semicolon, " · ") to ", "
                tags_str = bookinfo.keywords
                    :gsub("%s*[\n;]%s*", ", ")
                    :gsub("%s+·%s+", ", ")
                    :gsub("^,%s*", ""):gsub(",%s*$", "")
            end

            -- ── Layout constants ─────────────────────────────────────────────
            local pad_left  = self.do_cover_image and Screen:scaleBySize(6) or Screen:scaleBySize(10)
            local pad_right = Screen:scaleBySize(10)
            local fs_title   = _fontSize(18, 21)
            local fs_meta    = _fontSize(14, 18)
            local fs_right   = _fontSize(14, 18)

            local left_offset = self.do_cover_image and (cover_zone_w + pad_left) or pad_left

            -- ── Step 1: build status widget at its natural width ─────────────
            local wright_status, status_nat_w = nil, 0
            if status_label then
                local display_str = progress_str and (status_label .. " " .. progress_str) or status_label
                wright_status = TextWidget:new{
                    text    = display_str,
                    face    = Font:getFace("cfont", fs_right),
                    fgcolor = fgcolor,
                    padding = 0,
                }
                status_nat_w = wright_status:getWidth()
            end

            -- ── Step 2: main_w based on status only → left side takes priority
            local main_w_first = math.max(1, self.width - left_offset - status_nat_w - 2 * pad_right)

            -- ── Step 3: measure natural title/author widths (single-line probe)
            local nat_left_w = 0
            do
                local tw = TextWidget:new{
                    text    = title,
                    face    = Font:getFace("cfont", fs_title),
                    bold    = true,
                    padding = 0,
                }
                nat_left_w = tw:getWidth()
                tw:free()
                if authors then
                    local authors_flat = authors:gsub("\n", " ")
                    local aw = TextWidget:new{
                        text    = authors_flat,
                        face    = Font:getFace("cfont", fs_meta),
                        padding = 0,
                    }
                    nat_left_w = math.max(nat_left_w, aw:getWidth())
                    aw:free()
                end
            end
            -- Actual left occupation = min of natural width and allocated space
            local actual_left_w = math.min(nat_left_w, main_w_first)

            -- ── Step 4: tags expand left into unused title space ─────────────
            -- Tags right-edge aligns with status right-edge: cap at the wider of
            -- status_nat_w and the unused space left of the actual title content.
            local wright_tags, wright_w = nil, status_nat_w
            if tags_str then
                local fs_tags = math.max(7, fs_right - 2)
                local tags_avail_w = self.width - left_offset - actual_left_w - 2 * pad_right
                -- Never wider than status line (keeps right edges flush)
                local tags_max_w = math.max(1, math.max(status_nat_w, tags_avail_w))
                -- But hard-cap to status_nat_w so tags don't push right column wider
                tags_max_w = math.min(tags_max_w, math.max(status_nat_w,
                    self.width - left_offset - actual_left_w - 2 * pad_right))
                tags_max_w = math.max(1, tags_max_w)
                wright_tags = TextWidget:new{
                    text      = tags_str,
                    face      = Font:getFace("cfont", fs_tags),
                    fgcolor   = Blitbuffer.COLOR_GRAY_3,
                    padding   = 0,
                    max_width = tags_max_w,
                }
                -- Column width = max of status and rendered tag width, but
                -- never wider than what avail space allows (left takes priority)
                local tags_rendered_w = wright_tags:getWidth()
                wright_w = math.min(
                    math.max(status_nat_w, tags_rendered_w),
                    self.width - left_offset - actual_left_w - 2 * pad_right
                )
                wright_w = math.max(status_nat_w, wright_w)
            end

            -- Final main_w: left gets its space; only shrinks if tags > status width
            local main_w = math.max(1, self.width - left_offset - wright_w - 2 * pad_right)

            -- ── Text stack (title / authors / series) ────────────────────────
            local function make_text_line(text, face, bold_flag)
                return TextBoxWidget:new{
                    text = text,
                    face = Font:getFace(face, bold_flag and fs_title or fs_meta),
                    width = main_w,
                    height = dimen_h,          -- will shrink via height_adjust
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                    alignment = "left",
                    bold = bold_flag or false,
                    fgcolor = fgcolor,
                }
            end

            local wtitle   = make_text_line(title,        "cfont", true)
            local wauthors = authors   and make_text_line(authors,   "cfont", false) or nil
            local wseries  = series_str and make_text_line(series_str, "cfont", false) or nil

            -- Shrink title font until title + meta fits in dimen_h
            local title_h   = wtitle:getSize().h
            local authors_h = wauthors and wauthors:getSize().h or 0
            local series_h  = wseries  and wseries:getSize().h  or 0
            local total_h   = title_h + authors_h + series_h

            if total_h > dimen_h then
                -- Drop to single lines for each to fit
                for _, w in ipairs{wtitle, wauthors, wseries} do
                    if w then
                        w.height = math.floor(dimen_h / (wauthors and wseries and 3 or wauthors and 2 or 1))
                        w.height_adjust = true
                        w.height_overflow_show_ellipsis = true
                        w:free(true)
                        w:init()
                    end
                end
            end

            local text_stack = VerticalGroup:new{ align = "left" }
            table.insert(text_stack, wtitle)
            if wauthors then table.insert(text_stack, wauthors) end
            if wseries  then table.insert(text_stack, wseries)  end

            local wmain = LeftContainer:new{
                dimen = { w = self.width, h = dimen_h },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = left_offset },
                    LeftContainer:new{
                        dimen = { w = main_w, h = dimen_h },
                        text_stack,
                    },
                },
            }

            -- ── Assemble full row ─────────────────────────────────────────────
            local row_dimen = { w = self.width, h = dimen_h }
            local widget = OverlapGroup:new{
                dimen = row_dimen,
                wmain,
            }

            if wleft then
                table.insert(widget, 1, wleft)
            end

            if wright_status or wright_tags then
                local right_stack = VerticalGroup:new{ align = "right" }
                if wright_status then table.insert(right_stack, wright_status) end
                if wright_tags   then table.insert(right_stack, wright_tags)   end
                table.insert(widget, RightContainer:new{
                    dimen = row_dimen,
                    HorizontalGroup:new{
                        right_stack,
                        HorizontalSpan:new{ width = pad_right },
                    },
                })
            end

            -- ── Commit to underline container ────────────────────────────────
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

    -- Hook FileManager:setupLayout so we run after coverbrowser has been
    -- instantiated (same pattern as browser_folder_cover).
    local FileManager = require("apps/filemanager/filemanager")
    local orig_fm_setupLayout = FileManager.setupLayout
    local patched = false

    FileManager.setupLayout = function(self)
        orig_fm_setupLayout(self)
        if not patched and self.coverbrowser then
            patchListMenu()
            patched = true
        end
    end
end

return apply_browser_list_item_layout
