local settings_builder = require("settings/zen_settings_build")
local settings_page = require("settings/zen_settings_page")

local M = {}

function M.build(plugin)
    return settings_builder.build(plugin)
end

function M.show_page(plugin, show_parent)
    return settings_page.show_page(plugin, show_parent)
end

return M
