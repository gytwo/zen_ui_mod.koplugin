-- settings/sections/about.lua
-- "About" info items: plugin version, KOReader version, device, firmware.
-- Receives ctx: { plugin }

local _ = require("gettext")
local utils = require("settings/zen_settings_utils")

local M = {}

function M.build(ctx)
    local plugin = ctx.plugin
    local items = {}

    table.insert(items, {
        text_func = function()
            return _("Zen UI: ") .. utils.get_plugin_version(plugin)
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text_func = function()
            return _("KOReader: ") .. utils.get_koreader_version()
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text_func = function()
            return _("Device: ") .. utils.get_device_model_name()
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text_func = function()
            local fw = utils.get_kindle_firmware_display()
            if fw == "n/a" then return nil end
            return _("Firmware: ") .. fw
        end,
        enabled_func = function()
            return utils.get_kindle_firmware_display() ~= "n/a"
        end,
        keep_menu_open = true,
        separator = true
    })

    return items
end

return M
