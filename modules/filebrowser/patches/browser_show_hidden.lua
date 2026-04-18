local function apply_browser_show_hidden()
    -- When "show hidden outside home" is enabled, automatically enforce:
    --   • at or below home dir  → show_hidden = false, show_unsupported = false
    --   • outside home dir      → show_hidden = true, show_unsupported = true
    -- This fires on every directory change via genItemTable.

    local FileChooser = require("ui/widget/filechooser")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end

    local function is_enabled()
        return zen_plugin.config.developer
            and zen_plugin.config.developer.show_hidden_outside_home == true
    end

    local function get_home_dir()
        return G_reader_settings:readSetting("home_dir")
            or require("apps/filemanager/filemanagerutil").getDefaultDir()
    end

    local function is_at_or_below_home(path)
        local home = get_home_dir()
        if not home or not path then return true end
        return path == home or path:sub(1, #home + 1) == home .. "/"
    end

    local orig_genItemTable = FileChooser.genItemTable

    function FileChooser:genItemTable(dirs, files, path)
        if is_enabled() and self.name == "filemanager" then
            local want_hidden = not is_at_or_below_home(path or self.path)
            local current = G_reader_settings:isTrue("show_hidden")
            if current ~= want_hidden then
                G_reader_settings:saveSetting("show_hidden", want_hidden)
                -- Re-scan with the corrected setting
                self.show_hidden = want_hidden
            end

            -- Also manage show_unsupported (all file types)
            local current_unsupported = G_reader_settings:isTrue("show_unsupported")
            if current_unsupported ~= want_hidden then
                G_reader_settings:saveSetting("show_unsupported", want_hidden)
                self.show_unsupported = want_hidden
            end
        end
        return orig_genItemTable(self, dirs, files, path)
    end
end

return apply_browser_show_hidden
