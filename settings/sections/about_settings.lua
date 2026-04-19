-- settings/sections/about.lua
-- "About" info items: plugin version, KOReader version, device, firmware.
-- Receives ctx: { plugin }

local _ = require("gettext")
local UIManager = require("ui/uimanager")
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

    table.insert(items, {
        text = _("Show quickstart"),
        separator = true,
        callback = function()
            local ok_qs, QuickstartScreen = pcall(require, "common/quickstart_screen")
            if not ok_qs then return end
            local ok_pg, pages_mod = pcall(require, "common/quickstart_pages")
            if not ok_pg then return end
            UIManager:show(QuickstartScreen:new{
                pages = pages_mod.INSTALL_PAGES,
            })
        end,
    })

    return items
end

return M
