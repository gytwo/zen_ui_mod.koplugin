-- i18n must be installed before any other require() so every subsequent
-- require("gettext") in every sub-module receives the wrapped version.
local i18n = require("common/i18n")
i18n.install()

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local ConfigManager = require("config/manager")
local registry = require("modules/registry")
local zen_settings = require("settings/zen_settings")
local zen_updater   = require("settings/zen_updater")

-- Absolute path to this plugin's root directory (used for custom icon paths).
local _plugin_root = (function()
    local src = debug.getinfo(1, "S").source or ""
    return (src:sub(1, 1) == "@") and src:sub(2):match("^(.*)/[^/]+$") or nil
end)()

-- Register local SVGs so short icon names resolve to our files at runtime.
if _plugin_root then
    local utils = require("common/utils")
    utils.registerPluginIcons(_plugin_root .. "/icons/", {
        ["zen_settings"]        = "settings.svg",
        ["zen_settings_update"] = "settings_update.svg",
        ["quicksettings"]       = "quicksettings.svg",
        ["zen_ui"]              = "zen_ui.svg",
        ["zen_ui_light"]        = "zen_ui_light.svg",
        ["library"]             = "library.svg",
        ["zen_favorites"]       = "tab_favorites.svg",
        ["zen_history"]         = "tab_history.svg",
    }, true)
    -- Override KOReader's default dialog icons with the Zen UI logo.
    local zen_icon = _plugin_root .. "/icons/zen_ui.svg"
    utils.overrideIcons({
        ["notice-info"]     = zen_icon,
        ["notice-question"] = zen_icon,
    })
    -- Register bundled SymbolsNerdFont as last-resort fallback for MDI glyphs.
    -- Append (not prepend) so KOReader's own icon fonts resolve first; our
    -- custom PUA codepoints are unique enough that they'll still reach this.
    local ok_font, Font = pcall(require, "ui/font")
    local ok_fl, FontList = pcall(require, "fontlist")
    if ok_font and Font and Font.fallbacks and ok_fl and FontList then
        FontList:getFontList() -- ensure fontlist is populated before we inject
        table.insert(FontList.fontlist, _plugin_root .. "/fonts/SymbolsNerdFont-Regular.ttf")
        table.insert(Font.fallbacks, "SymbolsNerdFont-Regular.ttf")
    end
end

-- Holds the single plugin instance so the FileManagerMenu patch can reach it.
local _zen_plugin_ref = nil

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
    _zen_plugin_ref = self

    -- First-run: backup user's original screensaver settings as a preset.
    if not self.config._meta.screensaver_backup_created then
        if type(self.config.sleep_screen) ~= "table" then
            self.config.sleep_screen = { presets = {}, active_preset = nil }
        end
        if type(self.config.sleep_screen.presets) ~= "table" then
            self.config.sleep_screen.presets = {}
        end
        local backup = {
            name = "Backup of Original",
            screensaver_type = G_reader_settings:readSetting("screensaver_type"),
            screensaver_message = G_reader_settings:readSetting("screensaver_message"),
            screensaver_show_message = G_reader_settings:isTrue("screensaver_show_message"),
            screensaver_img_background = G_reader_settings:readSetting("screensaver_img_background"),
            screensaver_document_cover = G_reader_settings:readSetting("screensaver_document_cover"),
            screensaver_stretch_images = G_reader_settings:isTrue("screensaver_stretch_images"),
            screensaver_stretch_limit_percentage = G_reader_settings:readSetting("screensaver_stretch_limit_percentage"),
        }
        table.insert(self.config.sleep_screen.presets, 1, backup)
        self.config._meta.screensaver_backup_created = true
        self:saveConfig()
    end

    -- First-run: backup user's original footer settings as a preset.
    if not self.config._meta.footer_backup_created then
        local footer_settings = G_reader_settings:readSetting("footer")
        if footer_settings then
            local util = require("util")
            if type(self.config.reader_footer) ~= "table" then
                self.config.reader_footer = {}
            end
            self.config.reader_footer.backup_preset = {
                name = "Backup of Original",
                footer = util.tableDeepCopy(footer_settings),
                reader_footer_mode = G_reader_settings:readSetting("reader_footer_mode") or 1,
                reader_footer_custom_text = G_reader_settings:readSetting("reader_footer_custom_text") or "KOReader",
                reader_footer_custom_text_repetitions = G_reader_settings:readSetting("reader_footer_custom_text_repetitions") or 1,
            }
            self.config._meta.footer_backup_created = true
            self:saveConfig()
        end
    end

    -- First-run: default portrait list mode to 5 items per page.
    if not self.config._meta.files_per_page_defaulted then
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim then
            BookInfoManager:saveSetting("files_per_page", 5)
            local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
            if ok_fc then
                FileChooser.files_per_page = 5
            end
        end
        self.config._meta.files_per_page_defaulted = true
        self:saveConfig()
    end

    self:_initModules()

    -- Inject Zen UI tab after QuickSettings and a Home tab at the far right.
    -- Patches setUpdateItemTable once per class so it persists across menu rebuilds.
    local function find_quicksettings_pos(tab_table)
        for i, tab in ipairs(tab_table) do
            for _, field in ipairs({ "id", "name", "icon" }) do
                local v = tab[field]
                if type(v) == "string" then
                    local norm = v:lower():gsub("[%s_%-]+", "")
                    if norm == "quicksettings" then
                        return i
                    end
                end
            end
        end
        return nil
    end

    -- Last tab is pushed to far-right by TouchMenuBar's stretch spacer.
    local function inject_zen_tab(menu_class)
        if not menu_class or menu_class.__zen_ui_tab_patched then return end
        menu_class.__zen_ui_tab_patched = true
        local orig_sut = menu_class.setUpdateItemTable
        menu_class.setUpdateItemTable = function(m_self)
            orig_sut(m_self)
            if type(m_self.tab_item_table) ~= "table" or not _zen_plugin_ref then return end
            -- Insert Zen UI tab right after quicksettings.
            local zen_items = zen_settings.build(_zen_plugin_ref).sub_item_table
            -- Use the badge icon when an update is available.
            if zen_updater.has_update() then
                zen_items.icon = "zen_settings_update"
            else
                zen_items.icon = "zen_settings"
            end
            local qs_pos = find_quicksettings_pos(m_self.tab_item_table)
            local insert_pos = qs_pos and (qs_pos + 1) or 1
            table.insert(m_self.tab_item_table, insert_pos, zen_items)
            -- Append Home tab at the far right (stretched position).
            local home_tab = { icon = "library", remember = false }
            home_tab.callback = function()
                require("ui/uimanager"):scheduleIn(0, function()
                    if m_self.menu_container then
                        require("ui/uimanager"):close(m_self.menu_container)
                        m_self.menu_container = nil
                    end
                    local ui = m_self.ui
                    if not ui then return end
                    if ui.document then
                        local file = ui.document.file
                        ui:handleEvent(require("ui/event"):new("CloseConfigMenu"))
                        ui:onClose()
                        if type(ui.showFileManager) == "function" then
                            ui:showFileManager(file)
                        end
                    elseif type(ui.onHome) == "function" then
                        ui:onHome()
                    end
                end)
            end
            table.insert(m_self.tab_item_table, home_tab)
        end
    end

    local ok_fm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if ok_fm then inject_zen_tab(FileManagerMenu) end

    local ok_rm, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if ok_rm then inject_zen_tab(ReaderMenu) end

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- addToMainMenu is a no-op; tab injection is done via the FileManagerMenu patch.
function ZenUI:addToMainMenu(menu_items) -- luacheck: ignore
end

function ZenUI:onCloseWidget()
    i18n.uninstall()
end

return ZenUI
