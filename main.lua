local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local ConfigManager = require("config/manager")
local registry = require("modules/registry")
local zen_settings = require("settings/zen_settings")

local ZenUI = WidgetContainer:extend{
    name = "zen_ui",
    is_doc_only = false,
}

function ZenUI:saveConfig()
    ConfigManager.save(self.config)
end

local function is_enabled(config, path)
    if not path then
        return true
    end
    local node = config
    for _, key in ipairs(path) do
        node = node and node[key]
    end
    return node == true
end

function ZenUI:_initModules()
    for _, def in ipairs(registry) do
        if is_enabled(self.config, def.setting) then
            local ok, module = pcall(require, def.file)
            if ok and module and module.init then
                local loaded_ok = module.init(logger, self)
                if not loaded_ok then
                    logger.warn("zen-ui: module failed to load", def.id)
                end
            else
                logger.warn("zen-ui: module require failed", def.id)
            end
        end
    end
end

function ZenUI:init()
    self.config = ConfigManager.load()
    self:_initModules()

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function ZenUI:addToMainMenu(menu_items)
    local root = zen_settings.build(self)
    menu_items.zen_ui = {
        text = root.text,
        callback = function()
            zen_settings.show_page(self, self.ui)
        end,
    }
end

return ZenUI
