-- common/cover_utils.lua
-- Shared cover handling for filebrowser patches

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local BD = require("ui/bidi")
local _ = require("gettext")

local CoverUtils = {}

-- ============================================================
-- Helper: get_upvalue
-- ============================================================

function CoverUtils.getUpvalue(fn, name)
    if type(fn) ~= "function" then return nil end
    for i = 1, 64 do
        local upname, value = debug.getupvalue(fn, i)
        if not upname then break end
        if upname == name then return value end
    end
end

-- ============================================================
-- Cover mode (gallery / stack / normal)
-- ============================================================

function CoverUtils.getMode()
    local G = rawget(_G, "G_reader_settings")
    local is_gallery = G and G:isTrue("folder_gallery_mode") or false
    local is_stack = G and G:isTrue("folder_stack_mode") or false
    
    if is_gallery then
        return "gallery", 4, true
    elseif is_stack then
        return "stack", 3, true
    else
        return "normal", 1, false
    end
end

-- ============================================================
-- Cover ratio from settings (e.g., "2:3")
-- ============================================================

function CoverUtils.getRatio()
    local G = rawget(_G, "G_reader_settings")
    local ratio_str = G and G:readSetting("uniform_cover_ratio") or "2:3"
    local num, den = ratio_str:match("(%d+):(%d+)")
    return (tonumber(num) or 2) / (tonumber(den) or 3)
end

-- ============================================================
-- Calculate portrait dimensions from max_w and max_h
-- ============================================================

function CoverUtils.calcDims(max_w, max_h)
    local ratio = CoverUtils.getRatio()
    if max_h * ratio <= max_w then
        return math.floor(max_h * ratio), max_h
    else
        return max_w, math.floor(max_w / ratio)
    end
end

-- ============================================================
-- Generate placeholder cover from file path
-- ============================================================

function CoverUtils.genCover(filepath, target_w, target_h)
    local ratio = CoverUtils.getRatio()
    local width, height
    
    if target_w and target_h then
        width, height = CoverUtils.calcDims(target_w, target_h)
    elseif target_w then
        width, height = CoverUtils.calcDims(target_w, 9999)
    else
        width, height = CoverUtils.calcDims(9999, target_h or 300)
    end
    
    -- Get metadata
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    local title = ""
    local authors = ""
    
    if ok then
        local bookinfo = BookInfoManager:getBookInfo(filepath, true)
        if bookinfo and not bookinfo.ignore_meta then
            title = bookinfo.title or ""
            authors = bookinfo.authors or ""
            if authors and authors:find("\n") then
                authors = authors:match("^([^\n]+)")
            end
        end
    end
    
    -- Fallback to filename
    if title == "" then
        local fname = filepath:match("([^/]+)$") or ""
        fname = fname:gsub("/$", "")
        fname = fname:gsub("%.[^%.]+$", "")
        title = fname
    end
    
    if title == "" then title = _("Unknown") end
    if authors == "" then authors = _("Unknown Author") end
    
    -- Create canvas
    local final_bb = Blitbuffer.new(width, height, Blitbuffer.TYPE_BBRGB32)
    
    local split_y = math.floor(height * 2 / 3)
    local lighter_color = Blitbuffer.ColorRGB32(212, 220, 243, 255)
    local darker_color = Blitbuffer.ColorRGB32(130, 159, 227, 255)
    
    for y = 0, split_y - 1 do
        for x = 0, width - 1 do
            final_bb:setPixel(x, y, lighter_color)
        end
    end
    for y = split_y, height - 1 do
        for x = 0, width - 1 do
            final_bb:setPixel(x, y, darker_color)
        end
    end
    
    local title_area_h = split_y - 10
    local author_area_h = height - split_y - 10
    local max_text_width = width - 16
    
    local title_color = Blitbuffer.ColorRGB32(1, 68, 142, 255)
    local authors_color = Blitbuffer.ColorRGB32(8, 51, 93, 255)
    
    -- Title widget
    local title_font_size = 20
    local min_title_font = 10
    local title_widget = nil
    
    while title_font_size >= min_title_font do
        if title_widget then title_widget:free() end
        local face = Font:getFace("ffont", title_font_size)
        title_widget = TextBoxWidget:new{
            text = title,
            face = face,
            width = max_text_width,
            alignment = "center",
            bold = true,
            fgcolor = title_color,
            bgcolor = lighter_color,
        }
        if title_widget:getSize().h <= title_area_h then break end
        title_font_size = title_font_size - 1
    end
    
    if title_widget:getSize().h > title_area_h then
        title_widget:free()
        local face = Font:getFace("ffont", min_title_font)
        title_widget = TextBoxWidget:new{
            text = title,
            face = face,
            width = max_text_width,
            alignment = "center",
            bold = true,
            fgcolor = title_color,
            bgcolor = lighter_color,
            height = title_area_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end
    title_widget.handleEvent = function() return false end
    
    -- Author widget
    local authors_font_size = 16
    local min_authors_font = 6
    local authors_widget = nil
    
    while authors_font_size >= min_authors_font do
        if authors_widget then authors_widget:free() end
        local face = Font:getFace("ffont", authors_font_size)
        authors_widget = TextBoxWidget:new{
            text = authors,
            face = face,
            width = max_text_width,
            alignment = "center",
            fgcolor = authors_color,
            bgcolor = darker_color,
        }
        if authors_widget:getSize().h <= author_area_h then break end
        authors_font_size = authors_font_size - 1
    end
    
    if authors_widget and authors_widget:getSize().h > author_area_h then
        authors_widget:free()
        local face = Font:getFace("ffont", min_authors_font)
        authors_widget = TextBoxWidget:new{
            text = authors,
            face = face,
            width = max_text_width,
            alignment = "center",
            fgcolor = authors_color,
            bgcolor = darker_color,
            height = author_area_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end
    if authors_widget then
        authors_widget.handleEvent = function() return false end
    end
    
    -- Paint
    local title_y = math.max(5, (split_y - title_widget:getSize().h) / 2)
    title_widget:paintTo(final_bb, math.max(0, (width - title_widget:getSize().w) / 2), title_y)
    title_widget:free()
    
    if authors_widget then
        local authors_y = split_y + math.max(5, (author_area_h - authors_widget:getSize().h) / 2)
        authors_widget:paintTo(final_bb, math.max(0, (width - authors_widget:getSize().w) / 2), authors_y)
        authors_widget:free()
    end
    
    return final_bb, width, height
end

-- ============================================================
-- Scale a real cover to target dimensions while preserving aspect ratio
-- ============================================================

function CoverUtils.scaleCover(cover_bb, src_w, src_h, target_w, target_h)
    local scaled_bb = cover_bb:scale(target_w, target_h)
    return scaled_bb, target_w, target_h
end
-- ============================================================
-- Collect covers from directory
-- ============================================================

function CoverUtils.collect(dir_path, chooser, max_covers, need_copy, entries)
    local covers = {}
    
    if not entries then
        chooser._dummy = true
        entries = chooser:genItemTableFromPath(dir_path)
        chooser._dummy = false
    end
    
    if not entries then return covers end
    
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok then return covers end
    
    for _, entry in ipairs(entries) do
        if (entry.is_file or entry.file) and #covers < max_covers then
            local fpath = entry.path or entry.file
            local bookinfo = BookInfoManager:getBookInfo(fpath, true)
            
            if bookinfo and bookinfo.cover_bb and bookinfo.has_cover
                    and bookinfo.cover_fetched and not bookinfo.ignore_cover then
                local cover_bb = need_copy and bookinfo.cover_bb:copy() or bookinfo.cover_bb
                table.insert(covers, { data = cover_bb, w = bookinfo.cover_w, h = bookinfo.cover_h })
            else
                local cover_bb, pw, ph = CoverUtils.genCover(fpath, 200, 300)
                table.insert(covers, { data = cover_bb, w = pw, h = ph })
            end
        end
    end
    
    return covers
end

-- ============================================================
-- DRAWING FUNCTIONS
-- ============================================================

function CoverUtils.drawGallery(covers, portrait_w, portrait_h, border)
    local sep = 1
    local half_w = math.floor((portrait_w - sep) / 2)
    local half_w2 = portrait_w - sep - half_w
    local half_h = math.floor((portrait_h - sep) / 2)
    local half_h2 = portrait_h - sep - half_h
    local cell_dims = {
        { w = half_w,  h = half_h  },
        { w = half_w2, h = half_h  },
        { w = half_w,  h = half_h2 },
        { w = half_w2, h = half_h2 },
    }
    
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local ImageWidget = require("ui/widget/imagewidget")
    local LineWidget = require("ui/widget/linewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    
    local cells = {}
    for i = 1, 4 do
        local c = covers[i]
        local cd = cell_dims[i]
        if c then
            cells[i] = CenterContainer:new{
                dimen = { w = cd.w, h = cd.h },
                ImageWidget:new{
                    image = c.data,
                    width = cd.w,
                    height = cd.h,
                },
            }
        else
            cells[i] = CenterContainer:new{
                dimen = { w = cd.w, h = cd.h },
                VerticalSpan:new{ width = 1 },
            }
        end
    end
    
    local bg = Blitbuffer.COLOR_LIGHT_GRAY
    local dimen = { w = portrait_w + 2 * border, h = portrait_h + 2 * border }
    
    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        width = dimen.w,
        height = dimen.h,
        background = bg,
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
end

function CoverUtils.drawStack(covers, portrait_w, portrait_h, border)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    
    local stack_count = #covers
    local bg = Blitbuffer.COLOR_LIGHT_GRAY
    local dimen = { w = portrait_w + 2 * border, h = portrait_h + 2 * border }
    
    if stack_count == 0 then
        return FrameContainer:new{
            padding = 0,
            bordersize = border,
            width = dimen.w,
            height = dimen.h,
            background = bg,
            CenterContainer:new{
                dimen = { w = portrait_w, h = portrait_h },
                VerticalSpan:new{ width = 1 },
            },
            overlap_align = "center",
        }
    end
    
    local final_bb = Blitbuffer.new(portrait_w, portrait_h)
    final_bb:fill(Blitbuffer.COLOR_WHITE)
    
    local book_width = portrait_w * 0.85
    local book_height = book_width * (portrait_h / portrait_w)
    local base_x = math.floor((portrait_w - book_width) / 2)
    local base_y = math.floor((portrait_h - book_height) / 2)
    
    local offsets
    if stack_count == 1 then
        offsets = { { x = 0, y = 6 } }
    elseif stack_count == 2 then
        offsets = { { x = 8, y = 0 }, { x = -8, y = 12 } }
    else
        offsets = { { x = 12, y = 0 }, { x = 0, y = 6 }, { x = -12, y = 12 } }
    end
    
    for i = math.min(stack_count, 3), 1, -1 do
        local cover = covers[i]
        local offset_idx = math.min(stack_count - i + 1, #offsets)
        local offset = offsets[offset_idx] or { x = 0, y = 0 }
        
        local scaled_bb, sw, sh = CoverUtils.scaleCover(cover.data, cover.w, cover.h, book_width, book_height)
        local img_widget = ImageWidget:new{
            image = scaled_bb,
            width = sw,
            height = sh,
        }
        img_widget:paintTo(final_bb, base_x + offset.x, base_y + offset.y)
    end
    
    local plugin_root = require("common/plugin_root")
    local folder_icon_width = portrait_w
    local folder_icon_height = folder_icon_width * 0.65
    local folder_icon = ImageWidget:new{
        file = plugin_root .. "/icons/folder.png",
        width = folder_icon_width,
        height = folder_icon_height,
        alpha = true,
    }
    folder_icon:paintTo(final_bb, 0, portrait_h - folder_icon_height)
    
    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        width = dimen.w,
        height = dimen.h,
        background = bg,
        CenterContainer:new{
            dimen = { w = portrait_w, h = portrait_h },
            ImageWidget:new{
                image = final_bb,
                width = portrait_w,
                height = portrait_h,
            },
        },
        overlap_align = "center",
    }
end

function CoverUtils.drawNoImage(folder_name, portrait_w, portrait_h, border)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    
    local final_bb = Blitbuffer.new(portrait_w, portrait_h, Blitbuffer.TYPE_BBRGB32)
    local bg = Blitbuffer.COLOR_WHITE
    final_bb:fill(bg)
    
    local font_size = 20
    local min_font = 10
    local text_widget = nil
    
    while font_size >= min_font do
        if text_widget then text_widget:free() end
        local face = Font:getFace("cfont", font_size)
        text_widget = TextBoxWidget:new{
            text = folder_name,
            face = face,
            width = portrait_w - 16,
            alignment = "center",
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            bgcolor = bg,
        }
        if text_widget:getSize().h <= portrait_h - 10 then
            break
        end
        font_size = font_size - 1
    end
    
    text_widget.handleEvent = function() return false end
    
    if text_widget:getSize().h > portrait_h - 10 then
        text_widget:free()
        local face = Font:getFace("cfont", min_font)
        text_widget = TextBoxWidget:new{
            text = folder_name,
            face = face,
            width = portrait_w - 16,
            alignment = "center",
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            bgcolor = bg,
            height = portrait_h - 10,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
        text_widget.handleEvent = function() return false end
    end
    
    local y = (portrait_h - text_widget:getSize().h) / 2
    text_widget:paintTo(final_bb, (portrait_w - text_widget:getSize().w) / 2, y)
    text_widget:free()
    
    local dimen = { w = portrait_w + 2 * border, h = portrait_h + 2 * border }
    
    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        width = dimen.w,
        height = dimen.h,
        background = bg,
        CenterContainer:new{
            dimen = { w = portrait_w, h = portrait_h },
            ImageWidget:new{
                image = final_bb,
                width = portrait_w,
                height = portrait_h,
            },
        },
        overlap_align = "center",
    }
end

function CoverUtils.drawSingle(cover_data, portrait_w, portrait_h, border)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    
    local bg = Blitbuffer.COLOR_LIGHT_GRAY
    local dimen = { w = portrait_w + 2 * border, h = portrait_h + 2 * border }
    
    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        width = dimen.w,
        height = dimen.h,
        background = bg,
        CenterContainer:new{
            dimen = { w = portrait_w, h = portrait_h },
            ImageWidget:new{
                image = cover_data,
                width = portrait_w,
                height = portrait_h,
            },
        },
        overlap_align = "center",
    }
end

-- ============================================================
-- UNIFIED ENTRY POINT
-- ============================================================

function CoverUtils.makeCover(path, chooser, options)
    options = options or {}
    
    -- Handle single book file
    if not options.is_folder then
        local ok, BookInfoManager = pcall(require, "bookinfomanager")
        
        local target_w = options.width or 200
        local target_h = options.height or 300
        
        -- Always use calcDims to get correct dimensions
        local final_w, final_h = CoverUtils.calcDims(target_w, target_h)
        
        if ok then
            local bookinfo = BookInfoManager:getBookInfo(path, true)
            
            if bookinfo and bookinfo.cover_bb and bookinfo.has_cover
                    and bookinfo.cover_fetched and not bookinfo.ignore_cover then
                local scaled_bb, sw, sh = CoverUtils.scaleCover(
                    bookinfo.cover_bb, bookinfo.cover_w, bookinfo.cover_h,
                    final_w, final_h)
                local need_copy = options.need_copy == true
                local cover_bb = need_copy and scaled_bb:copy() or scaled_bb
                return cover_bb, final_w, final_h, "single", "real_cover"
            end
        end
        
        local cover_bb = CoverUtils.genCover(path, final_w, final_h)
        return cover_bb, final_w, final_h, "single", "placeholder"
    end
    
    -- Handle folder
    local mode, max_covers, need_copy = CoverUtils.getMode()
    if options.max_covers then max_covers = options.max_covers end
    
    local covers = options.covers_data
    if not covers or #covers == 0 then
        covers = CoverUtils.collect(path, chooser, max_covers, need_copy)
    end
    
    local folder_name = options.folder_name or (path:match("([^/]+)/?$") or path):gsub("/$", "")
    folder_name = BD.directory(folder_name)
    
    local border = 2
    local max_w = options.max_w or 200
    local max_h = options.max_h or 300
    
    local portrait_w, portrait_h = CoverUtils.calcDims(max_w, max_h)
    
    local cover_widget = nil
    
    local scaled_covers = {}
    for _, c in ipairs(covers) do
        if c.w ~= portrait_w or c.h ~= portrait_h then
            local scaled_bb, sw, sh = CoverUtils.scaleCover(c.data, c.w, c.h, portrait_w, portrait_h)
            table.insert(scaled_covers, { data = scaled_bb, w = sw, h = sh })
        else
            table.insert(scaled_covers, { data = c.data, w = c.w, h = c.h })
        end
    end
    
    if #scaled_covers > 0 then
        if mode == "gallery" then
            cover_widget = CoverUtils.drawGallery(scaled_covers, portrait_w, portrait_h, border)
        elseif mode == "stack" then
            cover_widget = CoverUtils.drawStack(scaled_covers, portrait_w, portrait_h, border)
        else
            cover_widget = CoverUtils.drawSingle(scaled_covers[1].data, portrait_w, portrait_h, border)
        end
        return cover_widget, mode, "folder_covers", scaled_covers
    end
    
    cover_widget = CoverUtils.drawNoImage(folder_name, portrait_w, portrait_h, border)
    return cover_widget, mode, "empty_folder", nil
end

return CoverUtils