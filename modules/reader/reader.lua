local M = {}
local initialized = false

local PATCH_MODULES = {
    reader_header_clock = "modules/reader/patches/reader_header_clock",
}

local function is_feature_enabled(plugin, key)
    return plugin
        and type(plugin.config) == "table"
        and type(plugin.config.features) == "table"
        and plugin.config.features[key] == true
end

local function run_feature(logger, plugin, feature, fn)
    local prev_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    _G.__ZEN_UI_PLUGIN = plugin
    local ok, err = pcall(fn)
    _G.__ZEN_UI_PLUGIN = prev_plugin
    if not ok and logger then
        logger.warn("zen-ui: grouped reader feature failed", feature, err)
    end
    return ok
end

local function load_patch(feature)
    local module_name = PATCH_MODULES[feature]
    if not module_name then
        return nil
    end
    local ok, patch_fn = pcall(require, module_name)
    if not ok or type(patch_fn) ~= "function" then
        return nil
    end
    return patch_fn
end

function M.init(logger, plugin)
    if initialized then
        return true
    end

    if is_feature_enabled(plugin, "reader_header_clock") then
        local fn = load_patch("reader_header_clock")
        if fn then
            run_feature(logger, plugin, "reader_header_clock", fn)
        elseif logger then
            logger.warn("zen-ui: reader patch module missing", "reader_header_clock")
        end
    end

    initialized = true
    return true
end

return M
