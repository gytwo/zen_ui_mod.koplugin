local defaults = require("config/defaults")
local utils = require("common/utils")

local KEY = "zen_ui_config"
local M = {}

local function merged_with_defaults(stored)
    local cfg = utils.deepcopy(defaults)
    if type(stored) == "table" then
        utils.deepmerge(stored, cfg)
        cfg = stored
    end
    utils.deepmerge(cfg, defaults)
    return cfg
end

function M.load()
    local stored = G_reader_settings:readSetting(KEY, {})
    local cfg = merged_with_defaults(stored)
    return cfg
end

function M.save(config)
    G_reader_settings:saveSetting(KEY, config)
end

function M.key()
    return KEY
end

return M
