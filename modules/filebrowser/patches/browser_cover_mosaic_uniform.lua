--[[
    browser_cover_mosaic_uniform.lua
    ─────────────────────────────────────────────────────────────────────────────
    Mosaic mode:
      • Enforces a uniform portrait aspect ratio (2:3) on all native book cover
        images so that landscape covers do not render wider than portrait ones.

    Approach inspired by SeriousHornet/KOReader.patches#2---stretched-covers.lua:
    find the local ImageWidget upvalue inside MosaicMenuItem.update's closure
    and replace it with a subclass that constrains width/height to the target
    aspect ratio on init, before KOReader scales and renders the cover.

    Folder covers (browser_folder_cover.lua) handle their own sizing separately.

    Always applied – no feature flag required.
]]

local function apply_browser_cover_mosaic_uniform()
    local Size = require("ui/size")

    local MosaicMenu = require("mosaicmenu")

    local function get_upvalue(fn, name)
        if type(fn) ~= "function" then return nil end
        for i = 1, 128 do
            local upname, value = debug.getupvalue(fn, i)
            if not upname then break end
            if upname == name then return value, i end
        end
    end

    local MosaicMenuItem = get_upvalue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem then return end

    if MosaicMenuItem._zen_mosaic_uniform_patched then return end
    MosaicMenuItem._zen_mosaic_uniform_patched = true

    -- Find the ImageWidget upvalue inside MosaicMenuItem.update.
    local local_ImageWidget, upvalue_idx
    for i = 1, 128 do
        local name, value = debug.getupvalue(MosaicMenuItem.update, i)
        if not name then break end
        if name == "ImageWidget" then
            local_ImageWidget = value
            upvalue_idx = i
            break
        end
    end

    if not local_ImageWidget or not upvalue_idx then return end

    -- Capture cell inner dimensions per-init so the subclass can reference them.
    -- All cells in a grid share the same size, so a module-level pair is fine.
    local max_img_w, max_img_h
    local orig_init = MosaicMenuItem.init
    function MosaicMenuItem:init()
        if self.width and self.height then
            local border = Size.border.thin
            max_img_w = self.width  - 2 * border
            max_img_h = self.height - 2 * border
        end
        if orig_init then orig_init(self) end
    end

    -- StretchingImageWidget: constrain every cover to a portrait 2:3 box.
    local aspect_ratio = 2 / 3   -- width / height
    local StretchingImageWidget = local_ImageWidget:extend({})

    StretchingImageWidget.init = function(self)
        if local_ImageWidget.init then
            local_ImageWidget.init(self)
        end
        if not max_img_w or not max_img_h then return end

        -- Reset any scale_factor set by the caller; we drive sizing via w/h.
        self.scale_factor = nil

        if max_img_w / max_img_h > aspect_ratio then
            -- Cell is wider than 2:3 → constrain height, derive width.
            self.height = max_img_h
            self.width  = math.floor(max_img_h * aspect_ratio)
        else
            -- Cell is taller than 2:3 → constrain width, derive height.
            self.width  = max_img_w
            self.height = math.floor(max_img_w / aspect_ratio)
        end
    end

    debug.setupvalue(MosaicMenuItem.update, upvalue_idx, StretchingImageWidget)
end

return apply_browser_cover_mosaic_uniform
