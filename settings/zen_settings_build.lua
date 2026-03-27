local _ = require("gettext")
local UIManager = require("ui/uimanager")
local Device = require("device")

local settings_apply = require("settings/zen_settings_apply")
local updater = require("settings/zen_settings_updater")

local M = {}

local function get_path(tbl, path)
    local node = tbl
    for _, key in ipairs(path) do
        node = node and node[key]
    end
    return node
end

local function set_path(tbl, path, value)
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

function M.build(plugin)
    local config = plugin.config

    local function apply_feature(feature, label)
        local enabled = get_path(config, { "features", feature }) == true
        settings_apply.apply_feature_toggle(plugin, feature, enabled, label)
    end

    local function save_and_apply(feature, label)
        plugin:saveConfig()
        apply_feature(feature, label)
    end

    local function save_and_apply_navbar()
        save_and_apply("navbar", _("Bottom navbar"))
    end

    local function ensure_navbar_color()
        local c = config.navbar.active_tab_color
        if type(c) ~= "table" then
            c = { 0x33, 0x99, 0xFF }
            config.navbar.active_tab_color = c
        end
        c[1] = tonumber(c[1]) or 0x33
        c[2] = tonumber(c[2]) or 0x99
        c[3] = tonumber(c[3]) or 0xFF
        c[1] = math.max(0, math.min(255, c[1]))
        c[2] = math.max(0, math.min(255, c[2]))
        c[3] = math.max(0, math.min(255, c[3]))
        return c
    end

    local function set_navbar_color(r, g, b)
        config.navbar.active_tab_color = {
            math.max(0, math.min(255, tonumber(r) or 0)),
            math.max(0, math.min(255, tonumber(g) or 0)),
            math.max(0, math.min(255, tonumber(b) or 0)),
        }
    end

    local function get_home_dir()
        return G_reader_settings:readSetting("home_dir")
            or require("apps/filemanager/filemanagerutil").getDefaultDir()
    end

    local function get_last_dir()
        return G_reader_settings:readSetting("lastdir") or "/"
    end

    local function get_current_dir()
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        local fm = ok and FileManager and FileManager.instance
        if fm and fm.file_chooser and fm.file_chooser.path then
            return fm.file_chooser.path
        end
        return get_last_dir()
    end

    local function save_and_apply_quick_settings()
        save_and_apply("quick_settings", _("Quick settings panel"))
    end

    local function save_and_apply_titlebar()
        save_and_apply("titlebar", _("Custom status bar"))
    end

    local feature_items = {
        { text = _("Bottom navbar"), path = { "features", "navbar" } },
        { text = _("Quick settings panel"), path = { "features", "quick_settings" } },
        { text = _("Custom status bar"), path = { "features", "titlebar" } },
        { text = _("Hide pagination footer"), path = { "features", "hide_pagination" } },
        { text = _("Disable top menu zones"), path = { "features", "disable_top_menu_zones" } },
        { text = _("Browser folder covers"), path = { "features", "browser_folder_cover" } },
        { text = _("Browser hide underline"), path = { "features", "browser_hide_underline" } },
        { text = _("Browser up-folder behavior"), path = { "features", "browser_up_folder" } },
        { text = _("Reader header clock"), path = { "features", "reader_header_clock" } },
    }

    local items = {}
    for _, item in ipairs(feature_items) do
        table.insert(items, {
            text = item.text,
            checked_func = function()
                return get_path(config, item.path)
            end,
            callback = function()
                local current = get_path(config, item.path)
                local enabled = not current
                set_path(config, item.path, enabled)
                plugin:saveConfig()
                settings_apply.apply_feature_toggle(plugin, item.path[2], enabled, item.text)
            end,
        })
    end

    local navbar_tab_items = {
        { id = "books", text = _("Books") },
        { id = "manga", text = _("Manga") },
        { id = "news", text = _("News") },
        { id = "continue", text = _("Continue") },
        { id = "history", text = _("History") },
        { id = "favorites", text = _("Favorites") },
        { id = "collections", text = _("Collections") },
        { id = "exit", text = _("Exit") },
        { id = "page_left", text = _("Previous page") },
        { id = "page_right", text = _("Next page") },
    }

    local navbar_tab_toggle_items = {}
    for _, tab in ipairs(navbar_tab_items) do
        if tab.id ~= "books" then
            table.insert(navbar_tab_toggle_items, {
                text = tab.text,
                checked_func = function()
                    return config.navbar.show_tabs[tab.id] == true
                end,
                callback = function()
                    local current = config.navbar.show_tabs[tab.id] == true
                    config.navbar.show_tabs[tab.id] = not current
                    save_and_apply_navbar()
                end,
            })
        end
    end

    table.insert(items, {
        text = _("Bottom navbar settings"),
        enabled_func = function()
            return config.features.navbar == true
        end,
        sub_item_table = {
            {
                text = _("Show labels"),
                checked_func = function() return config.navbar.show_labels == true end,
                callback = function()
                    config.navbar.show_labels = not (config.navbar.show_labels == true)
                    save_and_apply("navbar", _("Bottom navbar"))
                end,
            },
            {
                text = _("Show top border"),
                checked_func = function() return config.navbar.show_top_border == true end,
                callback = function()
                    config.navbar.show_top_border = not (config.navbar.show_top_border == true)
                    save_and_apply("navbar", _("Bottom navbar"))
                end,
            },
            {
                text = _("Show in standalone views"),
                checked_func = function() return config.navbar.show_in_standalone == true end,
                callback = function()
                    config.navbar.show_in_standalone = not (config.navbar.show_in_standalone == true)
                    save_and_apply("navbar", _("Bottom navbar"))
                end,
            },
            {
                text = _("Show top gap"),
                checked_func = function() return config.navbar.show_top_gap == true end,
                callback = function()
                    config.navbar.show_top_gap = not (config.navbar.show_top_gap == true)
                    save_and_apply("navbar", _("Bottom navbar"))
                end,
            },
            {
                text = _("Active tab styling"),
                checked_func = function() return config.navbar.active_tab_styling == true end,
                callback = function()
                    config.navbar.active_tab_styling = not (config.navbar.active_tab_styling == true)
                    save_and_apply("navbar", _("Bottom navbar"))
                end,
            },
            {
                text = _("Bold active tab"),
                checked_func = function() return config.navbar.active_tab_bold == true end,
                enabled_func = function() return config.navbar.active_tab_styling == true end,
                callback = function()
                    config.navbar.active_tab_bold = not (config.navbar.active_tab_bold == true)
                    save_and_apply("navbar", _("Bottom navbar"))
                end,
            },
            {
                text = _("Active tab underline"),
                checked_func = function() return config.navbar.active_tab_underline == true end,
                enabled_func = function() return config.navbar.active_tab_styling == true end,
                callback = function()
                    config.navbar.active_tab_underline = not (config.navbar.active_tab_underline == true)
                    save_and_apply("navbar", _("Bottom navbar"))
                end,
            },
            {
                text = _("Underline above icon"),
                checked_func = function() return config.navbar.underline_above == true end,
                enabled_func = function() return config.navbar.active_tab_styling == true and config.navbar.active_tab_underline == true end,
                callback = function()
                    config.navbar.underline_above = not (config.navbar.underline_above == true)
                    save_and_apply("navbar", _("Bottom navbar"))
                end,
            },
            {
                text = _("Colored active tab"),
                checked_func = function() return config.navbar.colored == true end,
                enabled_func = function() return config.navbar.active_tab_styling == true end,
                callback = function()
                    config.navbar.colored = not (config.navbar.colored == true)
                    save_and_apply_navbar()
                end,
            },
            {
                text_func = function()
                    local c = ensure_navbar_color()
                    return _("Active tab color: ") .. string.format("%d,%d,%d", c[1], c[2], c[3])
                end,
                enabled_func = function()
                    return config.navbar.active_tab_styling == true and config.navbar.colored == true
                end,
                sub_item_table = {
                    {
                        text = _("Blue"),
                        checked_func = function()
                            local c = ensure_navbar_color()
                            return c[1] == 0x33 and c[2] == 0x99 and c[3] == 0xFF
                        end,
                        callback = function()
                            set_navbar_color(0x33, 0x99, 0xFF)
                            save_and_apply_navbar()
                        end,
                    },
                    {
                        text = _("Green"),
                        checked_func = function()
                            local c = ensure_navbar_color()
                            return c[1] == 0x33 and c[2] == 0xAA and c[3] == 0x55
                        end,
                        callback = function()
                            set_navbar_color(0x33, 0xAA, 0x55)
                            save_and_apply_navbar()
                        end,
                    },
                    {
                        text = _("Amber"),
                        checked_func = function()
                            local c = ensure_navbar_color()
                            return c[1] == 0xFF and c[2] == 0xAA and c[3] == 0x00
                        end,
                        callback = function()
                            set_navbar_color(0xFF, 0xAA, 0x00)
                            save_and_apply_navbar()
                        end,
                    },
                    {
                        text = _("Red"),
                        checked_func = function()
                            local c = ensure_navbar_color()
                            return c[1] == 0xDD and c[2] == 0x33 and c[3] == 0x33
                        end,
                        callback = function()
                            set_navbar_color(0xDD, 0x33, 0x33)
                            save_and_apply_navbar()
                        end,
                    },
                    {
                        text_func = function()
                            local c = ensure_navbar_color()
                            return _("Custom RGB") .. " (" .. string.format("%d,%d,%d", c[1], c[2], c[3]) .. ")"
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local InputDialog = require("ui/widget/inputdialog")
                            local c = ensure_navbar_color()
                            local dlg
                            dlg = InputDialog:new{
                                title = _("Active tab RGB"),
                                input = string.format("%d,%d,%d", c[1], c[2], c[3]),
                                hint = _("Format: R,G,B (0-255)"),
                                buttons = {{
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function() UIManager:close(dlg) end,
                                    },
                                    {
                                        text = _("Set"),
                                        is_enter_default = true,
                                        callback = function()
                                            local text = dlg:getInputText() or ""
                                            local r, g, b = text:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
                                            if r and g and b then
                                                set_navbar_color(tonumber(r), tonumber(g), tonumber(b))
                                                UIManager:close(dlg)
                                                save_and_apply_navbar()
                                                if touchmenu_instance then
                                                    touchmenu_instance:updateItems()
                                                end
                                            end
                                        end,
                                    },
                                }},
                            }
                            UIManager:show(dlg)
                            dlg:onShowKeyboard()
                        end,
                    },
                },
            },
            {
                text = _("Tabs"),
                sub_item_table = {
                    {
                        text = _("Arrange tabs"),
                        keep_menu_open = true,
                        callback = function()
                            local SortWidget = require("ui/widget/sortwidget")
                            local sort_items = {}
                            for _, tab in ipairs(navbar_tab_items) do
                                local is_visible = tab.id == "books" or config.navbar.show_tabs[tab.id] == true
                                table.insert(sort_items, {
                                    text = tab.text,
                                    orig_item = tab.id,
                                    dim = not is_visible,
                                })
                            end
                            UIManager:show(SortWidget:new{
                                title = _("Arrange navbar tabs"),
                                item_table = sort_items,
                                callback = function()
                                    for i, item in ipairs(sort_items) do
                                        config.navbar.tab_order[i] = item.orig_item
                                    end
                                    save_and_apply_navbar()
                                end,
                            })
                        end,
                    },
                    {
                        text_func = function()
                            local label = config.navbar.books_label
                            if label == nil or label == "" then
                                label = "Books"
                            end
                            return _("Books tab label: ") .. label
                        end,
                        separator = true,
                        sub_item_table = {
                            {
                                text = _("Books"),
                                checked_func = function()
                                    return config.navbar.books_label == nil or config.navbar.books_label == "" or config.navbar.books_label == "Books"
                                end,
                                callback = function()
                                    config.navbar.books_label = "Books"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text = _("Home"),
                                checked_func = function() return config.navbar.books_label == "Home" end,
                                callback = function()
                                    config.navbar.books_label = "Home"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text = _("Library"),
                                checked_func = function() return config.navbar.books_label == "Library" end,
                                callback = function()
                                    config.navbar.books_label = "Library"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text_func = function()
                                    local label = config.navbar.books_label or ""
                                    local presets = { [""] = true, Books = true, Home = true, Library = true }
                                    if presets[label] then
                                        return _("Custom")
                                    end
                                    return _("Custom: ") .. label
                                end,
                                checked_func = function()
                                    local label = config.navbar.books_label or ""
                                    local presets = { [""] = true, Books = true, Home = true, Library = true }
                                    return not presets[label]
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local InputDialog = require("ui/widget/inputdialog")
                                    local dlg
                                    dlg = InputDialog:new{
                                        title = _("Books tab label"),
                                        input = config.navbar.books_label or "",
                                        buttons = {{
                                            {
                                                text = _("Cancel"),
                                                id = "close",
                                                callback = function() UIManager:close(dlg) end,
                                            },
                                            {
                                                text = _("Set"),
                                                is_enter_default = true,
                                                callback = function()
                                                    local text = dlg:getInputText()
                                                    config.navbar.books_label = text ~= "" and text or "Books"
                                                    UIManager:close(dlg)
                                                    save_and_apply_navbar()
                                                    if touchmenu_instance then
                                                        touchmenu_instance:updateItems()
                                                    end
                                                end,
                                            },
                                        }},
                                    }
                                    UIManager:show(dlg)
                                    dlg:onShowKeyboard()
                                end,
                            },
                        },
                    },
                    {
                        text_func = function()
                            if config.navbar.manga_action == "folder" then
                                return _("Manga tab action: ") .. _("Folder")
                            end
                            return _("Manga tab action: ") .. _("Rakuyomi")
                        end,
                        separator = true,
                        sub_item_table = {
                            {
                                text = _("Open Rakuyomi"),
                                checked_func = function() return config.navbar.manga_action ~= "folder" end,
                                callback = function()
                                    config.navbar.manga_action = "rakuyomi"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text_func = function()
                                    if config.navbar.manga_action == "folder" and config.navbar.manga_folder ~= "" then
                                        local util = require("util")
                                        local _dir, folder_name = util.splitFilePathName(config.navbar.manga_folder)
                                        return _("Open folder: ") .. folder_name
                                    end
                                    return _("Open folder")
                                end,
                                checked_func = function() return config.navbar.manga_action == "folder" end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local PathChooser = require("ui/widget/pathchooser")
                                    local start_path = config.navbar.manga_folder ~= "" and config.navbar.manga_folder
                                        or G_reader_settings:readSetting("lastdir") or "/"
                                    local path_chooser = PathChooser:new{
                                        select_file = false,
                                        show_files = false,
                                        path = start_path,
                                        onConfirm = function(dir_path)
                                            config.navbar.manga_action = "folder"
                                            config.navbar.manga_folder = dir_path
                                            save_and_apply_navbar()
                                            if touchmenu_instance then
                                                touchmenu_instance:updateItems()
                                            end
                                        end,
                                    }
                                    UIManager:show(path_chooser)
                                end,
                            },
                            {
                                text = _("Folder presets"),
                                sub_item_table = {
                                    {
                                        text = _("Use home folder"),
                                        callback = function()
                                            config.navbar.manga_action = "folder"
                                            config.navbar.manga_folder = get_home_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                    {
                                        text = _("Use last folder"),
                                        callback = function()
                                            config.navbar.manga_action = "folder"
                                            config.navbar.manga_folder = get_last_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                    {
                                        text = _("Use current folder"),
                                        callback = function()
                                            config.navbar.manga_action = "folder"
                                            config.navbar.manga_folder = get_current_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                },
                            },
                        },
                    },
                    {
                        text_func = function()
                            if config.navbar.news_action == "folder" then
                                return _("News tab action: ") .. _("Folder")
                            end
                            return _("News tab action: ") .. _("QuickRSS")
                        end,
                        separator = true,
                        sub_item_table = {
                            {
                                text = _("Open QuickRSS"),
                                checked_func = function() return config.navbar.news_action ~= "folder" end,
                                callback = function()
                                    config.navbar.news_action = "quickrss"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text_func = function()
                                    if config.navbar.news_action == "folder" and config.navbar.news_folder ~= "" then
                                        local util = require("util")
                                        local _dir, folder_name = util.splitFilePathName(config.navbar.news_folder)
                                        return _("Open folder: ") .. folder_name
                                    end
                                    return _("Open folder")
                                end,
                                checked_func = function() return config.navbar.news_action == "folder" end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local PathChooser = require("ui/widget/pathchooser")
                                    local start_path = config.navbar.news_folder ~= "" and config.navbar.news_folder
                                        or G_reader_settings:readSetting("lastdir") or "/"
                                    local path_chooser = PathChooser:new{
                                        select_file = false,
                                        show_files = false,
                                        path = start_path,
                                        onConfirm = function(dir_path)
                                            config.navbar.news_action = "folder"
                                            config.navbar.news_folder = dir_path
                                            save_and_apply_navbar()
                                            if touchmenu_instance then
                                                touchmenu_instance:updateItems()
                                            end
                                        end,
                                    }
                                    UIManager:show(path_chooser)
                                end,
                            },
                            {
                                text = _("Folder presets"),
                                sub_item_table = {
                                    {
                                        text = _("Use home folder"),
                                        callback = function()
                                            config.navbar.news_action = "folder"
                                            config.navbar.news_folder = get_home_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                    {
                                        text = _("Use last folder"),
                                        callback = function()
                                            config.navbar.news_action = "folder"
                                            config.navbar.news_folder = get_last_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                    {
                                        text = _("Use current folder"),
                                        callback = function()
                                            config.navbar.news_action = "folder"
                                            config.navbar.news_folder = get_current_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                },
                            },
                        },
                    },
                    {
                        text = _("Visibility"),
                        sub_item_table = navbar_tab_toggle_items,
                    },
                },
            },
            {
                text = _("Refresh navbar"),
                keep_menu_open = true,
                callback = function()
                    apply_feature("navbar", _("Bottom navbar"))
                end,
            },
        },
    })

    local quick_button_items = {
        { key = "wifi", text = _("Wi-Fi") },
        { key = "night", text = _("Night mode") },
        { key = "rotate", text = _("Rotate") },
        { key = "settings", text = _("Settings") },
        { key = "usb", text = _("USB") },
        { key = "search", text = _("File search") },
        { key = "quickrss", text = _("QuickRSS") },
        { key = "cloud", text = _("Cloud storage") },
        { key = "zlibrary", text = _("Z-Library") },
        { key = "calibre", text = _("Calibre") },
        { key = "notion", text = _("Notion") },
        { key = "streak", text = _("Streak") },
        { key = "opds", text = _("OPDS") },
        { key = "filebrowser", text = _("Filebrowser") },
        { key = "browserbar", text = _("Browser bar") },
        { key = "restart", text = _("Restart") },
        { key = "exit", text = _("Exit") },
        { key = "sleep", text = _("Sleep") },
        { key = "home", text = _("Home") },
    }

    local quick_button_label_by_id = {}
    for _, quick_item in ipairs(quick_button_items) do
        quick_button_label_by_id[quick_item.key] = quick_item.text
    end

    local quick_button_sub_items = {}

    table.insert(quick_button_sub_items, {
        text = _("Arrange buttons"),
        keep_menu_open = true,
        separator = true,
        callback = function()
            local SortWidget = require("ui/widget/sortwidget")
            local sort_items = {}
            for _, id in ipairs(config.quick_settings.button_order) do
                local label = quick_button_label_by_id[id]
                if label then
                    table.insert(sort_items, {
                        text = label,
                        orig_item = id,
                        dim = not (config.quick_settings.show_buttons[id] == true),
                    })
                end
            end

            UIManager:show(SortWidget:new{
                title = _("Arrange quick settings buttons"),
                item_table = sort_items,
                callback = function()
                    for i, item in ipairs(sort_items) do
                        config.quick_settings.button_order[i] = item.orig_item
                    end
                    save_and_apply_quick_settings()
                end,
            })
        end,
    })

    for _, quick_item in ipairs(quick_button_items) do
        table.insert(quick_button_sub_items, {
            text = quick_item.text,
            checked_func = function()
                return config.quick_settings.show_buttons[quick_item.key] == true
            end,
            callback = function()
                local current = config.quick_settings.show_buttons[quick_item.key] == true
                config.quick_settings.show_buttons[quick_item.key] = not current
                save_and_apply_quick_settings()
            end,
        })
    end

    table.insert(items, {
        text = _("Quick settings panel settings"),
        enabled_func = function()
            return config.features.quick_settings == true
        end,
        sub_item_table = {
            {
                text = _("Show frontlight slider"),
                checked_func = function() return config.quick_settings.show_frontlight == true end,
                callback = function()
                    config.quick_settings.show_frontlight = not (config.quick_settings.show_frontlight == true)
                    save_and_apply_quick_settings()
                end,
            },
            {
                text = _("Show warmth slider"),
                checked_func = function() return config.quick_settings.show_warmth == true end,
                callback = function()
                    config.quick_settings.show_warmth = not (config.quick_settings.show_warmth == true)
                    save_and_apply_quick_settings()
                end,
            },
            {
                text = _("Always open on this tab"),
                checked_func = function() return config.quick_settings.open_on_start == true end,
                callback = function()
                    config.quick_settings.open_on_start = not (config.quick_settings.open_on_start == true)
                    save_and_apply_quick_settings()
                end,
            },
            {
                text = _("Buttons"),
                sub_item_table = quick_button_sub_items,
            },
        },
    })

    table.insert(items, {
        text = _("Custom status bar settings"),
        enabled_func = function()
            return config.features.titlebar == true
        end,
        sub_item_table = {
            {
                text = _("Hide browser bar"),
                checked_func = function() return config.titlebar.hide_topbar == true end,
                callback = function()
                    config.titlebar.hide_topbar = not (config.titlebar.hide_topbar == true)
                    save_and_apply_titlebar()
                end,
            },
            {
                text_func = function()
                    local name = config.titlebar.device_name
                    if name == nil or name == "" then
                        name = Device.model or ""
                    end
                    return _("Device name: ") .. name
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local InputDialog = require("ui/widget/inputdialog")
                    local dlg
                    dlg = InputDialog:new{
                        title = _("Device name"),
                        input = config.titlebar.device_name or "",
                        hint = Device.model or "",
                        buttons = {{
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function() UIManager:close(dlg) end,
                            },
                            {
                                text = _("Set"),
                                is_enter_default = true,
                                callback = function()
                                    config.titlebar.device_name = dlg:getInputText()
                                    UIManager:close(dlg)
                                    save_and_apply_titlebar()
                                    if touchmenu_instance then
                                        touchmenu_instance:updateItems()
                                    end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            },
            {
                text = _("Show time"),
                checked_func = function() return config.titlebar.show_time == true end,
                callback = function()
                    config.titlebar.show_time = not (config.titlebar.show_time == true)
                    save_and_apply_titlebar()
                end,
            },
            {
                text = _("12-hour time"),
                checked_func = function() return config.titlebar.time_12h == true end,
                enabled_func = function() return config.titlebar.show_time == true end,
                callback = function()
                    config.titlebar.time_12h = not (config.titlebar.time_12h == true)
                    save_and_apply_titlebar()
                end,
            },
            {
                text = _("Show bottom border"),
                checked_func = function() return config.titlebar.show_bottom_border == true end,
                callback = function()
                    config.titlebar.show_bottom_border = not (config.titlebar.show_bottom_border == true)
                    save_and_apply_titlebar()
                end,
            },
            {
                text = _("Bold text"),
                checked_func = function() return config.titlebar.bold_text == true end,
                callback = function()
                    config.titlebar.bold_text = not (config.titlebar.bold_text == true)
                    save_and_apply_titlebar()
                end,
            },
            {
                text = _("Colored status icons"),
                checked_func = function() return config.titlebar.colored == true end,
                callback = function()
                    config.titlebar.colored = not (config.titlebar.colored == true)
                    save_and_apply_titlebar()
                end,
            },
            {
                text = _("Items"),
                sub_item_table = {
                    {
                        text = _("Arrange items"),
                        keep_menu_open = true,
                        separator = true,
                        callback = function()
                            local SortWidget = require("ui/widget/sortwidget")
                            local titlebar_items = {
                                wifi = _("WiFi"),
                                disk = _("Disk space"),
                                ram = _("RAM usage"),
                                frontlight = _("Frontlight"),
                                battery = _("Battery"),
                            }
                            local sort_items = {}
                            for _, key in ipairs(config.titlebar.order) do
                                if titlebar_items[key] then
                                    table.insert(sort_items, {
                                        text = titlebar_items[key],
                                        orig_item = key,
                                        dim = not (config.titlebar.show[key] == true),
                                    })
                                end
                            end

                            UIManager:show(SortWidget:new{
                                title = _("Arrange titlebar items"),
                                item_table = sort_items,
                                callback = function()
                                    for i, item in ipairs(sort_items) do
                                        config.titlebar.order[i] = item.orig_item
                                    end
                                    save_and_apply_titlebar()
                                end,
                            })
                        end,
                    },
                    {
                        text = _("Show WiFi"),
                        checked_func = function() return config.titlebar.show.wifi == true end,
                        callback = function()
                            config.titlebar.show.wifi = not (config.titlebar.show.wifi == true)
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("Show disk space"),
                        checked_func = function() return config.titlebar.show.disk == true end,
                        callback = function()
                            config.titlebar.show.disk = not (config.titlebar.show.disk == true)
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("Show RAM usage"),
                        checked_func = function() return config.titlebar.show.ram == true end,
                        callback = function()
                            config.titlebar.show.ram = not (config.titlebar.show.ram == true)
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("Show frontlight"),
                        checked_func = function() return config.titlebar.show.frontlight == true end,
                        callback = function()
                            config.titlebar.show.frontlight = not (config.titlebar.show.frontlight == true)
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("Show battery"),
                        checked_func = function() return config.titlebar.show.battery == true end,
                        callback = function()
                            config.titlebar.show.battery = not (config.titlebar.show.battery == true)
                            save_and_apply_titlebar()
                        end,
                    },
                },
            },
            {
                text_func = function()
                    local separator_label = {
                        dot = _("Middle dot"),
                        bar = _("Vertical bar"),
                        dash = _("Dash"),
                        bullet = _("Bullet"),
                        space = _("Space only"),
                        ["small-space"] = _("Space only (small)"),
                        none = _("No separator"),
                        custom = _("Custom"),
                    }
                    local key = config.titlebar.separator_key or "dot"
                    return _("Separator: ") .. (separator_label[key] or key)
                end,
                sub_item_table = {
                    {
                        text = _("Middle dot") .. "  '  ·  '",
                        checked_func = function() return config.titlebar.separator_key == "dot" end,
                        callback = function()
                            config.titlebar.separator_key = "dot"
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("Vertical bar") .. "  '  |  '",
                        checked_func = function() return config.titlebar.separator_key == "bar" end,
                        callback = function()
                            config.titlebar.separator_key = "bar"
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("Dash") .. "  '  -  '",
                        checked_func = function() return config.titlebar.separator_key == "dash" end,
                        callback = function()
                            config.titlebar.separator_key = "dash"
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("Bullet") .. "  '  •  '",
                        checked_func = function() return config.titlebar.separator_key == "bullet" end,
                        callback = function()
                            config.titlebar.separator_key = "bullet"
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("Space only") .. "  '   '",
                        checked_func = function() return config.titlebar.separator_key == "space" end,
                        callback = function()
                            config.titlebar.separator_key = "space"
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("Space only (small)") .. "  ' '",
                        checked_func = function() return config.titlebar.separator_key == "small-space" end,
                        callback = function()
                            config.titlebar.separator_key = "small-space"
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text = _("No separator"),
                        checked_func = function() return config.titlebar.separator_key == "none" end,
                        callback = function()
                            config.titlebar.separator_key = "none"
                            save_and_apply_titlebar()
                        end,
                    },
                    {
                        text_func = function()
                            return _("Custom") .. "  '" .. (config.titlebar.custom_separator or "") .. "'"
                        end,
                        checked_func = function() return config.titlebar.separator_key == "custom" end,
                        callback = function(touchmenu_instance)
                            local InputDialog = require("ui/widget/inputdialog")
                            local dlg
                            dlg = InputDialog:new{
                                title = _("Custom separator"),
                                input = config.titlebar.custom_separator or "",
                                buttons = {{
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function() UIManager:close(dlg) end,
                                    },
                                    {
                                        text = _("Set"),
                                        is_enter_default = true,
                                        callback = function()
                                            config.titlebar.custom_separator = dlg:getInputText()
                                            config.titlebar.separator_key = "custom"
                                            UIManager:close(dlg)
                                            save_and_apply_titlebar()
                                            if touchmenu_instance then
                                                touchmenu_instance:updateItems()
                                            end
                                        end,
                                    },
                                }},
                            }
                            UIManager:show(dlg)
                            dlg:onShowKeyboard()
                        end,
                    },
                },
            },
        },
    })

    table.insert(items, {
        text = _("Browser up-folder settings"),
        enabled_func = function()
            return config.features.browser_up_folder == true
        end,
        sub_item_table = {
            {
                text = _("Hide up folders"),
                checked_func = function() return config.browser_up_folder.hide_up_folder == true end,
                callback = function()
                    config.browser_up_folder.hide_up_folder = not (config.browser_up_folder.hide_up_folder == true)
                    save_and_apply("browser_up_folder", _("Browser up-folder behavior"))
                end,
            },
            {
                text = _("Hide empty folders"),
                checked_func = function() return config.browser_up_folder.hide_empty_folder == true end,
                callback = function()
                    config.browser_up_folder.hide_empty_folder = not (config.browser_up_folder.hide_empty_folder == true)
                    save_and_apply("browser_up_folder", _("Browser up-folder behavior"))
                end,
            },
        },
    })

    table.insert(items, {
        text = _("Enable updater actions"),
        checked_func = function()
            return config.zen.updater_enabled == true
        end,
        callback = function()
            config.zen.updater_enabled = not (config.zen.updater_enabled == true)
            plugin:saveConfig()
        end,
    })

    table.insert(items, updater.build_update_now_item(plugin))

    return {
        text = _("Zen UI"),
        sub_item_table = items,
    }
end

return M
