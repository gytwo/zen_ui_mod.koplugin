local M = {}

function M.deepcopy(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for k, v in pairs(value) do
        result[M.deepcopy(k)] = M.deepcopy(v)
    end
    return result
end

function M.deepmerge(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return src
    end

    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            M.deepmerge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = M.deepcopy(v)
        end
    end

    return dst
end

function M.set_at_path(tbl, path, value)
    local node = tbl
    for i = 1, #path - 1 do
        local key = path[i]
        if type(node[key]) ~= "table" then
            node[key] = {}
        end
        node = node[key]
    end
    node[path[#path]] = value
end

--- Resolve an icon name to an absolute file path within a plugin icons directory.
--- Checks for <name>.svg then <name>.png. Returns the path string or nil.
--- Pass the result as `file =` to IconWidget/ColorIconWidget instead of `icon =`.
--- @param icons_dir string  absolute path to the icons dir, ending with "/"
--- @param name      string  icon name without extension
--- @return          string|nil
function M.resolveLocalIcon(icons_dir, name)
    if not icons_dir or not name then return nil end
    local lfs = require("libs/libkoreader-lfs")
    for _, ext in ipairs({ ".svg", ".png" }) do
        local p = icons_dir .. name .. ext
        if lfs.attributes(p, "mode") == "file" then return p end
    end
    return nil
end

--- Register plugin icons so short names resolve immediately via IconWidget.
--- Injects name→path entries into IconWidget's module-local ICONS_PATH cache,
--- and optionally copies the files into KOReader's user icons directory so they
--- also resolve on subsequent cold starts (without the cache injection).
---
--- @param icons_dir        string   absolute path to the plugin icons dir, ending with "/"
--- @param icons            table    mapping of { [icon_name] = "filename.ext", ... }
--- @param copy_to_user_dir boolean  when true, also copy files to DataStorage icons dir
function M.registerPluginIcons(icons_dir, icons, copy_to_user_dir)
    if not icons_dir or type(icons) ~= "table" then return end
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")

        -- Copy files to user icons dir (for restart-based resolution by the scanner)
        if copy_to_user_dir then
            pcall(function()
                local DataStorage = require("datastorage")
                local ffiutil = require("ffi/util")
                local user_icons_dir = DataStorage:getDataDir() .. "/icons"
                if lfs.attributes(user_icons_dir, "mode") ~= "directory" then
                    lfs.mkdir(user_icons_dir)
                end
                for _, filename in pairs(icons) do
                    local dst = user_icons_dir .. "/" .. filename
                    if lfs.attributes(dst, "mode") ~= "file" then
                        local src = icons_dir .. filename
                        if lfs.attributes(src, "mode") == "file" then
                            ffiutil.copyFile(src, dst)
                        end
                    end
                end
            end)
        end

        -- Inject into IconWidget's runtime ICONS_PATH upvalue cache
        local iw = require("ui/widget/iconwidget")
        local iw_init = rawget(iw, "init")
        if type(iw_init) ~= "function" then return end
        local icons_path
        for i = 1, 64 do
            local uname, uval = debug.getupvalue(iw_init, i)
            if uname == nil then break end
            if uname == "ICONS_PATH" and type(uval) == "table" then
                icons_path = uval
                break
            end
        end
        if not icons_path then return end
        for name, filename in pairs(icons) do
            if not icons_path[name] then
                local p = icons_dir .. filename
                if lfs.attributes(p, "mode") == "file" then
                    icons_path[name] = p
                end
            end
        end
    end)
end

--- Override built-in KOReader icons by name at runtime.
--- Wraps IconWidget.init so that after normal icon resolution,
--- the file path is swapped to our replacement for matching names.
--- Does NOT modify any original icon files on disk.
---
--- @param overrides table  map of icon_name → absolute replacement path
function M.overrideIcons(overrides)
    local lfs = require("libs/libkoreader-lfs")
    local valid = {}
    for name, path in pairs(overrides) do
        if lfs.attributes(path, "mode") == "file" then
            valid[name] = path
        end
    end
    if not next(valid) then return end

    local iw = require("ui/widget/iconwidget")
    local orig_init = iw.init
    function iw:init()
        orig_init(self)
        if valid[self.icon] then
            self.file = valid[self.icon]
        end
    end
end

-- Module-level cache so pgettext is resolved only once (lazy, safe for early require).
local _C_cache
local function _C(ctx, msgid)
    if not _C_cache then
        local _cg = rawget(_G, "C_")
        if type(_cg) == "function" then
            _C_cache = _cg
        else
            local ok_gt, gt = pcall(require, "gettext")
            if ok_gt and gt and type(gt.pgettext) == "function" then
                _C_cache = function(c, m) return gt.pgettext(c, m) end
            else
                _C_cache = function(_, m) return m end
            end
        end
    end
    return _C_cache(ctx, msgid)
end

--- Returns a localised page-count label.
--- long=false (default): abbreviated form, e.g. "100\u{00A0}p."  (for mosaic badges)
--- long=true:            full word form,  e.g. "100\u{00A0}pages" (for list-view text)
--- The label is translated via pgettext using the page_count / page_count_long context.
--- @param pages number
--- @param long  boolean|nil
--- @return string
function M.formatPageCount(pages, long)
    local ctx = long and "page_count_long" or "page_count"
    local msgid = long and "pages" or "p."
    return tostring(pages) .. "\u{00A0}" .. _C(ctx, msgid)
end

return M
